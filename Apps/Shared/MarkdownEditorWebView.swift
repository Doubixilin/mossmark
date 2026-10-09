import MarkdownCore
import SwiftUI
import WebKit

#if os(macOS)
import AppKit
#else
import UIKit
#endif

private enum BridgedImageImportError: Error {
    case resourceTooLarge
}

@MainActor
struct MarkdownEditorWebView {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Binding var document: MarkdownFileDocument
    let fileURL: URL?
    let isEditable: Bool
    let controller: MarkdownEditorController
    /// Preferred mode for the very first document load; applied only while
    /// the controller still sits at its default mode.
    var initialMode: MarkdownEditorMode = .preview
    /// Called once, after the first document load has been applied to the
    /// engine. Used by the iOS library to restore the reading progress.
    var onInitialLoadComplete: (() async -> Void)?
    /// Called when the reader's scroll progress changes (reported by the
    /// engine after scrolling settles in preview mode).
    var onScrollProgress: ((Double) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    fileprivate func makeWebView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(context.coordinator, name: "markdownBridge")
        configuration.setURLSchemeHandler(
            context.coordinator.schemeHandler,
            forURLScheme: MarkdownEditorAssetSchemeHandler.scheme
        )

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.pageZoom = pageZoom
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = false
        context.coordinator.connect(webView: webView)
        context.coordinator.update(parent: self)
        if context.coordinator.schemeHandler.hasEngineResources {
            webView.load(URLRequest(url: URL(string: "markdown-editor://local/index.html")!))
        } else {
            controller.postStatus(
                String(localized: "error.editor.resources-missing"),
                severity: .error
            )
        }
        return webView
    }

    fileprivate func updateWebView(_ webView: WKWebView, context: Context) {
        webView.pageZoom = pageZoom
        context.coordinator.update(parent: self)
        context.coordinator.synchronizeDocumentIfNeeded()
    }

    private var pageZoom: CGFloat {
        switch dynamicTypeSize {
        case .xSmall: 0.9
        case .small: 0.95
        case .medium: 0.98
        case .large: 1
        case .xLarge: 1.08
        case .xxLarge: 1.16
        case .xxxLarge: 1.25
        case .accessibility1: 1.35
        case .accessibility2: 1.5
        case .accessibility3: 1.65
        case .accessibility4: 1.8
        case .accessibility5: 2
        @unknown default: 1
        }
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var parent: MarkdownEditorWebView
        let schemeHandler: MarkdownEditorAssetSchemeHandler

        private weak var webView: WKWebView?
        private var editorReady = false
        private var lastSynchronizedMarkdown: String?
        private var lastSynchronizedEditable: Bool?
        private var revision = 0
        private var hasPresentedUnsafeWarning = false
        private var allowsRecoveryReload = false
        private var recoveryRetriesRemaining = 0
        private var recoveryNavigationInFlight = false
        private var imageImportGeneration = 0
        private var synchronizationTask: Task<Void, Never>?
        private var synchronizationSequence = 0
        private var hasCompletedInitialLoad = false

        /// Number of delayed reloads issued after a WebContent-process
        /// recovery navigation fails, before giving up with an error status.
        private static let maximumRecoveryRetries = 2

        init(parent: MarkdownEditorWebView) {
            self.parent = parent
            schemeHandler = MarkdownEditorAssetSchemeHandler()
        }

        func connect(webView: WKWebView) {
            self.webView = webView
            parent.controller.attach(webView: webView)
        }

        func update(parent: MarkdownEditorWebView) {
            if self.parent.fileURL?.standardizedFileURL != parent.fileURL?.standardizedFileURL
                || self.parent.isEditable != parent.isEditable
            {
                imageImportGeneration &+= 1
            }
            self.parent = parent
            schemeHandler.update(documentURL: parent.fileURL)
        }

        func synchronizeDocumentIfNeeded() {
            guard editorReady else { return }
            let markdown = parent.document.content.source
            let editable = parent.isEditable
            let controller = parent.controller
            var requestedMode = controller.mode
            let markdownChanged = markdown != lastSynchronizedMarkdown
            let editabilityChanged = editable != lastSynchronizedEditable
            guard markdownChanged || editabilityChanged else { return }
            imageImportGeneration &+= 1

            // Only the newest synchronization may report back: cancel the
            // previous load/setEditable task and tag this one with a sequence
            // number so a stale task cannot restore old state or surface a
            // stale error after a newer sync has started.
            synchronizationSequence &+= 1
            let sequence = synchronizationSequence
            synchronizationTask?.cancel()

            if !markdownChanged {
                lastSynchronizedEditable = editable
                synchronizationTask = Task {
                    do {
                        try await controller.setEditable(editable)
                    } catch {
                        guard synchronizationSequence == sequence, !Task.isCancelled else {
                            return
                        }
                        lastSynchronizedEditable = nil
                        controller.postStatus(error.localizedDescription)
                    }
                }
                return
            }

            // A brand-new, unsaved document (fileURL == nil) opens directly in
            // WYSIWYM editing; opening an existing file keeps the reading-mode
            // default. Only the first load picks a default — afterwards the
            // user's mode changes flow through controller.mode untouched.
            if !hasCompletedInitialLoad,
               parent.fileURL == nil,
               editable,
               requestedMode == .preview
            {
                requestedMode = .wysiwym
                controller.mode = .wysiwym
            } else if !hasCompletedInitialLoad,
                      editable,
                      requestedMode == .preview,
                      parent.initialMode != .preview
            {
                // The iOS document library asks for an explicit initial mode
                // (new documents open in WYSIWYM); it applies only while the
                // controller still sits at the default reading mode.
                requestedMode = parent.initialMode
                controller.mode = parent.initialMode
            }
            let isInitialLoad = !hasCompletedInitialLoad
            hasCompletedInitialLoad = true

            revision += 1
            let synchronizedRevision = revision
            lastSynchronizedMarkdown = markdown
            lastSynchronizedEditable = editable
            hasPresentedUnsafeWarning = false
            controller.documentWillLoad()
            synchronizationTask = Task {
                do {
                    try await controller.load(
                        markdown: markdown,
                        revision: synchronizedRevision,
                        requestedMode: requestedMode,
                        isEditable: editable
                    )
                    guard synchronizationSequence == sequence, !Task.isCancelled else {
                        return
                    }
                    if isInitialLoad {
                        await parent.onInitialLoadComplete?()
                    }
                    guard synchronizationSequence == sequence, !Task.isCancelled else {
                        return
                    }
                    controller.documentDidFinishLoad(revision: synchronizedRevision)
                } catch {
                    guard synchronizationSequence == sequence, !Task.isCancelled else {
                        return
                    }
                    if lastSynchronizedMarkdown == markdown {
                        lastSynchronizedMarkdown = nil
                    }
                    if lastSynchronizedEditable == editable {
                        lastSynchronizedEditable = nil
                    }
                    controller.postStatus(error.localizedDescription)
                }
            }
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == "markdownBridge",
                  let envelope = message.body as? [String: Any],
                  envelope["protocolVersion"] as? Int == EditorDocumentSnapshot.protocolVersion,
                  let type = envelope["type"] as? String
            else {
                return
            }

            switch type {
            case "ready":
                editorReady = true
                allowsRecoveryReload = false
                recoveryRetriesRemaining = 0
                recoveryNavigationInFlight = false
                parent.controller.editorDidBecomeReady()
                synchronizeDocumentIfNeeded()
            case "change":
                receiveChange(envelope["payload"])
            case "mode":
                receiveMode(envelope["payload"])
            case "reading-tap":
                parent.controller.toggleImmersiveReading()
            case "reading-escape":
                parent.controller.exitImmersiveReading()
            case "scroll-progress":
                if let dictionary = envelope["payload"] as? [String: Any],
                   let progress = (dictionary["progress"] as? NSNumber)?.doubleValue
                {
                    parent.onScrollProgress?(progress)
                }
            case "import-image":
                receiveImageImport(envelope["payload"])
            case "outline":
                receiveOutline(envelope["payload"])
            case "warning":
                receiveStatus(envelope["payload"], severity: .warning)
            case "error":
                receiveStatus(envelope["payload"], severity: .error)
            default:
                break
            }
        }

        private func receiveOutline(_ payload: Any?) {
            guard let dictionary = payload as? [String: Any],
                  let index = (dictionary["index"] as? NSNumber)?.intValue
            else {
                return
            }
            parent.controller.currentHeadingIndex = index >= 0 ? index : nil
        }

        private func receiveChange(_ payload: Any?) {
            guard parent.isEditable,
                  let dictionary = payload as? [String: Any],
                  let markdown = dictionary["markdown"] as? String
            else {
                return
            }

            revision = dictionary["revision"] as? Int ?? revision + 1
            lastSynchronizedMarkdown = markdown
            if let rawMode = dictionary["mode"] as? String,
               let mode = MarkdownEditorMode(rawValue: rawMode)
            {
                if parent.controller.mode != mode {
                    imageImportGeneration &+= 1
                    parent.controller.mode = mode
                }
            }
            guard parent.document.content.source != markdown else { return }
            imageImportGeneration &+= 1
            var updated = parent.document
            updated.content.source = markdown
            parent.document = updated
        }

        private func receiveMode(_ payload: Any?) {
            guard let dictionary = payload as? [String: Any],
                  let rawMode = dictionary["mode"] as? String,
                  let mode = MarkdownEditorMode(rawValue: rawMode)
            else {
                return
            }
            if parent.controller.mode != mode {
                imageImportGeneration &+= 1
                parent.controller.mode = mode
            }
            if mode != .preview {
                parent.controller.isImmersiveReading = false
            }
        }

        private func receiveStatus(_ payload: Any?, severity: EditorStatusSeverity) {
            guard let dictionary = payload as? [String: Any] else { return }
            if let message = dictionary["message"] as? String {
                // The forced fallback to source mode is explained once per document
                // load; repeated attempts to enter WYSIWYM stay in source mode
                // silently instead of showing the banner every time.
                if severity == .warning, dictionary["code"] as? String == "wysiwym-unsafe" {
                    guard !hasPresentedUnsafeWarning else { return }
                    hasPresentedUnsafeWarning = true
                }
                parent.controller.postStatus(message, severity: severity)
            } else {
                parent.controller.statusMessage = nil
            }
        }

        /// MIME types accepted from the engine's image paste/drop bridge,
        /// mapped to the file extension used when staging the payload.
        private static let importableImageTypes: [String: String] = [
            "image/png": "png",
            "image/jpeg": "jpg",
            "image/gif": "gif",
            "image/webp": "webp",
            "image/svg+xml": "svg",
            "image/avif": "avif",
            "image/heic": "heic",
            "image/bmp": "bmp",
            "image/tiff": "tiff",
            "image/x-icon": "ico",
            "image/vnd.microsoft.icon": "ico",
        ]

        /// Base64 expands binary data to four characters for every three
        /// bytes. Reject oversized bridge messages before allocating a Data
        /// buffer; the decoded-size check remains as defense in depth.
        nonisolated private static let maximumBridgedImageSize = 25 * 1_024 * 1_024
        nonisolated private static let maximumEncodedImagePayloadSize =
            ((maximumBridgedImageSize + 2) / 3) * 4

        private func receiveImageImport(_ payload: Any?) {
            guard let dictionary = payload as? [String: Any],
                  let requestId = dictionary["requestId"] as? String,
                  !requestId.isEmpty
            else {
                return
            }

            guard let requestedRevision = (dictionary["revision"] as? NSNumber)?.intValue,
                  let rawRequestedMode = dictionary["mode"] as? String,
                  let requestedMode = MarkdownEditorMode(rawValue: rawRequestedMode),
                  parent.isEditable,
                  parent.controller.mode == .wysiwym,
                  requestedMode == .wysiwym,
                  requestedRevision == revision
            else {
                resolveImageImport(requestId: requestId, relativePath: nil)
                return
            }

            guard let documentURL = parent.fileURL else {
                parent.controller.postStatus(
                    String(localized: "image.save-document-first"),
                    severity: .warning
                )
                resolveImageImport(requestId: requestId, relativePath: nil)
                return
            }

            guard let dataBase64 = dictionary["dataBase64"] as? String,
                  let mimeType = (dictionary["mimeType"] as? String)?.lowercased(),
                  let pathExtension = Self.importableImageTypes[mimeType]
            else {
                parent.controller.postStatus(
                    String(localized: "image.invalid-source"),
                    severity: .warning
                )
                resolveImageImport(requestId: requestId, relativePath: nil)
                return
            }

            guard dataBase64.utf8.count <= Self.maximumEncodedImagePayloadSize else {
                parent.controller.postStatus(
                    String(localized: "image.paste-too-large"),
                    severity: .warning
                )
                resolveImageImport(requestId: requestId, relativePath: nil)
                return
            }

            let rawName = dictionary["name"] as? String ?? "image"
            let importGeneration = imageImportGeneration
            let importRevision = revision
            let importMode = parent.controller.mode
            let importDocumentURL = documentURL.standardizedFileURL
            let importMarkdown = parent.document.content.source
            Task {
                do {
                    let relativePath = try await Task.detached(priority: .userInitiated) {
                        guard let data = Data(base64Encoded: dataBase64), !data.isEmpty else {
                            throw MarkdownAssetManager.ImportError.invalidSource
                        }
                        guard data.count <= Self.maximumBridgedImageSize else {
                            throw BridgedImageImportError.resourceTooLarge
                        }
                        let stagingDirectory = FileManager.default.temporaryDirectory
                            .appendingPathComponent(UUID().uuidString, isDirectory: true)
                        try FileManager.default.createDirectory(
                            at: stagingDirectory,
                            withIntermediateDirectories: true
                        )
                        defer { try? FileManager.default.removeItem(at: stagingDirectory) }
                        let stagingFile = stagingDirectory
                            .appendingPathComponent(Self.sanitizedImageBaseName(rawName))
                            .appendingPathExtension(pathExtension)
                        try data.write(to: stagingFile, options: .atomic)
                        return try MarkdownAssetManager.importResource(
                            at: stagingFile,
                            relativeTo: documentURL
                        )
                    }.value
                    guard isCurrentImageImportContext(
                        generation: importGeneration,
                        revision: importRevision,
                        mode: importMode,
                        documentURL: importDocumentURL,
                        markdown: importMarkdown
                    ) else {
                        Self.removeImportedImage(
                            relativePath: relativePath,
                            documentURL: importDocumentURL
                        )
                        resolveImageImport(requestId: requestId, relativePath: nil)
                        return
                    }
                    resolveImageImport(
                        requestId: requestId,
                        relativePath: relativePath,
                        cleanupDocumentURL: importDocumentURL
                    )
                } catch BridgedImageImportError.resourceTooLarge {
                    parent.controller.postStatus(
                        String(localized: "image.paste-too-large"),
                        severity: .warning
                    )
                    resolveImageImport(requestId: requestId, relativePath: nil)
                } catch {
                    parent.controller.postStatus(
                        localizedImageImportErrorMessage(error),
                        severity: .warning
                    )
                    resolveImageImport(requestId: requestId, relativePath: nil)
                }
            }
        }

        private func isCurrentImageImportContext(
            generation: Int,
            revision expectedRevision: Int,
            mode: MarkdownEditorMode,
            documentURL: URL,
            markdown: String
        ) -> Bool {
            imageImportGeneration == generation
                && revision == expectedRevision
                && parent.controller.mode == mode
                && mode == .wysiwym
                && parent.isEditable
                && parent.fileURL?.standardizedFileURL == documentURL
                && parent.document.content.source == markdown
        }

        /// `importResource` copies this bridge's temporary source to a unique
        /// document-relative path. If the initiating editor context has gone
        /// stale, remove only that returned file after resolving and
        /// round-tripping the path inside the original document directory.
        nonisolated private static func removeImportedImage(
            relativePath: String,
            documentURL: URL
        ) {
            guard let decodedPath = relativePath.removingPercentEncoding,
                  !decodedPath.isEmpty
            else {
                return
            }

            let root = documentURL.deletingLastPathComponent()
                .standardizedFileURL
                .resolvingSymlinksInPath()
            let candidate = root.appendingPathComponent(decodedPath)
                .standardizedFileURL
                .resolvingSymlinksInPath()
            guard candidate != root,
                  MarkdownAssetManager.relativeMarkdownPath(
                      for: candidate,
                      relativeTo: documentURL
                  ) == relativePath,
                  let values = try? candidate.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true
            else {
                return
            }
            try? FileManager.default.removeItem(at: candidate)
        }

        /// Keeps the pasted file's base name when it is filesystem-safe, so the
        /// copied resource stays recognizable next to the document.
        nonisolated private static func sanitizedImageBaseName(_ rawName: String) -> String {
            let base = (rawName as NSString).deletingPathExtension
            let allowed = CharacterSet.alphanumerics
                .union(CharacterSet(charactersIn: "-._"))
            let scalars = base.unicodeScalars.filter { allowed.contains($0) }
            let cleaned = String(String.UnicodeScalarView(scalars))
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return cleaned.isEmpty || cleaned == ".." ? "image" : cleaned
        }

        private func resolveImageImport(
            requestId: String,
            relativePath: String?,
            cleanupDocumentURL: URL? = nil
        ) {
            guard let webView else {
                if let relativePath,
                   let cleanupDocumentURL
                {
                    Self.removeImportedImage(
                        relativePath: relativePath,
                        documentURL: cleanupDocumentURL
                    )
                }
                return
            }
            Task { @MainActor in
                do {
                    let result = try await webView.callAsyncJavaScript(
                        "return window.mossmarkResolveImageImport(requestId, relativePath);",
                        arguments: [
                            "requestId": requestId,
                            "relativePath": relativePath ?? NSNull(),
                        ],
                        in: nil,
                        contentWorld: .page
                    )
                    if result as? Bool != true,
                       let relativePath,
                       let cleanupDocumentURL
                    {
                        Self.removeImportedImage(
                            relativePath: relativePath,
                            documentURL: cleanupDocumentURL
                        )
                    }
                } catch {
                    if let relativePath,
                       let cleanupDocumentURL
                    {
                        Self.removeImportedImage(
                            relativePath: relativePath,
                            documentURL: cleanupDocumentURL
                        )
                    }
                    parent.controller.postStatus(error.localizedDescription)
                }
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }
            if url.scheme == MarkdownEditorAssetSchemeHandler.scheme {
                // Resource requests do not pass through this delegate. At the
                // top level, allow only initial/reload navigation to the engine
                // entry point. A Markdown link such as `(index.html)` or a
                // document-local SVG must never replace the trusted editor.
                let isTrustedEntry = url.host == "local"
                    && url.path == "/index.html"
                    && url.user == nil
                    && url.password == nil
                    && url.port == nil
                    && url.query == nil
                let isMainFrame = navigationAction.targetFrame?.isMainFrame == true
                let navigationType = navigationAction.navigationType
                let isInitialLoad = navigationType == .other
                    && !editorReady
                    && !allowsRecoveryReload
                let isAuthorizedRecovery = allowsRecoveryReload
                    && (navigationType == .other || navigationType == .reload)
                let isAllowed = isTrustedEntry
                    && url.fragment == nil
                    && isMainFrame
                    && (isInitialLoad || isAuthorizedRecovery)
                if isAllowed, isAuthorizedRecovery {
                    // A recovery grant is single-use, and it is consumed only
                    // when the complete allow predicate holds: a navigation
                    // that gets cancelled (untrusted URL, subframe, fragment)
                    // must never burn the pending recovery. WebKit classifies
                    // a same-URL document link as `.reload`, so ordinary
                    // reloads must remain denied while the editor is running.
                    allowsRecoveryReload = false
                    recoveryNavigationInFlight = true
                }
                decisionHandler(isAllowed ? .allow : .cancel)
                return
            }

            let allowedExternalSchemes = Set(["http", "https", "mailto"])
            let opensExternally = navigationAction.navigationType == .linkActivated
                || navigationAction.targetFrame == nil
            if opensExternally,
               let scheme = url.scheme?.lowercased(),
               allowedExternalSchemes.contains(scheme)
            {
                #if os(macOS)
                NSWorkspace.shared.open(url)
                #else
                UIApplication.shared.open(url)
                #endif
            }
            decisionHandler(.cancel)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            editorReady = false
            lastSynchronizedMarkdown = nil
            lastSynchronizedEditable = nil
            imageImportGeneration &+= 1
            parent.controller.isReady = false
            parent.controller.documentWillLoad()
            parent.controller.postStatus(
                String(localized: "error.editor.process-terminated"),
                severity: .error
            )
            allowsRecoveryReload = true
            recoveryRetriesRemaining = Self.maximumRecoveryRetries
            recoveryNavigationInFlight = false
            webView.reload()
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: any Error
        ) {
            parent.controller.postStatus(error.localizedDescription)
            guard recoveryNavigationInFlight else { return }
            recoveryNavigationInFlight = false
            guard recoveryRetriesRemaining > 0 else {
                // Recovery budget exhausted: the explicit error status posted
                // above stays visible instead of retrying forever over a
                // blank editor.
                return
            }
            recoveryRetriesRemaining -= 1
            allowsRecoveryReload = true
            let scheduledRetriesRemaining = recoveryRetriesRemaining
            let attempt = Self.maximumRecoveryRetries - recoveryRetriesRemaining
            Task {
                // Bounded backoff before re-issuing the recovery reload. The
                // guards drop the retry if the editor already recovered or a
                // newer termination reset the recovery state.
                try? await Task.sleep(nanoseconds: UInt64(attempt) * 500_000_000)
                guard !editorReady,
                      allowsRecoveryReload,
                      !recoveryNavigationInFlight,
                      recoveryRetriesRemaining == scheduledRetriesRemaining,
                      let webView = self.webView
                else {
                    return
                }
                webView.reload()
            }
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation!,
            withError error: any Error
        ) {
            parent.controller.postStatus(error.localizedDescription)
        }
    }
}

/// Maps an asset import failure to the localized message shown to the user.
func localizedImageImportErrorMessage(_ error: any Error) -> String {
    guard let importError = error as? MarkdownAssetManager.ImportError else {
        return error.localizedDescription
    }
    switch importError {
    case .invalidDocumentURL:
        return String(localized: "image.save-document-first")
    case .invalidSource:
        return String(localized: "image.invalid-source")
    case .resourceTooLarge:
        return String(localized: "image.too-large")
    case .destinationUnavailable:
        return String(localized: "image.destination-unavailable")
    }
}

#if os(macOS)
extension MarkdownEditorWebView: NSViewRepresentable {
    typealias NSViewType = WKWebView

    func makeNSView(context: Context) -> WKWebView {
        makeWebView(context: context)
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        updateWebView(nsView, context: context)
    }
}
#else
extension MarkdownEditorWebView: UIViewRepresentable {
    typealias UIViewType = WKWebView

    func makeUIView(context: Context) -> WKWebView {
        makeWebView(context: context)
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        updateWebView(uiView, context: context)
    }
}
#endif
