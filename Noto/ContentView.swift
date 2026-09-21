import SwiftUI
import PDFKit
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var opened: PDFDocument?
    @State private var title = ""
    @State private var picking = false
    @State private var errorText: String?

    var body: some View {
        Group {
            if let document = opened {
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        Button { opened = nil } label: { Image(systemName: "chevron.left") }
                        Text(title).font(.headline).lineLimit(1)
                        Spacer()
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(.bar)
                    PDFNoteView(document: document)
                }
            } else {
                VStack(spacing: 16) {
                    Text("Noto").font(.largeTitle.bold())
                    Button("PDF 열기") { picking = true }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.pdf]) { result in
            guard case .success(let url) = result else { return }
            open(url)
        }
        .alert("PDF를 열 수 없습니다", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("확인", role: .cancel) {}
        } message: {
            Text(errorText ?? "")
        }
    }

    // Copies the picked file into the app's own storage so sidecar data can live next to it later.
    private func open(_ source: URL) {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let folder = URL.documentsDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let copy = folder.appending(path: "source.pdf")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: copy)
        } catch {
            errorText = error.localizedDescription
            return
        }
        guard let document = PDFDocument(url: copy) else {
            errorText = "파일이 올바른 PDF가 아닙니다."
            return
        }
        title = source.deletingPathExtension().lastPathComponent
        opened = document
    }
}
