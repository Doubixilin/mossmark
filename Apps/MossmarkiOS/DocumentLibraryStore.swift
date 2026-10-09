import MarkdownCore
import SwiftUI
import UniformTypeIdentifiers

/// One Markdown file inside the document library, flattened out of the
/// recursive `Documents/` scan.
struct LibraryDocument: Identifiable, Hashable {
    let url: URL
    let name: String
    /// Containing directory relative to the library root; nil at the root.
    let relativeDirectory: String?
    let modifiedAt: Date

    var id: URL { url }
}

enum LibraryRenameError: LocalizedError {
    case invalidName
    case nameExists(String)

    var errorDescription: String? {
        switch self {
        case .invalidName:
            String(localized: "library.error.invalid-name")
        case let .nameExists(name):
            String.localizedStringWithFormat(
                String(localized: "library.error.name-exists %@"),
                name
            )
        }
    }
}

/// Scans and mutates the iOS document library rooted at the app's
/// `Documents/` directory. Folder management is intentionally out of scope
/// for v1; nested files are listed flat with their relative path.
@MainActor
final class DocumentLibraryStore: ObservableObject {
    @Published private(set) var documents: [LibraryDocument] = []

    static let supportedExtensions: Set<String> = ["md", "markdown", "mdown", "mkd"]

    let rootDirectory: URL

    /// Monotonically identifies directory scans. A refresh started before a
    /// file mutation must never publish its now-stale snapshot afterward.
    private var refreshGeneration = 0

    init(rootDirectory: URL? = nil) {
        self.rootDirectory = rootDirectory
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    func refresh() async {
        refreshGeneration &+= 1
        let generation = refreshGeneration
        let root = rootDirectory.standardizedFileURL
        let extensions = Self.supportedExtensions
        let scannedDocuments = await Task.detached(priority: .utility) {
            Self.scan(root: root, extensions: extensions)
        }.value
        guard generation == refreshGeneration else { return }
        documents = scannedDocuments
    }

    /// Creates a new empty document in the library root with a unique name
    /// (未命名.md, 未命名 2.md, …) and returns its URL.
    @discardableResult
    func createDocument() async throws -> URL {
        let url = uniqueURL(
            baseName: String(localized: "library.untitled"),
            extension: "md",
            in: rootDirectory
        )
        try Data().write(to: url, options: .atomic)
        await refresh()
        return url
    }

    /// Imports an external file (Files app, share sheet, document picker)
    /// into the library root, de-duplicating the file name on collision.
    @discardableResult
    func importDocument(from sourceURL: URL) async throws -> URL {
        let accessed = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessed { sourceURL.stopAccessingSecurityScopedResource() }
        }
        let destination = uniqueURL(
            baseName: sourceURL.deletingPathExtension().lastPathComponent,
            extension: sourceURL.pathExtension.isEmpty ? "md" : sourceURL.pathExtension,
            in: rootDirectory
        )
        try FileManager.default.copyItem(at: sourceURL, to: destination)
        await refresh()
        return destination
    }

    /// Renames the document in place, keeping its directory and extension.
    @discardableResult
    func rename(_ document: LibraryDocument, to newBaseName: String) async throws -> URL {
        let trimmed = newBaseName.trimmingCharacters(in: .whitespacesAndNewlines)
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        guard !trimmed.isEmpty,
              trimmed != ".",
              trimmed != "..",
              trimmed.rangeOfCharacter(from: invalid) == nil
        else {
            throw LibraryRenameError.invalidName
        }
        let directory = document.url.deletingLastPathComponent()
        let destination = directory
            .appendingPathComponent(trimmed)
            .appendingPathExtension(document.url.pathExtension)
        guard destination.standardizedFileURL != document.url.standardizedFileURL else {
            return document.url
        }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw LibraryRenameError.nameExists(destination.lastPathComponent)
        }
        try FileManager.default.moveItem(at: document.url, to: destination)
        await refresh()
        return destination
    }

    /// Duplicates the document next to the original as "xxx 副本.md".
    @discardableResult
    func duplicate(_ document: LibraryDocument) async throws -> URL {
        let copyBaseName = String.localizedStringWithFormat(
            String(localized: "library.copy-name %@"),
            document.url.deletingPathExtension().lastPathComponent
        )
        let destination = uniqueURL(
            baseName: copyBaseName,
            extension: document.url.pathExtension,
            in: document.url.deletingLastPathComponent()
        )
        try FileManager.default.copyItem(at: document.url, to: destination)
        await refresh()
        return destination
    }

    func delete(_ document: LibraryDocument) async throws {
        // Invalidate any scan that may already have enumerated this URL. Its
        // result can otherwise arrive after the deletion and resurrect the
        // row until another refresh happens.
        refreshGeneration &+= 1
        try FileManager.default.removeItem(at: document.url)
        let deletedURL = document.url.standardizedFileURL
        documents.removeAll { $0.url.standardizedFileURL == deletedURL }
        await refresh()
    }

    // MARK: - Scanning and naming

    nonisolated private static func scan(
        root: URL,
        extensions: Set<String>
    ) -> [LibraryDocument] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        var result: [LibraryDocument] = []
        for case let url as URL in enumerator {
            guard extensions.contains(url.pathExtension.lowercased()),
                  let values = try? url.resourceValues(
                      forKeys: [.isRegularFileKey, .contentModificationDateKey]
                  ),
                  values.isRegularFile == true
            else {
                continue
            }
            let directory = url.deletingLastPathComponent().standardizedFileURL.path
            var relativeDirectory: String?
            if directory.hasPrefix(rootPath) {
                let relative = String(directory.dropFirst(rootPath.count))
                relativeDirectory = relative.isEmpty ? nil : relative
            }
            result.append(LibraryDocument(
                url: url,
                name: url.lastPathComponent,
                relativeDirectory: relativeDirectory,
                modifiedAt: values.contentModificationDate ?? .distantPast
            ))
        }
        return result.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    private func uniqueURL(baseName: String, extension: String, in directory: URL) -> URL {
        let fileManager = FileManager.default
        var candidate = directory
            .appendingPathComponent(baseName)
            .appendingPathExtension(`extension`)
        var counter = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = directory
                .appendingPathComponent("\(baseName) \(counter)")
                .appendingPathExtension(`extension`)
            counter += 1
        }
        return candidate
    }
}
