import SwiftUI
import PDFKit

enum DrawTool: String, CaseIterable, Identifiable {
    case pen, highlighter, eraser, lasso
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .pen: "pencil"
        case .highlighter: "highlighter"
        case .eraser: "eraser"
        case .lasso: "lasso"
        }
    }
}

// The toolbar's own state, replacing PencilKit's system palette. A plain Equatable value so SwiftUI's
// `.onChange` fires once per real change, however many of its fields moved.
struct ToolState: Equatable {
    var tool: DrawTool = .pen
    var penColor = Color.black
    var penWidth: Double = 3 // page points, before pressure
    var highlighterColor = Color.yellow
    var highlighterWidth: Double = 10

    static let penColors: [Color] = [.black, .blue, .red, .green, .purple, .orange]
    static let highlighterColors: [Color] = [.yellow, .green, .pink, .blue, .orange]
}

// Shared between the SwiftUI top bar/sidebar and the UIKit page viewer inside PDFNoteView.
final class NoteViewModel: ObservableObject {
    @Published var currentPage = 0
    @Published var sidebarVisible = true
    @Published var toolState = ToolState()
    var toolStateDidChange: (() -> Void)?
    var undo: (() -> Void)?
    var redo: (() -> Void)?
    var scrollToPage: ((Int) -> Void)?
    var showMatch: ((Int, CGRect) -> Void)? // page index, rect in that page's own point space (top-left origin)
    var insertText: (() -> Void)?
    var insertImage: (() -> Void)?
    var pasteInk: (() -> Void)?
}

struct SearchMatch: Identifiable {
    let id = UUID()
    let page: Int
    let rect: CGRect
}

struct NoteScreen: View {
    let folder: DocumentFolder
    let onClose: () -> Void

    @State private var pdf: PDFDocument?
    @State private var pages: [CGPDFPage] = []
    @State private var bookmarks: Set<Int> = []
    @State private var errorText: String?
    @State private var showingSettings = false
    @State private var showingSearch = false
    @State private var searchQuery = ""
    @State private var matches: [SearchMatch] = []
    @State private var matchIndex: Int?
    @StateObject private var model = NoteViewModel()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button(action: onClose) { Image(systemName: "chevron.left") }
                    .accessibilityLabel("라이브러리로")
                if showingSearch {
                    searchBar
                } else {
                    Text(folder.title).font(.subheadline.weight(.medium)).lineLimit(1).frame(maxWidth: 90, alignment: .leading)
                    if pdf != nil {
                        Divider().frame(height: 20)
                        toolGroup
                        Divider().frame(height: 20)
                        ToolbarIconButton(systemName: "arrow.uturn.backward") { model.undo?() }
                            .accessibilityLabel("실행 취소")
                        ToolbarIconButton(systemName: "arrow.uturn.forward") { model.redo?() }
                            .accessibilityLabel("다시 실행")
                        Menu {
                            Button { model.insertText?() } label: { Label("텍스트 추가", systemImage: "textformat") }
                            Button { model.insertImage?() } label: { Label("이미지 추가", systemImage: "photo") }
                            Button { model.pasteInk?() } label: { Label("필기 붙여넣기", systemImage: "doc.on.clipboard") }
                        } label: {
                            Image(systemName: "plus.circle").font(.system(size: 16)).frame(width: 30, height: 30)
                        }
                        .accessibilityLabel("추가")
                    }
                    Spacer(minLength: 4)
                    if pdf != nil {
                        ToolbarIconButton(systemName: "magnifyingglass") { showingSearch = true }
                            .accessibilityLabel("검색")
                        // Recording and AI aren't built yet — shown so the layout already has their place, greyed out.
                        ToolbarIconButton(systemName: "mic", disabled: true) {}
                            .accessibilityLabel("음성 녹음, 준비 중")
                        ToolbarIconButton(systemName: "sparkles", disabled: true) {}
                            .accessibilityLabel("AI, 준비 중")
                        Divider().frame(height: 20)
                        ToolbarIconButton(systemName: bookmarks.contains(model.currentPage) ? "bookmark.fill" : "bookmark", action: toggleBookmark)
                            .accessibilityLabel("이 페이지 북마크")
                    }
                    ToolbarIconButton(systemName: "sidebar.left") { model.sidebarVisible.toggle() }
                        .accessibilityLabel("사이드바")
                    ToolbarIconButton(systemName: "gearshape") { showingSettings = true }
                        .accessibilityLabel("설정")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.bar)

            Divider()

            if let pdf {
                ZStack(alignment: .top) {
                    HStack(spacing: 0) {
                        if model.sidebarVisible {
                            DocumentSidebar(folder: folder, pdf: pdf, pageCount: pages.count, bookmarks: $bookmarks, model: model)
                                .frame(width: 150)
                                .background(.bar)
                            Divider()
                        }
                        PDFNoteView(folder: folder, document: pdf, pages: pages, model: model)
                    }
                    if model.toolState.tool == .pen || model.toolState.tool == .highlighter {
                        ToolOptionsPill(toolState: $model.toolState)
                            .padding(.top, 10)
                    }
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
        .onChange(of: model.toolState) { _, _ in model.toolStateDidChange?() }
    }

    private var toolGroup: some View {
        HStack(spacing: 2) {
            ForEach(DrawTool.allCases) { tool in
                ToolbarIconButton(systemName: tool.icon, selected: model.toolState.tool == tool) {
                    model.toolState.tool = tool
                }
            }
        }
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

    // MARK: Search

    private var searchBar: some View {
        HStack(spacing: 10) {
            TextField("PDF에서 검색", text: $searchQuery)
                .textFieldStyle(.roundedBorder)
                .submitLabel(.search)
                .onSubmit(runSearch)
            if !matches.isEmpty {
                Text("\((matchIndex ?? 0) + 1)/\(matches.count)").font(.caption).foregroundStyle(.secondary)
                Button { step(-1) } label: { Image(systemName: "chevron.up") }
                Button { step(1) } label: { Image(systemName: "chevron.down") }
            } else if !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty {
                Text("결과 없음").font(.caption).foregroundStyle(.secondary)
            }
            Button {
                showingSearch = false
                searchQuery = ""
                matches = []
                matchIndex = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .foregroundStyle(.secondary)
        }
    }

    private func runSearch() {
        guard let pdf else { return }
        let query = searchQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            matches = []
            matchIndex = nil
            return
        }
        matches = pdf.findString(query, withOptions: [.caseInsensitive]).compactMap { selection -> SearchMatch? in
            guard let page = selection.pages.first else { return nil }
            // Unverified whether PDFKit's PDFPage.bounds(for:) already swaps width/height for a 90°/270°-rotated
            // page the way our own CGPDFPage-based sizing does elsewhere (PageViews.swift, PDFNoteViewController).
            // If a highlight lands wrong specifically on a rotated PDF, check this first.
            let natural = page.bounds(for: .cropBox).size
            guard natural.height > 0 else { return nil }
            let bottomLeft = selection.bounds(for: page) // origin bottom-left, PDF's own convention
            let topLeft = CGRect(x: bottomLeft.minX, y: natural.height - bottomLeft.maxY, width: bottomLeft.width, height: bottomLeft.height)
            return SearchMatch(page: pdf.index(for: page), rect: topLeft)
        }
        .sorted { $0.page < $1.page }
        matchIndex = matches.isEmpty ? nil : 0
        if let first = matches.first { model.showMatch?(first.page, first.rect) }
    }

    private func step(_ delta: Int) {
        guard !matches.isEmpty else { return }
        let next = ((matchIndex ?? 0) + delta + matches.count) % matches.count
        matchIndex = next
        model.showMatch?(matches[next].page, matches[next].rect)
    }
}

// MARK: - Toolbar

private struct ToolbarIconButton: View {
    let systemName: String
    var selected: Bool = false
    var disabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 16))
                .frame(width: 30, height: 30)
                .background(selected ? Color.accentColor.opacity(0.15) : .clear)
                .foregroundStyle(selected ? Color.accentColor : (disabled ? Color.secondary.opacity(0.4) : Color.primary))
                .clipShape(RoundedRectangle(cornerRadius: 7))
        }
        .disabled(disabled)
        .buttonStyle(.plain)
    }
}

// Floats above the page when the pen or highlighter is selected: color swatches, a custom color well, and a
// width slider. Which fields it edits depends on which of the two tools is currently active.
private struct ToolOptionsPill: View {
    @Binding var toolState: ToolState

    private var isHighlighter: Bool { toolState.tool == .highlighter }
    private var widthRange: ClosedRange<Double> { isHighlighter ? 4...24 : 1...10 }
    private var currentColor: Binding<Color> { isHighlighter ? $toolState.highlighterColor : $toolState.penColor }
    private var currentWidth: Binding<Double> { isHighlighter ? $toolState.highlighterWidth : $toolState.penWidth }

    var body: some View {
        HStack(spacing: 10) {
            ForEach(isHighlighter ? ToolState.highlighterColors : ToolState.penColors, id: \.self) { color in
                Circle()
                    .fill(color)
                    .frame(width: 20, height: 20)
                    .overlay(Circle().stroke(.primary, lineWidth: currentColor.wrappedValue == color ? 2 : 0).padding(-2))
                    .onTapGesture { currentColor.wrappedValue = color }
            }
            ColorPicker("사용자 지정 색상", selection: currentColor).labelsHidden().frame(width: 20, height: 20)
            Divider().frame(height: 20)
            Slider(value: currentWidth, in: widthRange, step: 1).frame(width: 90)
            Text("\(Int(currentWidth.wrappedValue))").font(.caption).monospacedDigit().foregroundStyle(.secondary).frame(width: 16)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(.separator, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
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
