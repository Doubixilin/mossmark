#if os(iOS)
import SwiftUI
import UIKit

/// One immutable file snapshot handed to the iOS share sheet.
///
/// Every snapshot owns a UUID-named directory so concurrent or repeated shares
/// never overwrite each other while the user-facing filename stays unchanged.
struct SharedExportFile: Identifiable, Sendable {
    let id: UUID
    let url: URL

    private let directoryURL: URL

    init(data: Data, filename: String) throws {
        let naturalFilename = URL(fileURLWithPath: filename).lastPathComponent
        guard !naturalFilename.isEmpty,
              naturalFilename != ".",
              naturalFilename != ".."
        else {
            throw CocoaError(.fileWriteInvalidFileName)
        }

        let id = UUID()
        let fileManager = FileManager.default
        let directoryURL = fileManager.temporaryDirectory
            .appendingPathComponent("MossmarkShare", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
        let url = directoryURL.appendingPathComponent(naturalFilename, isDirectory: false)

        do {
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
        } catch {
            try? fileManager.removeItem(at: directoryURL)
            throw error
        }

        self.id = id
        self.url = url
        self.directoryURL = directoryURL
    }

    /// Removes only this snapshot's UUID directory. Repeated calls are safe.
    func cleanup() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}

/// SwiftUI presentation wrapper for the standard iOS share sheet.
///
/// The temporary snapshot is removed after the selected activity finishes or
/// the user dismisses the sheet. Callers may also call `file.cleanup()` from a
/// sheet dismissal fallback because cleanup is intentionally idempotent.
struct IOSShareSheet: UIViewControllerRepresentable {
    typealias Completion = @MainActor (_ completed: Bool, _ error: (any Error)?) -> Void

    let file: SharedExportFile
    let onCompletion: Completion

    init(
        file: SharedExportFile,
        onCompletion: @escaping Completion = { _, _ in }
    ) {
        self.file = file
        self.onCompletion = onCompletion
    }

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let file = file
        let onCompletion = onCompletion
        let controller = UIActivityViewController(
            activityItems: [file.url],
            applicationActivities: nil
        )
        controller.completionWithItemsHandler = { _, completed, _, error in
            file.cleanup()
            onCompletion(completed, error)
        }
        return controller
    }

    func updateUIViewController(
        _ uiViewController: UIActivityViewController,
        context: Context
    ) {}
}
#endif
