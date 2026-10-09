import Foundation
import MarkdownCore
import UniformTypeIdentifiers
import WebKit

final class MarkdownEditorAssetSchemeHandler: NSObject, WKURLSchemeHandler, @unchecked Sendable {
    nonisolated static let scheme = "markdown-editor"

    private let lock = NSLock()
    private let engineRoot: URL?
    private var resourceRoot: URL?

    var hasEngineResources: Bool { engineRoot != nil }

    init(bundle: Bundle = .main) {
        let candidates = bundle.resourceURL.map { resourceURL in
            [
                resourceURL.appendingPathComponent("dist", isDirectory: true),
                resourceURL.appendingPathComponent("EditorEngine", isDirectory: true),
            ]
        } ?? []
        engineRoot = candidates.first(where: {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("index.html").path)
        })?.standardizedFileURL.resolvingSymlinksInPath()
        super.init()
    }

    func update(documentURL: URL?) {
        lock.lock()
        resourceRoot = documentURL?.deletingLastPathComponent()
            .standardizedFileURL
            .resolvingSymlinksInPath()
        lock.unlock()
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let requestURL = urlSchemeTask.request.url,
              let resolved = resolve(requestURL: requestURL),
              let values = try? resolved.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
              values.isRegularFile == true,
              (values.fileSize ?? 0) <= 100 * 1_024 * 1_024,
              let data = try? Data(contentsOf: resolved)
        else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }

        let mimeType = UTType(filenameExtension: resolved.pathExtension)?.preferredMIMEType
            ?? "application/octet-stream"
        let response = URLResponse(
            url: requestURL,
            mimeType: mimeType,
            expectedContentLength: data.count,
            textEncodingName: mimeType.hasPrefix("text/") || mimeType.contains("javascript")
                ? "utf-8"
                : nil
        )
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}

    private func resolve(requestURL: URL) -> URL? {
        let rawPath = requestURL.path.removingPercentEncoding ?? requestURL.path
        let relativePath = rawPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let enginePath = relativePath.isEmpty ? "index.html" : relativePath

        if enginePath == "index.html" || enginePath.hasPrefix("assets/") {
            guard let engineRoot else { return nil }
            return containedURL(path: enginePath, root: engineRoot)
        }

        lock.lock()
        let root = resourceRoot
        lock.unlock()
        guard let root else { return nil }
        return MarkdownResourceResolver.resolveServableResource(path: enginePath, relativeTo: root)
    }

    private func containedURL(path: String, root: URL) -> URL? {
        guard !path.hasPrefix("/"), !path.isEmpty else { return nil }
        let candidate = root.appendingPathComponent(path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let rootComponents = root.pathComponents
        let candidateComponents = candidate.pathComponents
        guard candidateComponents.count >= rootComponents.count,
              Array(candidateComponents.prefix(rootComponents.count)) == rootComponents
        else {
            return nil
        }
        return candidate
    }
}
