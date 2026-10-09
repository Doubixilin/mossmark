import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum MarkdownAssetManager {
    public enum ImportError: LocalizedError, Equatable {
        case invalidDocumentURL
        case invalidSource
        case resourceTooLarge
        case destinationUnavailable

        public var errorDescription: String? {
            switch self {
            case .invalidDocumentURL:
                "Save the Markdown document before importing an image."
            case .invalidSource:
                "The selected item is not a regular file."
            case .resourceTooLarge:
                "The selected image is larger than 100 MB."
            case .destinationUnavailable:
                "Mossmark could not create a safe relative image path."
            }
        }
    }

    public static let maximumResourceSize = 100 * 1_024 * 1_024

    /// Validates and imports an image chosen from a file provider. Some iOS
    /// providers expose camera images as generic files instead of `UTType.image`,
    /// so validation must be based on the bytes rather than only the picker type.
    public static func importImage(
        at sourceURL: URL,
        relativeTo documentURL: URL,
        fileManager: FileManager = .default
    ) throws -> String {
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
              CGImageSourceGetCount(source) > 0
        else {
            throw ImportError.invalidSource
        }
        return try importResource(
            at: sourceURL,
            relativeTo: documentURL,
            fileManager: fileManager
        )
    }

    /// Imports image bytes supplied by PhotosPicker into the same portable,
    /// document-relative `images/` directory used by file imports.
    public static func importImage(
        data: Data,
        suggestedFilename: String = "image",
        relativeTo documentURL: URL,
        fileManager: FileManager = .default
    ) throws -> String {
        guard !data.isEmpty,
              data.count <= maximumResourceSize,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0
        else {
            if data.count > maximumResourceSize { throw ImportError.resourceTooLarge }
            throw ImportError.invalidSource
        }

        let sourceType = CGImageSourceGetType(source) as String?
        let pathExtension = sourceType
            .flatMap(UTType.init)
            .flatMap(\.preferredFilenameExtension)
            ?? "img"
        let stagingDirectory = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(
            at: stagingDirectory,
            withIntermediateDirectories: true
        )
        defer { try? fileManager.removeItem(at: stagingDirectory) }

        let rawBaseName = URL(fileURLWithPath: suggestedFilename)
            .deletingPathExtension()
            .lastPathComponent
        let safeBaseName = sanitizedImageBaseName(rawBaseName)
        let stagingFile = stagingDirectory
            .appendingPathComponent(safeBaseName)
            .appendingPathExtension(pathExtension)
        try data.write(to: stagingFile, options: .atomic)
        return try importResource(
            at: stagingFile,
            relativeTo: documentURL,
            fileManager: fileManager
        )
    }

    /// Copies a file into a portable document-relative resource directory.
    /// Files already inside the document directory are left in place.
    public static func importResource(
        at sourceURL: URL,
        relativeTo documentURL: URL,
        directoryName: String = "images",
        fileManager: FileManager = .default
    ) throws -> String {
        guard documentURL.isFileURL else {
            throw ImportError.invalidDocumentURL
        }
        let source = sourceURL.standardizedFileURL.resolvingSymlinksInPath()
        guard source.isFileURL,
              let values = try? source.resourceValues(forKeys: [
                  .isRegularFileKey,
                  .fileSizeKey,
              ]),
              values.isRegularFile == true
        else {
            throw ImportError.invalidSource
        }
        guard (values.fileSize ?? 0) <= maximumResourceSize else {
            throw ImportError.resourceTooLarge
        }

        if let existingPath = relativeMarkdownPath(
            for: source,
            relativeTo: documentURL
        ) {
            return existingPath
        }

        let root = documentURL.deletingLastPathComponent()
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let unresolvedResourceDirectory = root
            .appendingPathComponent(sanitizedDirectoryName(directoryName), isDirectory: true)
            .standardizedFileURL
        try fileManager.createDirectory(
            at: unresolvedResourceDirectory,
            withIntermediateDirectories: true
        )
        let resourceDirectory = unresolvedResourceDirectory.resolvingSymlinksInPath()
        guard isContained(resourceDirectory, in: root), resourceDirectory != root else {
            throw ImportError.destinationUnavailable
        }

        let destination = uniqueDestination(
            for: source,
            in: resourceDirectory,
            fileManager: fileManager
        )
        try fileManager.copyItem(at: source, to: destination)
        guard let relativePath = relativeMarkdownPath(
            for: destination,
            relativeTo: documentURL
        ) else {
            try? fileManager.removeItem(at: destination)
            throw ImportError.destinationUnavailable
        }
        return relativePath
    }

    public static func relativeMarkdownPath(
        for resourceURL: URL,
        relativeTo documentURL: URL
    ) -> String? {
        guard documentURL.isFileURL, resourceURL.isFileURL else { return nil }
        let root = documentURL.deletingLastPathComponent()
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let resource = resourceURL.standardizedFileURL.resolvingSymlinksInPath()
        let rootComponents = root.pathComponents
        let resourceComponents = resource.pathComponents
        guard resourceComponents.count > rootComponents.count,
              Array(resourceComponents.prefix(rootComponents.count)) == rootComponents
        else {
            return nil
        }

        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return resourceComponents.dropFirst(rootComponents.count)
            .compactMap { $0.addingPercentEncoding(withAllowedCharacters: allowed) }
            .joined(separator: "/")
    }

    private static func isContained(_ candidate: URL, in root: URL) -> Bool {
        let rootComponents = root.pathComponents
        let candidateComponents = candidate.pathComponents
        guard candidateComponents.count >= rootComponents.count else { return false }
        return Array(candidateComponents.prefix(rootComponents.count)) == rootComponents
    }

    private static func sanitizedDirectoryName(_ value: String) -> String {
        let candidate = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty,
              candidate != ".",
              candidate != "..",
              !candidate.contains("/"),
              !candidate.contains("\\")
        else {
            return "images"
        }
        return candidate
    }

    private static func sanitizedImageBaseName(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let cleaned = value.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "-" }
        let candidate = String(cleaned).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return candidate.isEmpty ? "image" : candidate
    }

    private static func uniqueDestination(
        for sourceURL: URL,
        in directory: URL,
        fileManager: FileManager
    ) -> URL {
        let originalName = sourceURL.deletingPathExtension().lastPathComponent
        let baseName = originalName.isEmpty ? "image" : originalName
        let pathExtension = sourceURL.pathExtension

        for suffix in 1...10_000 {
            let name = suffix == 1 ? baseName : "\(baseName)-\(suffix)"
            let candidate = pathExtension.isEmpty
                ? directory.appendingPathComponent(name)
                : directory.appendingPathComponent(name).appendingPathExtension(pathExtension)
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return directory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(pathExtension)
    }
}
