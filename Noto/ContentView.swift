import SwiftUI
import PDFKit
import UniformTypeIdentifiers

enum AppInfo {
    // Shown in the UI so a TestFlight tester can tell which build is installed.
    static var version: String {
        let info = Bundle.main.infoDictionary
        return "v\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }
}

struct ContentView: View {
    @State private var documents: [DocumentFolder] = []
    @State private var opened: (folder: DocumentFolder, pdf: PDFDocument, pages: [CGPDFPage])?
    @State private var picking = false
    @State private var showingSettings = false
    @State private var pendingDelete: DocumentFolder?
    @State private var errorText: String?

    var body: some View {
        Group {
            if let current = opened {
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        Button {
                            opened = nil
                            documents = Library.all()
                        } label: {
                            Image(systemName: "chevron.left")
                        }
                        Text(current.folder.title).font(.headline).lineLimit(1)
                        Spacer()
                        Text(AppInfo.version).font(.caption).foregroundStyle(.secondary)
                        Button { showingSettings = true } label: { Image(systemName: "gearshape") }
                            .accessibilityLabel("설정")
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(.bar)
                    PDFNoteView(folder: current.folder, document: current.pdf, pages: current.pages)
                }
            } else {
                library
            }
        }
        .onAppear { documents = Library.all() }
        .sheet(isPresented: $showingSettings) { SettingsView() }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.pdf]) { result in
            switch result {
            case .success(let url):
                do {
                    open(try Library.importPDF(from: url))
                } catch {
                    errorText = error.localizedDescription
                }
            case .failure(let error):
                errorText = error.localizedDescription
            }
        }
        .confirmationDialog("문서를 삭제할까요?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible, presenting: pendingDelete) { document in
            Button("삭제", role: .destructive) {
                Library.delete(document)
                documents = Library.all()
            }
        } message: { _ in
            Text("필기도 함께 삭제되며 되돌릴 수 없습니다.")
        }
        .alert("PDF를 열 수 없습니다", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("확인", role: .cancel) {}
        } message: {
            Text(errorText ?? "")
        }
    }

    private var library: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Noto").font(.largeTitle.bold())
                    Text(AppInfo.version).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { showingSettings = true } label: { Image(systemName: "gearshape") }
                    .accessibilityLabel("설정")
                    .padding(.trailing, 8)
                Button("PDF 열기") { picking = true }
                    .buttonStyle(.borderedProminent)
            }
            .padding()

            if documents.isEmpty {
                Spacer()
                Text("PDF를 열어 필기를 시작하세요.").foregroundStyle(.secondary)
                Spacer()
            } else {
                List {
                    ForEach(documents) { document in
                        Button { open(document) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(document.title).font(.headline)
                                Text(document.modified, format: .dateTime.year().month().day().hour().minute())
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete { offsets in
                        pendingDelete = offsets.first.map { documents[$0] }
                    }
                }
            }
        }
    }

    private func open(_ folder: DocumentFolder) {
        guard let pdf = PDFDocument(url: folder.pdfURL), let pages = pdf.cgPages else {
            errorText = NotAPDF().localizedDescription
            return
        }
        opened = (folder, pdf, pages)
    }
}
