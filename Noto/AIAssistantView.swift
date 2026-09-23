import SwiftUI
import PDFKit

private struct AIMessage: Identifiable {
    let id = UUID()
    let question: String
    var answer: String
    var isError = false
    var isCached = false // shows a "다시 생성" button instead of just sitting there
    var regenerate: (() -> Void)?
}

struct AIAssistantView: View {
    let document: PDFDocument
    let folder: DocumentFolder
    let onJumpToPage: (Int) -> Void
    // Set when opened from the lasso's "AI로 설명" instead of the toolbar AI icon: the gathered PDF text +
    // recognized handwriting from inside the selection, explained automatically as soon as the sheet appears.
    var selectionToExplain: String? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var index: DocumentTextIndex?
    @State private var question = ""
    @State private var messages: [AIMessage] = []
    @State private var loading = false
    @State private var explainedSelection = false
    @StateObject private var dictation = VoiceDictation()
    @State private var dictationError: String?
    private let availability = AIAvailability.current

    var body: some View {
        NavigationStack {
            Group {
                switch availability {
                case .unavailable(let reason):
                    VStack(spacing: 8) {
                        Image(systemName: "sparkles").font(.largeTitle).foregroundStyle(.secondary)
                        Text(reason).font(.subheadline).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center).padding(.horizontal, 32)
                    }
                case .available:
                    chatBody
                }
            }
            .navigationTitle("AI")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("닫기") { dismiss() } } }
        }
        .onAppear {
            if index == nil { index = DocumentTextIndex(document: document) }
            if let selectionToExplain, !explainedSelection {
                explainedSelection = true
                Task { await explainSelection(selectionToExplain) }
            }
        }
    }

    private var chatBody: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if messages.isEmpty {
                            VStack(spacing: 6) {
                                Image(systemName: "sparkles").font(.largeTitle).foregroundStyle(.secondary)
                                Text("이 문서에 대해 무엇이든 물어보세요").font(.subheadline).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                        }
                        ForEach(messages) { message in
                            questionBubble(message.question).id(message.id)
                            answerBubble(message)
                        }
                    }
                    .padding(16)
                }
                .onChange(of: messages.count) { _, _ in
                    if let last = messages.last { withAnimation { proxy.scrollTo(last.id) } }
                }
            }
            Divider()
            HStack(spacing: 10) {
                Button("요약") { Task { await summarize(forceRefresh: false) } }.buttonStyle(.bordered).disabled(loading)
                Button("목차 생성") { Task { await generateOutline(forceRefresh: false) } }.buttonStyle(.bordered).disabled(loading)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            HStack(spacing: 10) {
                TextField(dictation.isListening ? "듣고 있어요…" : "문서에 대해 질문하기", text: $question)
                    .textFieldStyle(.roundedBorder)
                    .submitLabel(.send)
                    .onSubmit { Task { await ask() } }
                    .disabled(loading)
                Button {
                    dictation.isListening ? dictation.stop() : dictation.start()
                } label: {
                    Image(systemName: dictation.isListening ? "mic.fill" : "mic")
                        .font(.title3)
                        .foregroundStyle(dictation.isListening ? Color.red : Color.accentColor)
                }
                .disabled(loading)
                Button { Task { await ask() } } label: { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                    .disabled(loading || question.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(12)
        }
        .background(Color(.systemGroupedBackground))
        .onChange(of: dictation.partialText) { _, text in question = text }
        .onAppear { dictation.onError = { dictationError = $0.localizedDescription } }
        .alert("음성 입력을 사용할 수 없습니다", isPresented: .constant(dictationError != nil), presenting: dictationError) { _ in
            Button("확인") { dictationError = nil }
        } message: { Text($0) }
    }

    // The user's own question: a right-aligned bubble, like an outgoing message. Appended immediately (see
    // appendPlaceholder below) so this shows the moment a question is sent, not only once the answer arrives.
    private func questionBubble(_ text: String) -> some View {
        HStack {
            Spacer(minLength: 40)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    // The AI's answer: a left-aligned bubble, like an incoming message. Empty while still loading (a spinner
    // shows instead), and cached summary/outline results get a small "다시 생성" button of their own.
    private func answerBubble(_ message: AIMessage) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) {
                if message.answer.isEmpty {
                    ProgressView()
                } else {
                    citedText(message.answer)
                        .font(.subheadline)
                        .foregroundStyle(message.isError ? Color.red : Color.primary)
                }
                if message.isCached, let regenerate = message.regenerate {
                    Button("↻ 다시 생성", action: regenerate).font(.caption)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
            Spacer(minLength: 40)
        }
    }

    // Renders "(p.N)" tokens in the answer as tappable page-jump buttons; everything else stays plain text.
    private func citedText(_ text: String) -> some View {
        let parts = text.components(separatedBy: "(p.")
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(parts.enumerated()), id: \.offset) { offset, part in
                if offset == 0 {
                    if !part.isEmpty { Text(part) }
                } else if let closeParen = part.firstIndex(of: ")"), let page = Int(part[part.startIndex..<closeParen]) {
                    HStack(spacing: 4) {
                        Button("p.\(page)") { onJumpToPage(page - 1) }
                            .font(.caption.weight(.semibold))
                            .buttonStyle(.borderless)
                        Text(String(part[part.index(after: closeParen)...]))
                    }
                } else {
                    Text("(p.\(part)")
                }
            }
        }
    }

    // Shows the question right away with an empty (spinner) answer, and returns its id to fill in once the
    // real answer (or an error) is ready.
    private func appendPlaceholder(_ question: String) -> UUID {
        let message = AIMessage(question: question, answer: "")
        messages.append(message)
        return message.id
    }

    private func update(_ id: UUID, answer: String, isError: Bool = false, isCached: Bool = false, regenerate: (() -> Void)? = nil) {
        guard let i = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[i].answer = answer
        messages[i].isError = isError
        messages[i].isCached = isCached
        messages[i].regenerate = regenerate
    }

    private func explainSelection(_ content: String) async {
        let id = appendPlaceholder("선택한 내용 설명")
        guard !content.trimmingCharacters(in: .whitespaces).isEmpty else {
            update(id, answer: "선택 영역에서 텍스트나 필기를 인식하지 못했습니다.", isError: true)
            return
        }
        loading = true
        defer { loading = false }
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            do {
                let answer = try await AIAssistant.explainSelection(content)
                update(id, answer: answer)
            } catch {
                update(id, answer: AIErrorMessage.friendly(for: error), isError: true)
            }
            return
        }
        #endif
        update(id, answer: "이 빌드에서는 AI 기능을 사용할 수 없습니다.", isError: true)
    }

    private func ask() async {
        let question = question.trimmingCharacters(in: .whitespaces)
        guard !question.isEmpty, let index else { return }
        self.question = ""
        let id = appendPlaceholder(question)
        loading = true
        defer { loading = false }
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            do {
                let answer = try await AIAssistant.answer(question: question, index: index)
                update(id, answer: answer)
            } catch {
                update(id, answer: AIErrorMessage.friendly(for: error), isError: true)
            }
            return
        }
        #endif
        update(id, answer: "이 빌드에서는 AI 기능을 사용할 수 없습니다.", isError: true)
    }

    private func summarize(forceRefresh: Bool) async {
        guard let index else { return }
        if !forceRefresh, let cached = AICacheStore.summary(for: folder) {
            let id = appendPlaceholder("요약")
            update(id, answer: cached, isCached: true) { Task { await self.summarize(forceRefresh: true) } }
            return
        }
        let id = appendPlaceholder("요약")
        loading = true
        defer { loading = false }
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            do {
                let answer = try await AIAssistant.summarize(index: index)
                AICacheStore.setSummary(answer, for: folder)
                update(id, answer: answer, isCached: true) { Task { await self.summarize(forceRefresh: true) } }
            } catch {
                update(id, answer: AIErrorMessage.friendly(for: error), isError: true)
            }
            return
        }
        #endif
        update(id, answer: "이 빌드에서는 AI 기능을 사용할 수 없습니다.", isError: true)
    }

    private func generateOutline(forceRefresh: Bool) async {
        guard let index else { return }
        if !forceRefresh, let cached = AICacheStore.outline(for: folder) {
            let id = appendPlaceholder("목차 생성")
            update(id, answer: formatOutline(cached), isCached: true) { Task { await self.generateOutline(forceRefresh: true) } }
            return
        }
        let id = appendPlaceholder("목차 생성")
        loading = true
        defer { loading = false }
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            do {
                let items = try await AIAssistant.outline(index: index)
                guard !items.isEmpty else {
                    update(id, answer: "목차를 만들지 못했습니다.", isError: true)
                    return
                }
                AICacheStore.setOutline(items, for: folder)
                update(id, answer: formatOutline(items), isCached: true) { Task { await self.generateOutline(forceRefresh: true) } }
            } catch {
                update(id, answer: AIErrorMessage.friendly(for: error), isError: true)
            }
            return
        }
        #endif
        update(id, answer: "이 빌드에서는 AI 기능을 사용할 수 없습니다.", isError: true)
    }

    private func formatOutline(_ items: [(title: String, page: Int)]) -> String {
        items.map { "\($0.title) (p.\($0.page + 1))" }.joined(separator: "\n")
    }
}
