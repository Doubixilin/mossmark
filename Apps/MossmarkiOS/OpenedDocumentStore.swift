import MarkdownCore
import SwiftUI

/// Owns one document opened from the iOS document library: loads the file,
/// publishes it for `MarkdownDocumentView` to edit, and replaces the
/// DocumentGroup autosave with an explicit one-second debounced save plus
/// flushes when the app backgrounds or the editor is dismissed.
@MainActor
final class OpenedDocumentStore: ObservableObject {
    @Published var document: MarkdownFileDocument {
        didSet { scheduleSave() }
    }
    @Published var saveError: String?

    let fileURL: URL
    let isEditable: Bool

    private var lastSavedSource: String
    private var saveTask: Task<Void, Never>?

    init(fileURL: URL) throws {
        let data = try Data(contentsOf: fileURL)
        let content = try MarkdownDocument(data: data)
        self.fileURL = fileURL
        document = MarkdownFileDocument(content: content)
        lastSavedSource = content.source
        isEditable = FileManager.default.isWritableFile(atPath: fileURL.path)
    }

    private func scheduleSave() {
        guard isEditable else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    /// Writes pending changes to disk atomically. Only writes when the
    /// source actually diverged from the last saved state, so opening a
    /// document without editing never changes its bytes on disk.
    @discardableResult
    func flush() -> Bool {
        saveTask?.cancel()
        saveTask = nil
        guard isEditable else { return true }
        let source = document.content.source
        guard source != lastSavedSource else { return saveError == nil }
        do {
            let wrapper = FileWrapper(regularFileWithContents: document.serializedData())
            try wrapper.write(to: fileURL, options: .atomic, originalContentsURL: nil)
            lastSavedSource = source
            saveError = nil
            return true
        } catch {
            saveError = error.localizedDescription
            return false
        }
    }
}
