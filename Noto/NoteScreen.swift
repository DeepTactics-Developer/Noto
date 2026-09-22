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
                Button { model.sidebarVisible.toggle() } label: { Image(systemName: "sidebar.left") }
                    .accessibilityLabel("썸네일")
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
                        ThumbnailSidebar(folder: folder, pageCount: pages.count, model: model)
                            .frame(width: 130)
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
    }
}

struct ThumbnailSidebar: View {
    let folder: DocumentFolder
    let pageCount: Int
    @ObservedObject var model: NoteViewModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(0..<pageCount, id: \.self) { index in
                        Button { model.scrollToPage?(index) } label: {
                            VStack(spacing: 4) {
                                ThumbnailImage(folder: folder, page: index, width: 220)
                                    .aspectRatio(contentMode: .fit)
                                    .background(Color.white)
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 4)
                                            .stroke(index == model.currentPage ? Color.accentColor : Color.gray.opacity(0.3),
                                                   lineWidth: index == model.currentPage ? 2 : 0.5)
                                    )
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
