import SwiftUI
import PDFKit

// Shared between the SwiftUI top bar/sidebar and the UIKit page viewer inside PDFNoteView.
final class NoteViewModel: ObservableObject {
    @Published var currentPage = 0
    @Published var sidebarVisible = true
    var scrollToPage: ((Int) -> Void)?
}

struct NoteScreen: View {
    let folder: DocumentFolder
    let onClose: () -> Void

    @State private var pdf: PDFDocument?
    @State private var pages: [CGPDFPage] = []
    @State private var bookmarks: Set<Int> = []
    @State private var errorText: String?
    @State private var showingSettings = false
    @StateObject private var model = NoteViewModel()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button(action: onClose) { Image(systemName: "chevron.left") }
                    .accessibilityLabel("라이브러리로")
                Text(folder.title).font(.headline).lineLimit(1)
                Spacer()
                Text(AppInfo.version).font(.caption).foregroundStyle(.secondary)
                if pdf != nil {
                    Button(action: toggleBookmark) {
                        Image(systemName: bookmarks.contains(model.currentPage) ? "bookmark.fill" : "bookmark")
                    }
                    .accessibilityLabel("이 페이지 북마크")
                }
                Button { model.sidebarVisible.toggle() } label: { Image(systemName: "sidebar.left") }
                    .accessibilityLabel("사이드바")
                Button { showingSettings = true } label: { Image(systemName: "gearshape") }
                    .accessibilityLabel("설정")
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.bar)

            Divider()

            if let pdf {
                HStack(spacing: 0) {
                    if model.sidebarVisible {
                        DocumentSidebar(folder: folder, pdf: pdf, pageCount: pages.count, bookmarks: $bookmarks, model: model)
                            .frame(width: 150)
                            .background(.bar)
                        Divider()
                    }
                    PDFNoteView(folder: folder, document: pdf, pages: pages, model: model)
                }
            } else if let errorText {
                Spacer()
                Text(errorText).foregroundStyle(.secondary)
                Spacer()
            } else {
                Spacer()
                ProgressView()
                Spacer()
            }
        }
        .sheet(isPresented: $showingSettings) { SettingsView() }
        .onAppear(perform: load)
    }

    private func load() {
        guard let doc = PDFDocument(url: folder.pdfURL), let cgPages = doc.cgPages else {
            errorText = NotAPDF().localizedDescription
            return
        }
        pdf = doc
        pages = cgPages
        bookmarks = Library.bookmarkedPages(for: folder)
    }

    private func toggleBookmark() {
        Library.toggleBookmark(model.currentPage, for: folder)
        bookmarks = Library.bookmarkedPages(for: folder)
    }
}

// MARK: - Sidebar

private enum SidebarTab: String, CaseIterable, Identifiable {
    case thumbnails, outline, bookmarks
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .thumbnails: "square.grid.2x2"
        case .outline: "list.bullet"
        case .bookmarks: "bookmark"
        }
    }
}

private struct DocumentSidebar: View {
    let folder: DocumentFolder
    let pdf: PDFDocument
    let pageCount: Int
    @Binding var bookmarks: Set<Int>
    @ObservedObject var model: NoteViewModel
    @State private var tab: SidebarTab = .thumbnails

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(SidebarTab.allCases) { Image(systemName: $0.icon).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)

            switch tab {
            case .thumbnails:
                ThumbnailList(folder: folder, pageCount: pageCount, bookmarks: bookmarks, model: model)
            case .outline:
                OutlineList(items: pdf.flatOutline, model: model)
            case .bookmarks:
                BookmarkList(folder: folder, bookmarks: bookmarks, model: model)
            }
        }
    }
}

private struct SidebarEmptyState: View {
    let icon: String
    let text: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon).font(.title2).foregroundStyle(.tertiary)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.top, 40)
    }
}

private struct ThumbnailList: View {
    let folder: DocumentFolder
    let pageCount: Int
    let bookmarks: Set<Int>
    @ObservedObject var model: NoteViewModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(0..<pageCount, id: \.self) { index in
                        Button { model.scrollToPage?(index) } label: {
                            VStack(spacing: 4) {
                                ZStack(alignment: .topTrailing) {
                                    ThumbnailImage(folder: folder, page: index, width: 220)
                                        .aspectRatio(contentMode: .fit)
                                        .background(Color.white)
                                        .clipShape(RoundedRectangle(cornerRadius: 4))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 4)
                                                .stroke(index == model.currentPage ? Color.accentColor : Color.gray.opacity(0.3),
                                                       lineWidth: index == model.currentPage ? 2 : 0.5)
                                        )
                                    if bookmarks.contains(index) {
                                        Image(systemName: "bookmark.fill")
                                            .font(.system(size: 10))
                                            .foregroundStyle(.orange)
                                            .padding(3)
                                    }
                                }
                                Text("\(index + 1)").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .id(index)
                    }
                }
                .padding(8)
            }
            .onChange(of: model.currentPage) { _, page in
                withAnimation { proxy.scrollTo(page, anchor: .center) }
            }
        }
    }
}

private struct OutlineList: View {
    let items: [OutlineItem]
    @ObservedObject var model: NoteViewModel

    var body: some View {
        ScrollView {
            if items.isEmpty {
                SidebarEmptyState(icon: "list.bullet", text: "목차가 없습니다")
            } else {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(items) { item in
                        Button { model.scrollToPage?(item.pageIndex) } label: {
                            Text(item.title)
                                .font(.caption)
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 6)
                                .padding(.leading, CGFloat(item.depth) * 12 + 8)
                                .padding(.trailing, 8)
                                .background(item.pageIndex == model.currentPage ? Color.accentColor.opacity(0.12) : .clear)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }
}

private struct BookmarkList: View {
    let folder: DocumentFolder
    let bookmarks: Set<Int>
    @ObservedObject var model: NoteViewModel

    var body: some View {
        let pages = bookmarks.sorted()
        ScrollView {
            if pages.isEmpty {
                SidebarEmptyState(icon: "bookmark", text: "북마크한 페이지가 없습니다")
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(pages, id: \.self) { page in
                        Button { model.scrollToPage?(page) } label: {
                            HStack(spacing: 8) {
                                ThumbnailImage(folder: folder, page: page, width: 120)
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: 44)
                                    .background(Color.white)
                                    .clipShape(RoundedRectangle(cornerRadius: 3))
                                Text("페이지 \(page + 1)").font(.caption)
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(8)
            }
        }
    }
}

// MARK: - PDF outline (table of contents), read straight from the PDF's own bookmarks/outline.

struct OutlineItem: Identifiable {
    let id = UUID()
    let title: String
    let pageIndex: Int
    let depth: Int
}

extension PDFDocument {
    var flatOutline: [OutlineItem] {
        guard let root = outlineRoot else { return [] }
        var items: [OutlineItem] = []
        func walk(_ outline: PDFOutline, depth: Int) {
            for i in 0..<outline.numberOfChildren {
                guard let child = outline.child(at: i) else { continue }
                if let label = child.label, !label.isEmpty, let page = child.destination?.page {
                    items.append(OutlineItem(title: label, pageIndex: index(for: page), depth: depth))
                }
                walk(child, depth: depth + 1)
            }
        }
        walk(root, depth: 0)
        return items
    }
}
