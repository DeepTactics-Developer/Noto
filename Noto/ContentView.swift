import SwiftUI

enum AppInfo {
    // Shown in the UI so a TestFlight tester can tell which build is installed.
    static var version: String {
        let info = Bundle.main.infoDictionary
        return "v\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }
}

struct ContentView: View {
    @State private var opened: DocumentFolder?

    var body: some View {
        if let folder = opened {
            NoteScreen(folder: folder) { opened = nil }
        } else {
            LibraryView { folder in opened = folder }
        }
    }
}
