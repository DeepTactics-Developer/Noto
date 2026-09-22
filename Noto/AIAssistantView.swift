import SwiftUI
import PDFKit

private struct AIMessage: Identifiable {
    let id = UUID()
    let question: String
    var answer: String
    var isError = false
}

struct AIAssistantView: View {
    let document: PDFDocument
    let onJumpToPage: (Int) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var index: DocumentTextIndex?
    @State private var question = ""
    @State private var messages: [AIMessage] = []
    @State private var loading = false
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
        .onAppear { if index == nil { index = DocumentTextIndex(document: document) } }
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
                        if loading {
                            HStack { ProgressView(); Spacer() }.padding(.leading, 4)
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
                Button("요약") { Task { await summarize() } }.buttonStyle(.bordered).disabled(loading)
                Button("목차 생성") { Task { await generateOutline() } }.buttonStyle(.bordered).disabled(loading)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            HStack(spacing: 10) {
                TextField("문서에 대해 질문하기", text: $question)
                    .textFieldStyle(.roundedBorder)
                    .submitLabel(.send)
                    .onSubmit { Task { await ask() } }
                    .disabled(loading)
                Button { Task { await ask() } } label: { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                    .disabled(loading || question.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(12)
        }
        .background(Color(.systemGroupedBackground))
    }

    // The user's own question: a right-aligned bubble, like an outgoing message.
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

    // The AI's answer: a left-aligned bubble, like an incoming message.
    private func answerBubble(_ message: AIMessage) -> some View {
        HStack {
            citedText(message.answer)
                .font(.subheadline)
                .foregroundStyle(message.isError ? Color.red : Color.primary)
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

    private func ask() async {
        let question = question.trimmingCharacters(in: .whitespaces)
        guard !question.isEmpty, let index else { return }
        self.question = ""
        loading = true
        defer { loading = false }
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            do {
                let answer = try await AIAssistant.answer(question: question, index: index)
                messages.append(AIMessage(question: question, answer: answer))
            } catch {
                messages.append(AIMessage(question: question, answer: "답변을 가져오지 못했습니다: \(error.localizedDescription)", isError: true))
            }
            return
        }
        #endif
        messages.append(AIMessage(question: question, answer: "이 빌드에서는 AI 기능을 사용할 수 없습니다.", isError: true))
    }

    private func summarize() async {
        guard let index else { return }
        loading = true
        defer { loading = false }
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            do {
                let answer = try await AIAssistant.summarize(index: index)
                messages.append(AIMessage(question: "요약", answer: answer))
            } catch {
                messages.append(AIMessage(question: "요약", answer: "요약하지 못했습니다: \(error.localizedDescription)", isError: true))
            }
            return
        }
        #endif
        messages.append(AIMessage(question: "요약", answer: "이 빌드에서는 AI 기능을 사용할 수 없습니다.", isError: true))
    }

    private func generateOutline() async {
        guard let index else { return }
        loading = true
        defer { loading = false }
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            do {
                let items = try await AIAssistant.outline(index: index)
                let text = items.isEmpty ? "목차를 만들지 못했습니다." : items.map { "\($0.title) (p.\($0.page + 1))" }.joined(separator: "\n")
                messages.append(AIMessage(question: "목차 생성", answer: text))
            } catch {
                messages.append(AIMessage(question: "목차 생성", answer: "목차를 만들지 못했습니다: \(error.localizedDescription)", isError: true))
            }
            return
        }
        #endif
        messages.append(AIMessage(question: "목차 생성", answer: "이 빌드에서는 AI 기능을 사용할 수 없습니다.", isError: true))
    }
}
