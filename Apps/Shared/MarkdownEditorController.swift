import MarkdownCore
import Observation
import WebKit
import CoreGraphics
import ImageIO

#if os(macOS)
import AppKit
#else
import UIKit
#endif

enum MarkdownEditorControllerError: LocalizedError {
    case editorNotReady
    case invalidJavaScriptResult
    case pdfPageLimitExceeded
    case pdfGraphicRenderingFailed(expected: Int, decoded: Int)

    var errorDescription: String? {
        switch self {
        case .editorNotReady: String(localized: "error.editor.not-ready")
        case .invalidJavaScriptResult: String(localized: "error.editor.invalid-result")
        case .pdfPageLimitExceeded: String(localized: "error.pdf.page-limit")
        case let .pdfGraphicRenderingFailed(expected, decoded):
            String.localizedStringWithFormat(
                String(localized: "error.pdf.graphics"),
                expected,
                decoded
            )
        }
    }
}

enum MarkdownFormattingCommand: String {
    case bold
    case italic
    case strikethrough
    case inlineCode = "inline-code"
    case link
    case image
    case heading
    case bulletList = "bullet-list"
    case orderedList = "ordered-list"
    case blockquote
    case codeBlock = "code-block"
    case horizontalRule = "horizontal-rule"
    case table
}

enum MarkdownTableEditingCommand: String {
    case addRowBefore = "add-row-before"
    case addRowAfter = "add-row-after"
    case addColumnBefore = "add-column-before"
    case addColumnAfter = "add-column-after"
    case deleteRow = "delete-row"
    case deleteColumn = "delete-column"
    case alignLeft = "align-left"
    case alignCenter = "align-center"
    case alignRight = "align-right"
}

enum EditorStatusSeverity: String, Hashable {
    case info
    case warning
    case error
}

struct EditorStatusMessage: Hashable {
    var severity: EditorStatusSeverity
    var message: String
}

enum MarkdownTypographyPreset: String, CaseIterable {
    case quiet
    case paper
    case code

    var localizationKey: String {
        "typography.\(rawValue)"
    }
}

private struct MarkdownPDFGraphic: Sendable {
    let key: String
    let data: Data
    let image: CGImage
    let rect: CGRect
}

private struct MarkdownPDFGraphicSpec: Sendable {
    let key: String
    let dataURL: String
    let rect: CGRect
}

struct MarkdownDOCXExportPreparation: Sendable {
    let markdown: String
    let images: [String: MarkdownExportImage]
}

@MainActor
@Observable
final class MarkdownEditorController {
    var mode: MarkdownEditorMode = .preview
    var isReady = false
    var isDocumentLoaded = false
    var statusMessage: EditorStatusMessage?
    var isExporting = false
    var focusMode = false
    var typewriterMode = false
    var isImmersiveReading = false
    var currentHeadingIndex: Int?
    var typographyPreset: MarkdownTypographyPreset = .quiet

    @ObservationIgnored private weak var webView: WKWebView?
    @ObservationIgnored private var loadedRevision: Int?
    @ObservationIgnored private var outlineNavigationSequence = 0

    func attach(webView: WKWebView) {
        self.webView = webView
        isDocumentLoaded = false
        loadedRevision = nil
    }

    func postStatus(_ message: String, severity: EditorStatusSeverity = .error) {
        statusMessage = EditorStatusMessage(severity: severity, message: message)
    }

    func editorDidBecomeReady() {
        isReady = true
        isDocumentLoaded = false
        loadedRevision = nil
        applyStoredVisualPreferences()
    }

    func documentWillLoad() {
        isDocumentLoaded = false
        loadedRevision = nil
        currentHeadingIndex = nil
        outlineNavigationSequence &+= 1
    }

    func documentDidFinishLoad(revision: Int) {
        loadedRevision = revision
        isDocumentLoaded = true
    }

    func setMode(_ requestedMode: MarkdownEditorMode) {
        if requestedMode != .preview {
            isImmersiveReading = false
        }
        guard isReady, let webView else {
            mode = requestedMode
            return
        }

        Task {
            do {
                let result = try await webView.callAsyncJavaScript(
                    "return await window.MarkdownEditor.setMode(requestedMode);",
                    arguments: ["requestedMode": requestedMode.rawValue],
                    in: nil,
                    contentWorld: .page
                )
                if let dictionary = result as? [String: Any],
                   let rawMode = dictionary["mode"] as? String,
                   let acceptedMode = MarkdownEditorMode(rawValue: rawMode)
                {
                    mode = acceptedMode
                    if acceptedMode != .preview {
                        isImmersiveReading = false
                    }
                }
            } catch {
                postStatus(error.localizedDescription)
            }
        }
    }

    func toggleImmersiveReading() {
        guard mode == .preview, !isExporting else { return }
        isImmersiveReading.toggle()
    }

    func exitImmersiveReading() {
        guard isImmersiveReading else { return }
        isImmersiveReading = false
    }

    func applyFormatting(
        _ command: MarkdownFormattingCommand,
        stringValue: String? = nil,
        numberValue: Int? = nil
    ) {
        guard isReady, let webView else { return }
        Task {
            do {
                var arguments: [String: Any] = ["command": command.rawValue, "value": NSNull()]
                if let stringValue { arguments["value"] = stringValue }
                if let numberValue { arguments["value"] = numberValue }
                _ = try await webView.callAsyncJavaScript(
                    "return window.MarkdownEditor.applyFormatting(command, value);",
                    arguments: arguments,
                    in: nil,
                    contentWorld: .page
                )
            } catch {
                postStatus(error.localizedDescription)
            }
        }
    }

    func editTable(_ command: MarkdownTableEditingCommand) {
        guard isReady, mode != .preview, let webView else { return }
        Task {
            do {
                let result = try await webView.callAsyncJavaScript(
                    "return window.MarkdownEditor.editTable(command);",
                    arguments: ["command": command.rawValue],
                    in: nil,
                    contentWorld: .page
                )
                if result as? Bool != true {
                    postStatus(String(localized: "table.place-cursor"), severity: .warning)
                }
            } catch {
                postStatus(error.localizedDescription)
            }
        }
    }

    func find(_ query: String, backwards: Bool = false, caseSensitive: Bool = false) {
        guard isReady, !query.isEmpty, let webView else { return }
        Task {
            let configuration = WKFindConfiguration()
            configuration.backwards = backwards
            configuration.wraps = true
            configuration.caseSensitive = caseSensitive
            do {
                let result = try await webView.find(query, configuration: configuration)
                if !result.matchFound {
                    postStatus(
                        String.localizedStringWithFormat(
                            String(localized: "find.not-found %@"),
                            query
                        ),
                        severity: .info
                    )
                }
            } catch {
                postStatus(error.localizedDescription)
            }
        }
    }

    /// Counts matches via the editor engine for the find bar's match label.
    func countMatches(query: String, caseSensitive: Bool) async -> Int {
        guard isReady, !query.isEmpty, let webView else { return 0 }
        do {
            let result = try await webView.callAsyncJavaScript(
                "return window.mossmarkCountMatches(query, caseSensitive);",
                arguments: ["query": query, "caseSensitive": caseSensitive],
                in: nil,
                contentWorld: .page
            )
            return (result as? NSNumber)?.intValue ?? 0
        } catch {
            return 0
        }
    }

    func replaceAll(query: String, replacement: String, caseSensitive: Bool = false) {
        guard isReady, !query.isEmpty, let webView else { return }
        Task {
            do {
                let result = try await webView.callAsyncJavaScript(
                    "return window.MarkdownEditor.replaceAllText(query, replacement, caseSensitive);",
                    arguments: [
                        "query": query,
                        "replacement": replacement,
                        "caseSensitive": caseSensitive,
                    ],
                    in: nil,
                    contentWorld: .page
                )
                let count = result as? Int ?? 0
                postStatus(
                    count == 0
                        ? String(localized: "replace.none")
                        : String.localizedStringWithFormat(
                            String(localized: "replace.count %lld"),
                            count
                        ),
                    severity: .info
                )
            } catch {
                postStatus(error.localizedDescription)
            }
        }
    }

    /// Waits for the current document load, then accepts success only after
    /// the engine confirms the requested heading is actually inside the
    /// visible viewport. A newer request supersedes an older in-flight one.
    func scrollToHeading(index: Int, line: Int) async -> Bool {
        outlineNavigationSequence &+= 1
        let requestSequence = outlineNavigationSequence
        var lastError: (any Error)?
        var engineAttempts = 0
        for attempt in 0..<50 {
            guard requestSequence == outlineNavigationSequence else { return false }
            if isReady, isDocumentLoaded, loadedRevision != nil, let webView {
                engineAttempts += 1
                do {
                    let result = try await webView.callAsyncJavaScript(
                        "return await window.MarkdownEditor.scrollToHeading(index, line);",
                        arguments: ["index": index, "line": line],
                        in: nil,
                        contentWorld: .page
                    )
                    guard requestSequence == outlineNavigationSequence else { return false }
                    if result as? Bool == true, isDocumentLoaded {
                        currentHeadingIndex = index
                        return true
                    }
                } catch {
                    lastError = error
                }
                if engineAttempts >= 3 { break }
            }
            if attempt < 49 {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        if let lastError {
            postStatus(lastError.localizedDescription)
        }
        return false
    }

    func setFocusMode(_ enabled: Bool) {
        focusMode = enabled
        setVisualPreference("focus", enabled: enabled)
    }

    func setTypewriterMode(_ enabled: Bool) {
        typewriterMode = enabled
        setVisualPreference("typewriter", enabled: enabled)
    }

    func setTypographyPreset(_ preset: MarkdownTypographyPreset) {
        typographyPreset = preset
        guard isReady, let webView else { return }
        Task { @MainActor in
            do {
                _ = try await webView.callAsyncJavaScript(
                    "window.MarkdownEditor.setTypographyPreset(preset);",
                    arguments: ["preset": preset.rawValue],
                    in: nil,
                    contentWorld: .page
                )
            } catch {
                postStatus(error.localizedDescription)
            }
        }
    }

    /// Applies reading font size / content width to the preview; nil leaves a
    /// metric at the engine default.
    func setReadingMetrics(fontSize: Double?, contentWidth: Double?) {
        guard isReady, let webView else { return }
        Task { @MainActor in
            do {
                _ = try await webView.callAsyncJavaScript(
                    "window.setReadingMetrics(fontSize, contentWidth);",
                    arguments: [
                        "fontSize": fontSize ?? NSNull(),
                        "contentWidth": contentWidth ?? NSNull(),
                    ],
                    in: nil,
                    contentWorld: .page
                )
            } catch {
                postStatus(error.localizedDescription)
            }
        }
    }

    func setSpellCheck(_ enabled: Bool) {
        guard isReady, let webView else { return }
        Task { @MainActor in
            do {
                _ = try await webView.callAsyncJavaScript(
                    "window.setSpellCheck(enabled);",
                    arguments: ["enabled": enabled],
                    in: nil,
                    contentWorld: .page
                )
            } catch {
                postStatus(error.localizedDescription)
            }
        }
    }

    /// Toggles the full-width layout in the web editor.
    func setFullWidthLayout(enabled: Bool) {
        guard isReady, let webView else { return }
        Task { @MainActor in
            do {
                _ = try await webView.callAsyncJavaScript(
                    "window.setFullWidthLayout(enabled);",
                    arguments: ["enabled": enabled],
                    in: nil,
                    contentWorld: .page
                )
            } catch {
                postStatus(error.localizedDescription)
            }
        }
    }

    private func applyStoredVisualPreferences() {
        setVisualPreference("focus", enabled: focusMode)
        setVisualPreference("typewriter", enabled: typewriterMode)
        setTypographyPreset(typographyPreset)
    }

    private func setVisualPreference(_ preference: String, enabled: Bool) {
        guard isReady, let webView else { return }
        Task { @MainActor in
            do {
                _ = try await webView.callAsyncJavaScript(
                    "window.MarkdownEditor.setVisualPreference(preference, enabled);",
                    arguments: ["preference": preference, "enabled": enabled],
                    in: nil,
                    contentWorld: .page
                )
            } catch {
                postStatus(error.localizedDescription)
            }
        }
    }

    func load(
        markdown: String,
        revision: Int,
        requestedMode: MarkdownEditorMode,
        isEditable: Bool
    ) async throws {
        guard let webView else {
            throw MarkdownEditorControllerError.editorNotReady
        }
        _ = try await webView.callAsyncJavaScript(
            "return await window.MarkdownEditor.load({ markdown, revision, mode, editable });",
            arguments: [
                "markdown": markdown,
                "revision": revision,
                "mode": requestedMode.rawValue,
                "editable": isEditable,
            ],
            in: nil,
            contentWorld: .page
        )
    }

    func setEditable(_ enabled: Bool) async throws {
        guard isReady, let webView else {
            throw MarkdownEditorControllerError.editorNotReady
        }
        _ = try await webView.callAsyncJavaScript(
            "window.MarkdownEditor.setEditable(enabled);",
            arguments: ["enabled": enabled],
            in: nil,
            contentWorld: .page
        )
    }

    /// Restores a previously captured reading progress. Best effort: a
    /// failing restore must never interrupt editing, so errors stay silent.
    func restoreScrollProgress(_ progress: Double) async {
        guard isReady, let webView, progress > 0 else { return }
        _ = try? await webView.callAsyncJavaScript(
            "window.MarkdownEditor.restoreScrollProgress(progress);",
            arguments: ["progress": progress],
            in: nil,
            contentWorld: .page
        )
    }

    func exportHTML(title: String) async throws -> String {
        guard isReady, let webView else {
            throw MarkdownEditorControllerError.editorNotReady
        }
        let result = try await webView.callAsyncJavaScript(
            "return window.MarkdownEditor.getExportHTML(title);",
            arguments: ["title": title],
            in: nil,
            contentWorld: .page
        )
        guard let html = result as? String else {
            throw MarkdownEditorControllerError.invalidJavaScriptResult
        }
        return html
    }

    /// Returns the authoritative editor snapshot, including a WYSIWYM change
    /// that may not yet have reached the host's debounced file save.
    func currentMarkdown() async throws -> String {
        guard isDocumentLoaded, let webView else {
            throw MarkdownEditorControllerError.editorNotReady
        }
        let result = try await webView.callAsyncJavaScript(
            "return window.MarkdownEditor.getSnapshot();",
            arguments: [:],
            in: nil,
            contentWorld: .page
        )
        guard let dictionary = result as? NSDictionary,
              let markdown = dictionary["markdown"] as? String
        else {
            throw MarkdownEditorControllerError.invalidJavaScriptResult
        }
        return markdown
    }

    func makePDF(title: String) async throws -> Data {
        guard isReady, let webView else {
            throw MarkdownEditorControllerError.editorNotReady
        }

        let previousMode = mode
        let preparation = try await webView.callAsyncJavaScript(
            "return await window.MarkdownEditor.prepareForExport();",
            arguments: [:],
            in: nil,
            contentWorld: .page
        )
        let graphicSpecs = pdfGraphicSpecs(from: preparation)
        let graphics = await Task.detached(priority: .userInitiated) {
            Self.decodePDFGraphics(from: graphicSpecs)
        }.value
        let expectedGraphicCount = expectedPDFGraphicCount(from: preparation)
        guard graphics.count == expectedGraphicCount else {
            try? await finishExport(webView: webView, restoring: previousMode)
            throw MarkdownEditorControllerError.pdfGraphicRenderingFailed(
                expected: expectedGraphicCount,
                decoded: graphics.count
            )
        }
        mode = .preview

        do {
            let data = try await renderPaginatedPDF(
                webView: webView,
                title: title,
                graphics: graphics
            )
            try await finishExport(webView: webView, restoring: previousMode)
            return data
        } catch {
            try? await finishExport(webView: webView, restoring: previousMode)
            throw error
        }
    }

    func prepareDOCXExport() async throws -> MarkdownDOCXExportPreparation {
        guard isReady, let webView else {
            throw MarkdownEditorControllerError.editorNotReady
        }

        let previousMode = mode
        let preparation = try await webView.callAsyncJavaScript(
            "return await window.MarkdownEditor.prepareForExport();",
            arguments: [:],
            in: nil,
            contentWorld: .page
        )
        do {
            guard let dictionary = preparation as? NSDictionary,
                  let markdown = dictionary["markdown"] as? String
            else {
                throw MarkdownEditorControllerError.invalidJavaScriptResult
            }
            let graphicSpecs = pdfGraphicSpecs(from: preparation)
            let graphics = await Task.detached(priority: .userInitiated) {
                Self.decodePDFGraphics(from: graphicSpecs)
            }.value
            let expectedGraphicCount = expectedPDFGraphicCount(from: preparation)
            guard graphics.count == expectedGraphicCount else {
                throw MarkdownEditorControllerError.pdfGraphicRenderingFailed(
                    expected: expectedGraphicCount,
                    decoded: graphics.count
                )
            }
            let result = Dictionary(uniqueKeysWithValues: graphics.map { graphic in
                (
                    graphic.key,
                    MarkdownExportImage(
                        data: graphic.data,
                        fileExtension: "png",
                        widthPixels: graphic.image.width,
                        heightPixels: graphic.image.height
                    )
                )
            })
            try await finishExport(webView: webView, restoring: previousMode)
            return MarkdownDOCXExportPreparation(markdown: markdown, images: result)
        } catch {
            try? await finishExport(webView: webView, restoring: previousMode)
            throw error
        }
    }

    private func finishExport(webView: WKWebView, restoring mode: MarkdownEditorMode) async throws {
        _ = try await webView.callAsyncJavaScript(
            "return await window.MarkdownEditor.finishExport(mode);",
            arguments: ["mode": mode.rawValue],
            in: nil,
            contentWorld: .page
        )
        self.mode = mode
    }

    private func pdfGraphicSpecs(from value: Any?) -> [MarkdownPDFGraphicSpec] {
        guard let dictionary = value as? NSDictionary,
              let entries = dictionary["exportGraphics"] as? [Any]
        else {
            return []
        }
        return entries.compactMap { value in
            guard let entry = value as? NSDictionary else { return nil }
            guard let dataURL = entry["dataURL"] as? String,
                  let key = entry["key"] as? String,
                  let x = (entry["x"] as? NSNumber)?.doubleValue,
                  let y = (entry["y"] as? NSNumber)?.doubleValue,
                  let width = (entry["width"] as? NSNumber)?.doubleValue,
                  let height = (entry["height"] as? NSNumber)?.doubleValue
            else {
                return nil
            }
            return MarkdownPDFGraphicSpec(
                key: key,
                dataURL: dataURL,
                rect: CGRect(x: x, y: y, width: width, height: height)
            )
        }
    }

    /// Decodes base64 image payloads and rasterizes them; runs off the main actor.
    nonisolated private static func decodePDFGraphics(
        from specs: [MarkdownPDFGraphicSpec]
    ) -> [MarkdownPDFGraphic] {
        specs.compactMap { spec in
            guard let comma = spec.dataURL.firstIndex(of: ","),
                  let data = Data(base64Encoded: String(spec.dataURL[spec.dataURL.index(after: comma)...])),
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else {
                return nil
            }
            return MarkdownPDFGraphic(key: spec.key, data: data, image: image, rect: spec.rect)
        }
    }

    private func expectedPDFGraphicCount(from value: Any?) -> Int {
        guard let dictionary = value as? NSDictionary else { return 0 }
        return (dictionary["expectedGraphicCount"] as? NSNumber)?.intValue ?? 0
    }

    private func renderPaginatedPDF(
        webView: WKWebView,
        title: String,
        graphics: [MarkdownPDFGraphic]
    ) async throws -> Data {
        let result = try await webView.callAsyncJavaScript(
            "return { height: Math.max(document.documentElement.scrollHeight, document.body.scrollHeight), width: document.documentElement.clientWidth };",
            arguments: [:],
            in: nil,
            contentWorld: .page
        )
        guard let metrics = result as? [String: Any],
              let contentHeight = (metrics["height"] as? NSNumber)?.doubleValue,
              let clientWidth = (metrics["width"] as? NSNumber)?.doubleValue,
              contentHeight > 0,
              clientWidth > 0
        else {
            throw MarkdownEditorControllerError.invalidJavaScriptResult
        }

        let paperSize = CGSize(width: 595.28, height: 841.89)
        let margin: CGFloat = 36
        let printableSize = CGSize(
            width: paperSize.width - margin * 2,
            height: paperSize.height - margin * 2
        )
        let captureWidth = CGFloat(clientWidth)
        let preliminaryScale = printableSize.width / captureWidth
        let preliminaryPageHeight = printableSize.height / preliminaryScale
        let preliminaryPageCount = max(
            1,
            Int(ceil(CGFloat(contentHeight) / preliminaryPageHeight))
        )
        guard preliminaryPageCount <= 1_000 else {
            throw MarkdownEditorControllerError.pdfPageLimitExceeded
        }

        let configuration = WKPDFConfiguration()
        configuration.rect = CGRect(
            x: 0,
            y: 0,
            width: captureWidth,
            height: CGFloat(contentHeight)
        )
        let sourceData = try await webView.pdf(configuration: configuration)
        guard let sourceProvider = CGDataProvider(data: sourceData as CFData),
              let sourceDocument = CGPDFDocument(sourceProvider),
              let sourcePage = sourceDocument.page(at: 1)
        else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let sourceBox = sourcePage.getBoxRect(.mediaBox)
        let captureScale = printableSize.width / sourceBox.width
        let capturePageHeight = printableSize.height / captureScale
        let sourceXScale = sourceBox.width / captureWidth
        let sourceYScale = sourceBox.height / CGFloat(contentHeight)
        guard sourceXScale > 0, sourceYScale > 0 else {
            throw MarkdownEditorControllerError.invalidJavaScriptResult
        }
        let paginationResult = try await webView.callAsyncJavaScript(
            "return window.MarkdownEditor.getPaginationBreaks(pageHeight);",
            arguments: ["pageHeight": capturePageHeight / sourceYScale],
            in: nil,
            contentWorld: .page
        )
        guard let paginationValues = paginationResult as? [Any] else {
            throw MarkdownEditorControllerError.invalidJavaScriptResult
        }
        let pageBreaks = paginationValues.compactMap {
            ($0 as? NSNumber).map { CGFloat(truncating: $0) }
        }
        guard pageBreaks.count >= 2,
              abs((pageBreaks.first ?? -1)) < 0.5,
              (pageBreaks.last ?? 0) >= CGFloat(contentHeight) - 0.5,
              zip(pageBreaks, pageBreaks.dropFirst()).allSatisfy({ $0.0 < $0.1 })
        else {
            throw MarkdownEditorControllerError.invalidJavaScriptResult
        }
        let pageCount = pageBreaks.count - 1
        guard pageCount <= 1_000 else {
            throw MarkdownEditorControllerError.pdfPageLimitExceeded
        }

        return try await Task.detached(priority: .userInitiated) {
            try Self.drawPaginatedPDF(
                sourceData: sourceData,
                title: title,
                pageBreaks: pageBreaks,
                graphics: graphics,
                paperSize: paperSize,
                margin: margin,
                captureWidth: captureWidth,
                contentHeight: CGFloat(contentHeight)
            )
        }.value
    }

    /// Draws the paginated PDF from the captured page data; runs off the main actor
    /// because it can iterate over up to 1,000 pages of CoreGraphics work.
    nonisolated private static func drawPaginatedPDF(
        sourceData: Data,
        title: String,
        pageBreaks: [CGFloat],
        graphics: [MarkdownPDFGraphic],
        paperSize: CGSize,
        margin: CGFloat,
        captureWidth: CGFloat,
        contentHeight: CGFloat
    ) throws -> Data {
        let printableSize = CGSize(
            width: paperSize.width - margin * 2,
            height: paperSize.height - margin * 2
        )
        guard let sourceProvider = CGDataProvider(data: sourceData as CFData),
              let sourceDocument = CGPDFDocument(sourceProvider),
              let sourcePage = sourceDocument.page(at: 1)
        else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let sourceBox = sourcePage.getBoxRect(.mediaBox)
        let captureScale = printableSize.width / sourceBox.width
        let capturePageHeight = printableSize.height / captureScale
        let sourceXScale = sourceBox.width / captureWidth
        let sourceYScale = sourceBox.height / contentHeight
        guard sourceXScale > 0, sourceYScale > 0 else {
            throw MarkdownEditorControllerError.invalidJavaScriptResult
        }
        let pageCount = pageBreaks.count - 1

        let output = NSMutableData()
        guard let consumer = CGDataConsumer(data: output as CFMutableData) else {
            throw CocoaError(.fileWriteUnknown)
        }
        var mediaBox = CGRect(origin: .zero, size: paperSize)
        let metadata = [kCGPDFContextTitle as String: title] as CFDictionary
        guard let context = CGContext(
            consumer: consumer,
            mediaBox: &mediaBox,
            metadata
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }

        for pageIndex in 0..<pageCount {
            let pageStart = pageBreaks[pageIndex]
            let pageEnd = pageBreaks[pageIndex + 1]
            let pageStartInSource = pageStart * sourceYScale
            let pageEndInSource = min(sourceBox.height, pageEnd * sourceYScale)
            let sliceHeight = pageEndInSource - pageStartInSource
            let sliceMinimumY = sourceBox.maxY - pageEndInSource
            let topAlignment = capturePageHeight - sliceHeight

            context.beginPDFPage(nil)
            context.saveGState()
            context.clip(to: CGRect(origin: CGPoint(x: margin, y: margin), size: printableSize))
            context.translateBy(x: margin, y: margin)
            context.scaleBy(x: captureScale, y: captureScale)
            context.translateBy(
                x: -sourceBox.minX,
                y: -sliceMinimumY + topAlignment
            )
            context.drawPDFPage(sourcePage)
            context.restoreGState()

            for graphic in graphics
            where graphic.rect.maxY > pageStart && graphic.rect.minY < pageEnd {
                let destination = CGRect(
                    x: margin + graphic.rect.minX * sourceXScale * captureScale,
                    y: margin + printableSize.height
                        - (graphic.rect.maxY - pageStart) * sourceYScale * captureScale,
                    width: graphic.rect.width * sourceXScale * captureScale,
                    height: graphic.rect.height * sourceYScale * captureScale
                )
                context.saveGState()
                context.clip(to: CGRect(
                    origin: CGPoint(x: margin, y: margin),
                    size: printableSize
                ))
                context.interpolationQuality = .high
                context.draw(graphic.image, in: destination)
                context.restoreGState()
            }
            context.endPDFPage()
        }
        context.closePDF()
        return output as Data
    }
}
