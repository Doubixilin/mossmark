import SwiftUI

@main
struct MossmarkMacApp: App {
    init() {
        MossmarkBrandMigration.migrateLegacyDefaults()
    }

    var body: some Scene {
        DocumentGroup(newDocument: MarkdownFileDocument()) { configuration in
            MarkdownDocumentView(
                document: configuration.$document,
                fileURL: configuration.fileURL,
                isEditable: configuration.isEditable
            )
        }
        .commands {
            MossmarkDocumentCommands()
        }

        Settings {
            MossmarkSettingsView()
        }
    }
}
