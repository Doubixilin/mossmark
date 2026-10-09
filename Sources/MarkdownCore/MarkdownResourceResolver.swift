import Foundation

public enum MarkdownResourceResolver {
    /// Resolves a document-relative resource without allowing traversal outside
    /// the Markdown file's containing directory.
    public static func resolve(reference: String, relativeTo documentURL: URL) -> URL? {
        guard documentURL.isFileURL,
              !reference.isEmpty,
              !reference.hasPrefix("#"),
              let decoded = reference.removingPercentEncoding
        else {
            return nil
        }

        if let components = URLComponents(string: decoded), components.scheme != nil {
            return nil
        }

        let pathOnly = decoded.split(separator: "#", maxSplits: 1).first.map(String.init) ?? decoded
        let resourcePath = pathOnly.split(separator: "?", maxSplits: 1).first.map(String.init) ?? pathOnly
        guard !resourcePath.isEmpty, !resourcePath.hasPrefix("/") else {
            return nil
        }

        let root = documentURL.deletingLastPathComponent()
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let candidate = URL(fileURLWithPath: resourcePath, relativeTo: root)
            .standardizedFileURL
            .resolvingSymlinksInPath()

        guard isContained(candidate, in: root) else {
            return nil
        }
        return candidate
    }

    private static func isContained(_ candidate: URL, in root: URL) -> Bool {
        let rootComponents = root.pathComponents
        let candidateComponents = candidate.pathComponents
        guard candidateComponents.count >= rootComponents.count else {
            return false
        }
        return Array(candidateComponents.prefix(rootComponents.count)) == rootComponents
    }

    /// File extensions the in-app web view may serve from the document directory.
    /// Deliberately narrow: images plus the static assets a document can reference.
    private static let servableResourceExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "svg", "avif", "heic", "bmp", "tiff", "tif", "ico",
        "css",
        "woff", "woff2", "ttf", "otf",
    ]

    /// Resolves a resource path requested by the web scheme handler against the
    /// document directory, rejecting hidden path components, paths that escape
    /// the directory, and file types outside the servable allowlist.
    public static func resolveServableResource(path: String, relativeTo root: URL) -> URL? {
        guard root.isFileURL, !path.isEmpty, !path.hasPrefix("/") else {
            return nil
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.hasPrefix(".") }) else {
            return nil
        }
        let pathExtension = (path as NSString).pathExtension.lowercased()
        guard servableResourceExtensions.contains(pathExtension) else {
            return nil
        }

        let standardizedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = standardizedRoot.appendingPathComponent(path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard isContained(candidate, in: standardizedRoot) else {
            return nil
        }
        return candidate
    }
}
