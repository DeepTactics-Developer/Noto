import SwiftUI
import UniformTypeIdentifiers

enum LibraryFilter: Hashable {
    case recent, all, favorites, subject(UUID)
}

struct LibraryView: View {
    let onOpen: (DocumentFolder) -> Void

    @State private var documents: [DocumentFolder] = []
    @State private var subjects: [Subject] = []
    @State private var filter: LibraryFilter? = .recent
    @State private var searchText = ""
    @State private var picking = false
    @State private var showingSettings = false
    @State private var showingAddSubject = false
    @State private var newSubjectName = ""
    @State private var pendingDelete: DocumentFolder?
    @State private var errorText: String?

    private var filtered: [DocumentFolder] {
        var list = documents
        switch filter {
        case .recent, nil: list = Array(list.prefix(20))
        case .all: break
        case .favorites: list = list.filter(\.favorite)
        case .subject(let id): list = list.filter { $0.subjectID == id }
        }
        guard !searchText.isEmpty else { return list }
        return list.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $filter) {
                Section {
                    Label("최근", systemImage: "clock").tag(LibraryFilter.recent)
                    Label("모든 문서", systemImage: "doc.on.doc").tag(LibraryFilter.all)
                    Label("즐겨찾기", systemImage: "star").tag(LibraryFilter.favorites)
                }
                Section("과목") {
                    ForEach(subjects) { subject in
                        Label { Text(subject.name) } icon: { Circle().fill(subject.color).frame(width: 10, height: 10) }
                            .tag(LibraryFilter.subject(subject.id))
                    }
                    .onDelete { offsets in offsets.map { subjects[$0].id }.forEach(deleteSubject) }
                    Button {
                        newSubjectName = ""
                        showingAddSubject = true
                    } label: {
                        Label("과목 추가", systemImage: "plus")
                    }
                }
            }
            .navigationTitle("Noto")
        } detail: {
            content
        }
        .onAppear(perform: reload)
        .sheet(isPresented: $showingSettings) { SettingsView() }
        .alert("새 과목", isPresented: $showingAddSubject) {
            TextField("과목 이름", text: $newSubjectName)
            Button("취소", role: .cancel) {}
            Button("추가") {
                let name = newSubjectName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                SubjectStore.add(name: name)
                subjects = SubjectStore.all()
            }
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.pdf]) { result in
            switch result {
            case .success(let url):
                do { onOpen(try Library.importPDF(from: url)) }
                catch { errorText = error.localizedDescription }
            case .failure(let error):
                errorText = error.localizedDescription
            }
        }
        .confirmationDialog("문서를 삭제할까요?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible, presenting: pendingDelete) { document in
            Button("삭제", role: .destructive) {
                Library.delete(document)
                reload()
            }
        } message: { _ in
            Text("필기도 함께 삭제되며 되돌릴 수 없습니다.")
        }
        .alert("문제가 발생했습니다", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("확인", role: .cancel) {}
        } message: {
            Text(errorText ?? "")
        }
    }

    private var content: some View {
        ScrollView {
            if filtered.isEmpty {
                emptyState.padding(.top, 80)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160, maximum: 220), spacing: 16)], spacing: 20) {
                    ForEach(filtered) { document in
                        DocumentCard(document: document, subject: subjects.first { $0.id == document.subjectID })
                            .onTapGesture { onOpen(document) }
                            .contextMenu { cardMenu(for: document) }
                    }
                }
                .padding()
            }
        }
        .searchable(text: $searchText, prompt: "제목으로 검색")
        .navigationTitle(title(for: filter))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingSettings = true } label: { Image(systemName: "gearshape") }
                    .accessibilityLabel("설정")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { picking = true } label: { Label("PDF 가져오기", systemImage: "doc.badge.plus") }
                    Button(action: addBlankNote) { Label("새 빈 노트", systemImage: "square.and.pencil") }
                } label: {
                    Label("추가", systemImage: "plus")
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.text").font(.system(size: 40)).foregroundStyle(.tertiary)
            Text("문서가 없습니다").font(.headline)
            Text("PDF를 가져오거나 빈 노트를 만들어 시작하세요.").font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private func title(for filter: LibraryFilter?) -> String {
        switch filter {
        case .recent, nil: "최근"
        case .all: "모든 문서"
        case .favorites: "즐겨찾기"
        case .subject(let id): subjects.first { $0.id == id }?.name ?? "과목"
        }
    }

    @ViewBuilder
    private func cardMenu(for document: DocumentFolder) -> some View {
        Button {
            Library.setFavorite(!document.favorite, for: document)
            reload()
        } label: {
            Label(document.favorite ? "즐겨찾기 해제" : "즐겨찾기", systemImage: document.favorite ? "star.slash" : "star")
        }
        Menu("과목 지정") {
            Button("없음") { Library.setSubject(nil, for: document); reload() }
            ForEach(subjects) { subject in
                Button(subject.name) { Library.setSubject(subject.id, for: document); reload() }
            }
        }
        Button(role: .destructive) { pendingDelete = document } label: {
            Label("삭제", systemImage: "trash")
        }
    }

    private func addBlankNote() {
        do { onOpen(try Library.createBlank()) }
        catch { errorText = error.localizedDescription }
    }

    private func deleteSubject(_ id: UUID) {
        SubjectStore.delete(id)
        subjects = SubjectStore.all()
        reload()
    }

    private func reload() {
        documents = Library.all()
        subjects = SubjectStore.all()
    }
}

private struct DocumentCard: View {
    let document: DocumentFolder
    let subject: Subject?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                ThumbnailImage(folder: document, page: 0, width: 320)
                    .aspectRatio(210 / 297, contentMode: .fit) // roughly Letter, until the real page loads
                    .frame(maxWidth: .infinity)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator, lineWidth: 0.5))
                if document.favorite {
                    Image(systemName: "star.fill").font(.caption).foregroundStyle(.yellow).padding(6)
                }
            }
            Text(document.title).font(.subheadline.weight(.medium)).lineLimit(1)
            HStack(spacing: 4) {
                if let subject {
                    Circle().fill(subject.color).frame(width: 6, height: 6)
                }
                Text("\(document.pageCount)쪽 · \(document.modified.formatted(.dateTime.month().day()))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
