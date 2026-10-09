import SwiftUI

@main
struct MossmarkiOSApp: App {
    @StateObject private var readingHistory = ReadingHistory()

    var body: some Scene {
        // The system DocumentGroup browser is replaced by the self-built
        // document library: iOS 26.x has OS-level races in the browser
        // (failed new-document imports, stale Recents) and its "Connect to
        // Server" entry cannot be disabled.
        WindowGroup {
            DocumentLibraryView()
                .environmentObject(readingHistory)
        }
        .commands {
            MossmarkDocumentCommands()
        }
    }
}
