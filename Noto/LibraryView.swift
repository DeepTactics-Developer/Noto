import SwiftUI
import UniformTypeIdentifiers

enum LibraryFilter: Hashable {
    case recent, all, favorites, trash, subject(UUID)
}

struct LibraryView: View {
    let onOpen: (DocumentFolder) -> Void

    @State private var documents: [DocumentFolder] = []
    @State private var trashedDocuments: [DocumentFolder] = []
    @State private var subjects: [Subject] = []
    @State private var filter: LibraryFilter? = .recent
    @State private var searchText = ""
    @State private var picking = false
    @State private var showingSettings = false
    @State private var showingAddSubject = false
    @State private var newSubjectName = ""
    @State private var pendingDelete: DocumentFolder?
    @State private var pendingPermanentDelete: DocumentFolder?
    @State private var errorText: String?

    private var filtered: [DocumentFolder] {
        if filter == .trash {
            guard !searchText.isEmpty else { return trashedDocuments }
            return trashedDocuments.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
        }
        var list = documents
        switch filter {
        case .recent, nil: list = Array(list.prefix(20))
        case .all: break
        case .favorites: list = list.filter(\.favorite)
        case .subject(let id): list = list.filter { $0.subjectID == id }
        case .trash: break // handled above
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
                    Label("휴지통", systemImage: "trash").tag(LibraryFilter.trash)
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
        .onAppear {
            Library.purgeExpiredTrash()
            reload()
        }
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
                Library.trash(document)
                reload()
            }
        } message: { _ in
            Text("휴지통으로 이동합니다. \(Library.trashLifetimeDays)일 후 자동으로 완전히 삭제됩니다.")
        }
        .confirmationDialog("완전히 삭제할까요?",
                            isPresented: Binding(get: { pendingPermanentDelete != nil }, set: { if !$0 { pendingPermanentDelete = nil } }),
                            titleVisibility: .visible, presenting: pendingPermanentDelete) { document in
            Button("완전히 삭제", role: .destructive) {
                Library.permanentlyDelete(document)
                reload()
            }
        } message: { _ in
            Text("필기를 포함해 모든 내용이 영구히 삭제되며 되돌릴 수 없습니다.")
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
                            .onTapGesture { if filter != .trash { onOpen(document) } } // restore before reopening
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
            Image(systemName: filter == .trash ? "trash" : "doc.text").font(.system(size: 40)).foregroundStyle(.tertiary)
            Text(filter == .trash ? "휴지통이 비어 있습니다" : "문서가 없습니다").font(.headline)
            if filter != .trash {
                Text("PDF를 가져오거나 빈 노트를 만들어 시작하세요.").font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    private func title(for filter: LibraryFilter?) -> String {
        switch filter {
        case .recent, nil: "최근"
        case .all: "모든 문서"
        case .favorites: "즐겨찾기"
        case .trash: "휴지통"
        case .subject(let id): subjects.first { $0.id == id }?.name ?? "과목"
        }
    }

    @ViewBuilder
    private func cardMenu(for document: DocumentFolder) -> some View {
        if filter == .trash {
            Button {
                Library.restore(document)
                reload()
            } label: {
                Label("복원", systemImage: "arrow.uturn.backward")
            }
            Button(role: .destructive) { pendingPermanentDelete = document } label: {
                Label("완전히 삭제", systemImage: "trash.slash")
            }
        } else {
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
        trashedDocuments = Library.trashedDocuments()
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
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // In the trash, how long until it's gone for good matters more than when it was last edited.
    private var subtitle: String {
        guard let deletedAt = document.deletedAt else {
            return "\(document.pageCount)쪽 · \(document.modified.formatted(.dateTime.month().day()))"
        }
        let daysLeft = Library.trashLifetimeDays - Calendar.current.dateComponents([.day], from: deletedAt, to: .now).day!
        return daysLeft > 0 ? "\(daysLeft)일 후 자동 삭제" : "곧 자동 삭제됨"
    }
}
