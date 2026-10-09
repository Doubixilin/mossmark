import MarkdownCore
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
#else
import PhotosUI
import UIKit
#endif

private enum MarkdownExportError: LocalizedError {
    case invalidPDF

    var errorDescription: String? { String(localized: "error.pdf.invalid") }
}

private struct PresentedAppError: Identifiable {
    let id = UUID()
    let message: String
}

private enum PresentedDocumentSheet: String, Identifiable {
    case sidebar
    case settings

    var id: String { rawValue }
}

/// Hashable identity for refreshing the find bar's match count.
private struct FindCountQuery: Hashable {
    var query: String
    var caseSensitive: Bool
    var visible: Bool
    var ready: Bool
    var source: String
}

/// Hashable identity for pushing reading settings into the web editor.
private struct ReadingSettings: Hashable {
    var fontSize: Double
    var contentWidth: Double
    var spellCheck: Bool
    var fullWidthLayout: Bool
    var ready: Bool
}

struct MarkdownDocumentView: View {
    @Binding var document: MarkdownFileDocument
    let fileURL: URL?
    let isEditable: Bool
    /// Preferred mode for the first engine load. The iOS document library
    /// opens new documents straight into WYSIWYM editing; the default keeps
    /// the macOS DocumentGroup behavior unchanged.
    var initialMode: MarkdownEditorMode = .preview
    var onOpenDocument: ((URL) -> Void)? = nil

    @Environment(\.openURL) private var openURL
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #if os(iOS)
    @EnvironmentObject private var readingHistory: ReadingHistory
    #endif
    @AppStorage("mossmark.typography-preset") private var typographyPresetRaw =
        MarkdownTypographyPreset.quiet.rawValue
    @AppStorage("mossmark.reading-font-size") private var readingFontSize = 17.0
    @AppStorage("mossmark.reading-content-width") private var readingContentWidth = 760.0
    @AppStorage("mossmark.spell-check") private var spellCheckEnabled = true
    @AppStorage("mossmark.full-width-layout") private var fullWidthLayout = false
    @AppStorage("mossmark.show-status-bar") private var showsStatusBar = true
    @State private var controller = MarkdownEditorController()
    @State private var exportedDocument: BinaryExportDocument?
    @State private var exportedContentType: UTType = .pdf
    @State private var exportedFilename = "Markdown.pdf"
    @State private var presentsExporter = false
    @State private var sidebarVisibility: NavigationSplitViewVisibility = .automatic
    @State private var preferredCompactColumn: NavigationSplitViewColumn = .detail
    @State private var presentedSheet: PresentedDocumentSheet?
    @State private var pendingOutlineItem: MarkdownOutlineItem?
    @State private var pendingSiblingURL: URL?
    @State private var siblingDocuments: [URL] = []
    @State private var showsFindBar = false
    @State private var searchText = ""
    @State private var replacementText = ""
    @State private var findCaseSensitive = false
    @State private var matchCount: Int?
    @State private var showsLinkPrompt = false
    @State private var linkTarget = "https://"
    @State private var showsImagePrompt = false
    @State private var imageTarget = "images/image.png"
    @State private var presentsImageImporter = false
    #if os(iOS)
    @State private var presentsPhotoPicker = false
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var sharedExportFile: SharedExportFile?
    #endif
    @State private var isImportingImage = false
    @State private var isPrinting = false
    @State private var documentStatistics = MarkdownDocumentStatistics.empty
    @State private var outlineItems: [MarkdownOutlineItem] = []
    @State private var sidebarVisibilityBeforeImmersiveReading: NavigationSplitViewVisibility?
    @State private var presentedError: PresentedAppError?
    #if os(iOS)
    @State private var hasRestoredScrollProgress = false
    #endif

    var body: some View {
        navigationContent
        .task(id: fileURL) {
            await loadSiblingDocuments()
        }
        .task(id: document.content.source) {
            let markdown = document.content.source
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            let derived = await Task.detached(priority: .utility) {
                (
                    MarkdownDocumentStatistics.calculate(markdown),
                    MarkdownOutlineParser.parse(markdown)
                )
            }.value
            guard !Task.isCancelled else { return }
            documentStatistics = derived.0
            outlineItems = derived.1
        }
        .task(id: typographyPresetRaw) {
            controller.setTypographyPreset(
                MarkdownTypographyPreset(rawValue: typographyPresetRaw) ?? .quiet
            )
        }
        .task(
            id: ReadingSettings(
                fontSize: readingFontSize,
                contentWidth: readingContentWidth,
                spellCheck: spellCheckEnabled,
                fullWidthLayout: fullWidthLayout,
                ready: controller.isReady
            )
        ) {
            guard controller.isReady else { return }
            controller.setReadingMetrics(
                fontSize: readingFontSize,
                contentWidth: readingContentWidth
            )
            controller.setSpellCheck(spellCheckEnabled)
            controller.setFullWidthLayout(enabled: fullWidthLayout)
        }
        .task(id: controller.statusMessage) {
            // Informational messages clear themselves; warnings and errors stay
            // until dismissed explicitly.
            guard controller.statusMessage?.severity == .info else { return }
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, controller.statusMessage?.severity == .info else { return }
            controller.statusMessage = nil
        }
        .focusedSceneValue(\.mossmarkDocument, focusedDocument)
        .onChange(of: controller.isImmersiveReading) { _, isImmersive in
            showsFindBar = false
            #if os(macOS)
            if isImmersive {
                sidebarVisibilityBeforeImmersiveReading = sidebarVisibility
                withAnimation { sidebarVisibility = .detailOnly }
            } else if let previous = sidebarVisibilityBeforeImmersiveReading {
                withAnimation { sidebarVisibility = previous }
                sidebarVisibilityBeforeImmersiveReading = nil
            }
            #endif
        }
        .alert("插入链接", isPresented: $showsLinkPrompt) {
            TextField("https://example.com", text: $linkTarget)
            Button("取消", role: .cancel) {}
            Button("插入") {
                controller.applyFormatting(.link, stringValue: linkTarget)
            }
        } message: {
            Text("选中文本将成为链接标题。")
        }
        .alert("插入图片", isPresented: $showsImagePrompt) {
            TextField("images/image.png", text: $imageTarget)
            Button("取消", role: .cancel) {}
            Button("插入") {
                controller.applyFormatting(.image, stringValue: imageTarget)
            }
        } message: {
            Text("建议使用相对于当前 Markdown 文件的路径。")
        }
        .alert(item: $presentedError) { error in
            Alert(
                title: Text("error.title"),
                message: Text(error.message),
                dismissButton: .default(Text("common.ok"))
            )
        }
        .toolbar {
            if !controller.isImmersiveReading {
                ToolbarItem(placement: .navigation) {
                    Button {
                        #if os(iOS)
                        presentedSheet = .sidebar
                        #else
                        withAnimation {
                            sidebarVisibility = sidebarVisibility == .detailOnly ? .automatic : .detailOnly
                        }
                        #endif
                    } label: {
                        Label("侧栏", systemImage: "sidebar.left")
                    }
                    .disabled(!controller.isDocumentLoaded)
                    .accessibilityIdentifier("mossmark.document-sidebar")
                }
                #if os(macOS)
                ToolbarItem(placement: .principal) {
                    modePicker
                        .frame(maxWidth: 230)
                }
                #endif
                ToolbarItemGroup(placement: .secondaryAction) {
                    Button {
                        showsFindBar.toggle()
                    } label: {
                        Label("查找与替换", systemImage: "magnifyingglass")
                    }
                    .keyboardShortcut("f", modifiers: .command)

                    Button {
                        controller.toggleImmersiveReading()
                    } label: {
                        Label("沉浸阅读", systemImage: "rectangle.expand.vertical")
                    }
                    .disabled(controller.mode != .preview || !controller.isReady)

                    Menu("视图", systemImage: "eye") {
                        Toggle(
                            "专注模式（仅当前段落保持亮度）",
                            isOn: Binding(
                                get: { controller.focusMode },
                                set: { controller.setFocusMode($0) }
                            )
                        )
                        Toggle(
                            "打字机模式（输入行始终居中）",
                            isOn: Binding(
                                get: { controller.typewriterMode },
                                set: { controller.setTypewriterMode($0) }
                            )
                        )
                        Divider()
                        Picker("typography.title", selection: typographyPresetBinding) {
                            ForEach(MarkdownTypographyPreset.allCases, id: \.self) { preset in
                                Text(LocalizedStringKey(preset.localizationKey)).tag(preset)
                            }
                        }
                    }

                    #if os(iOS)
                    Button {
                        presentedSheet = .settings
                    } label: {
                        Label("settings.title", systemImage: "gearshape")
                    }
                    .accessibilityIdentifier("mossmark.settings-button")
                    #endif
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        #if os(iOS)
                        Button("share.markdown", systemImage: "doc.text") {
                            shareMarkdown()
                        }
                        Divider()
                        Button("share.pdf", systemImage: "doc.richtext") {
                            exportPDF()
                        }
                        Button("share.docx", systemImage: "doc.text") {
                            exportDOCX()
                        }
                        Button("share.html", systemImage: "doc.plaintext") {
                            exportHTML()
                        }
                        #else
                        Button("导出 PDF", systemImage: "doc.richtext") {
                            exportPDF()
                        }
                        Button("导出 DOCX", systemImage: "doc.text") {
                            exportDOCX()
                        }
                        Button("导出 HTML", systemImage: "doc.plaintext") {
                            exportHTML()
                        }
                        #endif
                        Divider()
                        Button("print.menu-item", systemImage: "printer") {
                            printDocument()
                        }
                        .disabled(isPrinting)
                    } label: {
                        if controller.isExporting || isPrinting {
                            ProgressView()
                        } else {
                            #if os(iOS)
                            Label("share.title", systemImage: "square.and.arrow.up")
                            #else
                            Label("导出", systemImage: "square.and.arrow.up")
                            #endif
                        }
                    }
                    .disabled(
                        !controller.isDocumentLoaded || controller.isExporting || isPrinting
                    )
                    .accessibilityIdentifier("mossmark.export-menu")
                }
            }
        }
        #if os(iOS)
        .toolbar(
            controller.isImmersiveReading ? .hidden : .visible,
            for: .navigationBar
        )
        .toolbar {
            if horizontalSizeClass == .compact, !controller.isImmersiveReading {
                ToolbarItem(placement: .principal) {
                    compactModeMenu
                }
            }
        }
        #else
        .toolbar(
            controller.isImmersiveReading ? .hidden : .visible,
            for: .windowToolbar
        )
        #endif
        .fileExporter(
            isPresented: $presentsExporter,
            document: exportedDocument,
            contentType: exportedContentType,
            defaultFilename: exportedFilename
        ) { result in
            switch result {
            case .success:
                break
            case let .failure(error):
                presentedError = PresentedAppError(message: error.localizedDescription)
            }
            exportedDocument = nil
        }
        .fileImporter(
            isPresented: $presentsImageImporter,
            allowedContentTypes: [.image, .data]
        ) { result in
            importImage(result)
        }
        #if os(iOS)
        .photosPicker(
            isPresented: $presentsPhotoPicker,
            selection: $selectedPhotoItem,
            matching: .images
        )
        .onChange(of: selectedPhotoItem) { _, item in
            guard let item else { return }
            importPhoto(item)
        }
        .sheet(item: $sharedExportFile) { file in
            IOSShareSheet(file: file) { _, error in
                if let error {
                    presentedError = PresentedAppError(message: error.localizedDescription)
                }
                sharedExportFile = nil
            }
            .onDisappear {
                file.cleanup()
            }
        }
        #endif
        .sheet(item: $presentedSheet, onDismiss: handlePresentedSheetDismissal) { sheet in
            presentedSheetContent(sheet)
        }
    }

    @ViewBuilder
    private func presentedSheetContent(_ sheet: PresentedDocumentSheet) -> some View {
        switch sheet {
        case .sidebar:
            #if os(iOS)
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Text(baseFilename)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Button("完成") { presentedSheet = nil }
                        .accessibilityIdentifier("mossmark.sidebar-done")
                }
                .padding(.horizontal, 20)
                .frame(height: 54)

                Divider()
                documentSidebar
            }
            #else
            NavigationStack {
                documentSidebar
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("完成") { presentedSheet = nil }
                        }
                    }
            }
            #endif
        case .settings:
            NavigationStack {
                MossmarkSettingsView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("common.done") { presentedSheet = nil }
                        }
                    }
            }
        }
    }

    @ViewBuilder
    private func statusBannerOverlay() -> some View {
        if let status = controller.statusMessage,
           !controller.isImmersiveReading || status.severity == .info {
            statusBanner(status)
        }
    }

    @ViewBuilder
    private var navigationContent: some View {
        #if os(iOS)
        editorArea
            .toolbarBackground(
                controller.isImmersiveReading ? .hidden : .visible,
                for: .navigationBar
            )
        #else
        NavigationSplitView(
            columnVisibility: $sidebarVisibility,
            preferredCompactColumn: $preferredCompactColumn
        ) {
            // Constant ideal width, no persistence: any state write during a live
            // column drag feeds a layout pass back into AppKit's resize tracking
            // and breaks real-mouse resizing. (No binding API exists for this.)
            documentSidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 260, max: 480)
        } detail: {
            editorArea
                .overlay(alignment: .bottom) {
                    statusBannerOverlay()
                }
        }
        #endif
    }

    private var editorArea: some View {
        VStack(spacing: 0) {
            #if os(iOS)
            if !controller.isImmersiveReading, horizontalSizeClass == .regular {
                HStack(spacing: 12) {
                    modePicker
                        .frame(maxWidth: 320)
                    Spacer(minLength: 0)
                    if showsStatusBar {
                        statusBarContent
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.bar)
                Divider()
            }
            #endif
            if showsFindBar && !controller.isImmersiveReading {
                findBar
                Divider()
            }
            #if os(iOS)
            statusBannerOverlay()
            #endif
            MarkdownEditorWebView(
                document: $document,
                fileURL: fileURL,
                isEditable: isEditable,
                controller: controller,
                initialMode: initialMode,
                onInitialLoadComplete: initialLoadCompleteHandler,
                onScrollProgress: scrollProgressHandler
            )
            .overlay { loadingOverlay }
            .overlay { emptyDocumentOverlay }
            #if os(macOS)
            if controller.mode != .preview {
                Divider()
                formattingBar
            }
            if showsStatusBar && !controller.isImmersiveReading {
                Divider()
                statusBar
            }
            #else
            // Persistent bottom bar while editing: the formatting bar sits
            // below the editor (above the status bar, as on macOS) and rides
            // above the keyboard via the layout's default keyboard avoidance.
            if controller.mode != .preview, isEditable, !controller.isImmersiveReading {
                Divider()
                formattingBar
                if horizontalSizeClass == .compact, showsStatusBar {
                    Divider()
                    statusBar
                }
            }
            #endif
        }
    }

    private var editorBackgroundColor: Color {
        #if os(macOS)
        Color(nsColor: .textBackgroundColor)
        #else
        Color(uiColor: .systemBackground)
        #endif
    }

    @ViewBuilder
    private var loadingOverlay: some View {
        if !controller.isDocumentLoaded {
            ZStack {
                editorBackgroundColor
                ProgressView("editor.loading")
            }
            .accessibilityIdentifier("mossmark.editor-loading")
        }
    }

    @ViewBuilder
    private var emptyDocumentOverlay: some View {
        if controller.isDocumentLoaded,
           controller.mode == .preview,
           documentStatistics.wordCount == 0,
           !controller.isImmersiveReading {
            ContentUnavailableView {
                Label("empty.document.title", systemImage: "square.and.pencil")
            } description: {
                Text("empty.document.hint")
            }
            .background(editorBackgroundColor)
        }
    }

    private var statusBarContent: some View {
        HStack(spacing: 5) {
            Text(
                String.localizedStringWithFormat(
                    String(localized: "statusbar.words %lld"),
                    documentStatistics.wordCount
                )
            )
            Text("·")
            Text(
                String.localizedStringWithFormat(
                    String(localized: "stats.minutes %lld"),
                    documentStatistics.estimatedReadingMinutes
                )
            )
            Text("·")
            Text(LocalizedStringKey(controller.mode.localizationKey))
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    private var statusBar: some View {
        HStack {
            statusBarContent
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(.bar)
    }

    #if os(iOS)
    private var compactModeMenu: some View {
        Menu {
            Picker("显示模式", selection: modeBinding) {
                ForEach(MarkdownEditorMode.allCases, id: \.self) { mode in
                    Text(LocalizedStringKey(mode.localizationKey)).tag(mode)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(LocalizedStringKey(controller.mode.localizationKey))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
            }
        }
        .disabled(!controller.isDocumentLoaded)
        .accessibilityIdentifier("mossmark.mode-picker")
    }
    #endif

    private var documentSidebar: some View {
        List {
            Section("stats.document") {
                LabeledContent("stats.words") {
                    Text(documentStatistics.wordCount, format: .number)
                }
                LabeledContent("stats.characters") {
                    Text(documentStatistics.characterCount, format: .number)
                }
                LabeledContent("stats.reading-time") {
                    Text(
                        String.localizedStringWithFormat(
                            String(localized: "stats.minutes %lld"),
                            documentStatistics.estimatedReadingMinutes
                        )
                    )
                }
            }

            Section("大纲") {
                if outlineItems.isEmpty {
                    Text("暂无标题")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(outlineItems) { item in
                        Button {
                            selectOutlineItem(item)
                        } label: {
                            HStack(spacing: 7) {
                                Capsule()
                                    .fill(Color.accentColor)
                                    .frame(width: 3, height: 18)
                                    .opacity(controller.currentHeadingIndex == item.id ? 1 : 0)
                                Text(item.title)
                                    .lineLimit(2)
                                    .fontWeight(
                                        controller.currentHeadingIndex == item.id
                                            ? .semibold
                                            : .regular
                                    )
                                Spacer(minLength: 0)
                            }
                            .padding(.leading, CGFloat(max(0, item.level - 1)) * 10)
                            .foregroundStyle(
                                controller.currentHeadingIndex == item.id
                                    ? Color.accentColor
                                    : Color.primary
                            )
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("mossmark.outline.\(item.id)")
                    }
                }
            }

            if !siblingDocuments.isEmpty {
                Section("同目录文档") {
                    ForEach(siblingDocuments, id: \.self) { url in
                        Button {
                            selectSiblingDocument(url)
                        } label: {
                            Label(
                                url.deletingPathExtension().lastPathComponent,
                                systemImage: url == fileURL ? "doc.text.fill" : "doc.text"
                            )
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier(
                            "mossmark.sibling.\(url.lastPathComponent)"
                        )
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .accessibilityIdentifier("mossmark.document-sidebar-list")
        .navigationTitle(baseFilename)
    }

    private var findBar: some View {
        HStack(spacing: 8) {
            TextField("查找", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .onSubmit { controller.find(searchText, caseSensitive: findCaseSensitive) }
            if !searchText.isEmpty, let matchCount {
                Text(
                    String.localizedStringWithFormat(
                        String(localized: "find.match-count %lld"),
                        matchCount
                    )
                )
                .foregroundStyle(.secondary)
                .fixedSize()
            }
            Toggle(isOn: $findCaseSensitive) {
                Text("Aa")
            }
            .toggleStyle(.button)
            .help("find.case-sensitive")
            .accessibilityLabel("find.case-sensitive")
            Button {
                controller.find(searchText, backwards: true, caseSensitive: findCaseSensitive)
            } label: {
                Image(systemName: "chevron.up")
            }
            .accessibilityLabel("find.previous")
            .disabled(searchText.isEmpty)
            Button {
                controller.find(searchText, caseSensitive: findCaseSensitive)
            } label: {
                Image(systemName: "chevron.down")
            }
            .accessibilityLabel("find.next")
            .disabled(searchText.isEmpty)
            TextField("替换为", text: $replacementText)
                .textFieldStyle(.roundedBorder)
            Button("全部替换") {
                controller.replaceAll(
                    query: searchText,
                    replacement: replacementText,
                    caseSensitive: findCaseSensitive
                )
            }
            .disabled(searchText.isEmpty || !isEditable)
            Button {
                showsFindBar = false
            } label: {
                Image(systemName: "xmark")
            }
            .accessibilityLabel("common.close")
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.bar)
        #if os(macOS)
        .onExitCommand {
            showsFindBar = false
        }
        #else
        .background {
            Button("common.close") {
                showsFindBar = false
            }
            .keyboardShortcut(.escape, modifiers: [])
            .frame(width: 0, height: 0)
            .opacity(0)
            .allowsHitTesting(false)
        }
        #endif
        .task(
            id: FindCountQuery(
                query: searchText,
                caseSensitive: findCaseSensitive,
                visible: showsFindBar,
                ready: controller.isReady,
                source: document.content.source
            )
        ) {
            guard showsFindBar, controller.isReady, !searchText.isEmpty else {
                matchCount = nil
                return
            }
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            matchCount = await controller.countMatches(
                query: searchText,
                caseSensitive: findCaseSensitive
            )
        }
    }

    private var formattingBar: some View {
        formattingBarContent
            .background(.bar)
    }

    private var formattingBarContent: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                formatButton("粗体", systemImage: "bold", command: .bold)
                formatButton("斜体", systemImage: "italic", command: .italic)
                formatButton("删除线", systemImage: "strikethrough", command: .strikethrough)
                formatButton("行内代码", systemImage: "chevron.left.forwardslash.chevron.right", command: .inlineCode)
                Divider().frame(height: 20)
                Menu {
                    ForEach(1...6, id: \.self) { level in
                        Button("标题 \(level)") {
                            controller.applyFormatting(.heading, numberValue: level)
                        }
                    }
                } label: {
                    formattingControlLabel(systemImage: "textformat.size")
                }
                .help("标题")
                .accessibilityLabel("标题")
                .accessibilityIdentifier("mossmark.format.heading")
                formatButton("无序列表", systemImage: "list.bullet", command: .bulletList)
                formatButton("有序列表", systemImage: "list.number", command: .orderedList)
                formatButton("引用", systemImage: "text.quote", command: .blockquote)
                formatButton("代码块", systemImage: "curlybraces", command: .codeBlock)
                tableMenu
                formatButton("分隔线", systemImage: "minus", command: .horizontalRule)
                Divider().frame(height: 20)
                Button {
                    showsLinkPrompt = true
                } label: {
                    formattingControlLabel(systemImage: "link")
                }
                .help("链接")
                .accessibilityLabel("链接")
                .accessibilityIdentifier("mossmark.format.link")
                Menu {
                    #if os(iOS)
                    Button {
                        presentsPhotoPicker = true
                    } label: {
                        Label("image.choose-photos", systemImage: "photo.on.rectangle")
                    }
                    .disabled(fileURL == nil || isImportingImage)
                    Button("image.choose-files", systemImage: "folder") {
                        presentsImageImporter = true
                    }
                    .disabled(fileURL == nil || isImportingImage)
                    #else
                    Button("image.choose", systemImage: "photo.on.rectangle") {
                        presentsImageImporter = true
                    }
                    .disabled(fileURL == nil || isImportingImage)
                    #endif
                    Button("image.enter-path", systemImage: "text.cursor") {
                        showsImagePrompt = true
                    }
                } label: {
                    if isImportingImage {
                        ProgressView()
                            .controlSize(.small)
                            #if os(iOS)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                            #endif
                    } else {
                        formattingControlLabel(systemImage: "photo")
                    }
                }
                .help("图片")
                .accessibilityLabel("图片")
                .accessibilityIdentifier("mossmark.format.image")
            }
            #if os(iOS)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            #else
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            #endif
        }
        .disabled(!controller.isReady || controller.mode == .preview || !isEditable)
    }

    private var tableMenu: some View {
        Menu {
            Button("table.insert", systemImage: "tablecells") {
                controller.applyFormatting(.table)
            }
            Divider()
            Section("table.rows") {
                Button("table.row-before", systemImage: "arrow.up.to.line") {
                    controller.editTable(.addRowBefore)
                }
                Button("table.row-after", systemImage: "arrow.down.to.line") {
                    controller.editTable(.addRowAfter)
                }
                Button("table.delete-row", systemImage: "trash") {
                    controller.editTable(.deleteRow)
                }
            }
            Section("table.columns") {
                Button("table.column-before", systemImage: "arrow.left.to.line") {
                    controller.editTable(.addColumnBefore)
                }
                Button("table.column-after", systemImage: "arrow.right.to.line") {
                    controller.editTable(.addColumnAfter)
                }
                Button("table.delete-column", systemImage: "trash") {
                    controller.editTable(.deleteColumn)
                }
            }
            Section("table.alignment") {
                Button("table.align-left", systemImage: "text.alignleft") {
                    controller.editTable(.alignLeft)
                }
                Button("table.align-center", systemImage: "text.aligncenter") {
                    controller.editTable(.alignCenter)
                }
                Button("table.align-right", systemImage: "text.alignright") {
                    controller.editTable(.alignRight)
                }
            }
        } label: {
            formattingControlLabel(systemImage: "tablecells")
        }
        .help("表格")
        .accessibilityLabel("表格")
        .accessibilityIdentifier("mossmark.format.table")
    }

    private func formatButton(
        _ title: LocalizedStringKey,
        systemImage: String,
        command: MarkdownFormattingCommand
    ) -> some View {
        Button {
            controller.applyFormatting(command)
        } label: {
            formattingControlLabel(systemImage: systemImage)
        }
        .help(Text(title))
        .accessibilityLabel(Text(title))
        .accessibilityIdentifier("mossmark.format.\(command.rawValue)")
    }

    @ViewBuilder
    private func formattingControlLabel(systemImage: String) -> some View {
        #if os(iOS)
        Image(systemName: systemImage)
            .font(.system(size: 18))
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        #else
        Image(systemName: systemImage)
        #endif
    }

    private var modeBinding: Binding<MarkdownEditorMode> {
        Binding(
            get: { controller.mode },
            set: { controller.setMode($0) }
        )
    }

    private var typographyPresetBinding: Binding<MarkdownTypographyPreset> {
        Binding(
            get: {
                MarkdownTypographyPreset(rawValue: typographyPresetRaw) ?? .quiet
            },
            set: { preset in
                typographyPresetRaw = preset.rawValue
                controller.setTypographyPreset(preset)
            }
        )
    }

    private var modePicker: some View {
        Picker("显示模式", selection: modeBinding) {
            ForEach(MarkdownEditorMode.allCases, id: \.self) { mode in
                Text(LocalizedStringKey(mode.localizationKey)).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .disabled(!controller.isDocumentLoaded)
        .accessibilityIdentifier("mossmark.mode-picker")
    }

    #if os(iOS)
    private func statusBanner(_ status: EditorStatusMessage) -> some View {
        HStack(spacing: 8) {
            Image(systemName: status.severity.systemImage)
                .foregroundStyle(status.severity.color)
            Text(status.message)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                controller.statusMessage = nil
            } label: {
                Image(systemName: "xmark")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("common.close")
        }
        .font(.footnote)
        .padding(.leading, 12)
        .padding(.trailing, 2)
        .background(.bar)
    }
    #else
    private func statusBanner(_ status: EditorStatusMessage) -> some View {
        HStack(spacing: 10) {
            Image(systemName: status.severity.systemImage)
                .foregroundStyle(status.severity.color)
            Text(status.message)
                .lineLimit(2)
            Button {
                controller.statusMessage = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("common.close")
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .padding()
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isStaticText)
    }
    #endif

    private var baseFilename: String {
        let candidate = fileURL?.deletingPathExtension().lastPathComponent ?? "Markdown"
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = candidate.components(separatedBy: invalid).joined(separator: "-")
        return cleaned.isEmpty ? "Markdown" : cleaned
    }

    private var initialLoadCompleteHandler: (() async -> Void)? {
        #if os(iOS)
        return restoreScrollProgressIfNeeded
        #else
        return nil
        #endif
    }

    /// Persists the reading progress reported live by the engine after
    /// scrolling settles. Capturing at teardown raced the WebView's disposal
    /// and silently lost the position, so the engine pushes it instead.
    private var scrollProgressHandler: ((Double) -> Void)? {
        #if os(iOS)
        return { [readingHistory] progress in
            guard let fileURL else { return }
            readingHistory.setScrollProgress(progress, for: fileURL)
        }
        #else
        return nil
        #endif
    }

    #if os(iOS)
    /// Restores the persisted reading progress once the initial document
    /// load has been applied — the engine resets its scroll state during
    /// `load`, so an earlier restore would be discarded.
    private func restoreScrollProgressIfNeeded() async {
        guard !hasRestoredScrollProgress, let fileURL else { return }
        hasRestoredScrollProgress = true
        let progress = readingHistory.scrollProgress(for: fileURL)
        guard progress > 0 else { return }
        await controller.restoreScrollProgress(progress)
    }
    #endif

    private func openSiblingDocument(_ url: URL) {
        if let onOpenDocument {
            onOpenDocument(url)
            return
        }
        #if os(macOS)
        // SwiftUI's openURL silently drops file URLs in a DocumentGroup scene, and a
        // bare NSWorkspace.open(url) defers to the (possibly absent) default handler
        // for .md. Route the file to this app explicitly, like `open -a` does.
        NSWorkspace.shared.open(
            [url],
            withApplicationAt: Bundle.main.bundleURL,
            configuration: NSWorkspace.OpenConfiguration()
        )
        #else
        openURL(url)
        #endif
    }

    private func selectOutlineItem(_ item: MarkdownOutlineItem) {
        #if os(iOS)
        // Dismiss first. Covered WKWebViews may throttle animation frames, so
        // CodeMirror cannot reliably finish its measure/scroll cycle while the
        // sidebar sheet is still on screen.
        pendingOutlineItem = item
        presentedSheet = nil
        #else
        Task {
            _ = await controller.scrollToHeading(index: item.id, line: item.line)
        }
        preferredCompactColumn = .detail
        #endif
    }

    private func selectSiblingDocument(_ url: URL) {
        #if os(iOS)
        guard url != fileURL else {
            presentedSheet = nil
            return
        }
        pendingSiblingURL = url
        presentedSheet = nil
        #else
        openSiblingDocument(url)
        #endif
    }

    private func handlePresentedSheetDismissal() {
        if let item = pendingOutlineItem {
            pendingOutlineItem = nil
            Task {
                if !(await controller.scrollToHeading(index: item.id, line: item.line)) {
                    controller.postStatus(
                        String(localized: "outline.navigation-failed"),
                        severity: .warning
                    )
                }
            }
            return
        }
        if let url = pendingSiblingURL {
            pendingSiblingURL = nil
            openSiblingDocument(url)
        }
    }

    private func loadSiblingDocuments() async {
        guard let fileURL else {
            siblingDocuments = []
            return
        }
        let directory = fileURL.deletingLastPathComponent()
        let supportedExtensions = Set(["md", "markdown", "mdown", "mkd"])
        siblingDocuments = await Task.detached(priority: .utility) {
            ((try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )) ?? [])
                .filter { supportedExtensions.contains($0.pathExtension.lowercased()) }
                .sorted {
                    $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent)
                        == .orderedAscending
                }
        }.value
    }

    private func importImage(_ result: Result<URL, any Error>) {
        guard case let .success(sourceURL) = result else {
            if case let .failure(error) = result {
                presentedError = PresentedAppError(message: error.localizedDescription)
            }
            return
        }
        guard let fileURL else {
            presentedError = PresentedAppError(
                message: String(localized: "image.save-document-first")
            )
            return
        }

        isImportingImage = true
        Task {
            defer { isImportingImage = false }
            do {
                let relativePath = try await Task.detached(priority: .userInitiated) {
                    let accessed = sourceURL.startAccessingSecurityScopedResource()
                    defer {
                        if accessed { sourceURL.stopAccessingSecurityScopedResource() }
                    }
                    return try MarkdownAssetManager.importImage(
                        at: sourceURL,
                        relativeTo: fileURL
                    )
                }.value
                controller.applyFormatting(.image, stringValue: relativePath)
                await loadSiblingDocuments()
            } catch {
                presentedError = PresentedAppError(
                    message: localizedImageImportErrorMessage(error)
                )
            }
        }
    }

    #if os(iOS)
    private func importPhoto(_ item: PhotosPickerItem) {
        guard let fileURL else {
            selectedPhotoItem = nil
            presentedError = PresentedAppError(
                message: String(localized: "image.save-document-first")
            )
            return
        }

        isImportingImage = true
        Task {
            defer {
                isImportingImage = false
                selectedPhotoItem = nil
            }
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    throw MarkdownAssetManager.ImportError.invalidSource
                }
                let suggestedFilename = item.itemIdentifier ?? "photo"
                let relativePath = try await Task.detached(priority: .userInitiated) {
                    try MarkdownAssetManager.importImage(
                        data: data,
                        suggestedFilename: suggestedFilename,
                        relativeTo: fileURL
                    )
                }.value
                controller.applyFormatting(.image, stringValue: relativePath)
            } catch {
                presentedError = PresentedAppError(
                    message: localizedImageImportErrorMessage(error)
                )
            }
        }
    }
    #endif

    #if os(iOS)
    private func shareMarkdown() {
        controller.isExporting = true
        Task {
            defer { controller.isExporting = false }
            do {
                let markdown = try await controller.currentMarkdown()
                var snapshot = document
                snapshot.content.source = markdown
                let originalExtension = fileURL?.pathExtension
                let fileExtension = originalExtension.flatMap { value in
                    value.isEmpty ? nil : value
                } ?? "md"
                try await presentGeneratedFile(
                    data: snapshot.serializedData(),
                    contentType: MarkdownFileDocument.markdownContentType,
                    filename: baseFilename + "." + fileExtension
                )
            } catch {
                presentedError = PresentedAppError(message: error.localizedDescription)
            }
        }
    }
    #endif

    private func exportPDF() {
        controller.isExporting = true
        Task {
            defer { controller.isExporting = false }
            do {
                let data = try await controller.makePDF(title: baseFilename)
                guard data.starts(with: Data("%PDF".utf8)) else {
                    throw MarkdownExportError.invalidPDF
                }
                try await presentGeneratedFile(
                    data: data,
                    contentType: .pdf,
                    filename: baseFilename + ".pdf"
                )
            } catch {
                presentedError = PresentedAppError(message: error.localizedDescription)
            }
        }
    }

    private func exportDOCX() {
        controller.isExporting = true
        let documentURL = fileURL
        let filename = baseFilename
        Task {
            defer { controller.isExporting = false }
            do {
                let preparation = try await controller.prepareDOCXExport()
                let data = try await Task.detached(priority: .userInitiated) {
                    let exportDocument = MarkdownExportParser.parse(
                        preparation.markdown,
                        fallbackTitle: filename
                    )
                    var images = MarkdownExportImageLoader.loadImages(
                        for: exportDocument,
                        documentURL: documentURL
                    )
                    images.merge(preparation.images) { local, _ in local }
                    return try MarkdownDOCXWriter.makeDocument(
                        from: exportDocument,
                        images: images
                    )
                }.value
                try await presentGeneratedFile(
                    data: data,
                    contentType: BinaryExportDocument.docxContentType,
                    filename: filename + ".docx"
                )
            } catch {
                presentedError = PresentedAppError(message: error.localizedDescription)
            }
        }
    }

    private func exportHTML() {
        controller.isExporting = true
        Task {
            defer { controller.isExporting = false }
            do {
                let html = try await controller.exportHTML(title: baseFilename)
                try await presentGeneratedFile(
                    data: Data(html.utf8),
                    contentType: .html,
                    filename: baseFilename + ".html"
                )
            } catch {
                presentedError = PresentedAppError(message: error.localizedDescription)
            }
        }
    }

    @MainActor
    private func presentGeneratedFile(
        data: Data,
        contentType: UTType,
        filename: String
    ) async throws {
        #if os(iOS)
        let file = try await Task.detached(priority: .userInitiated) {
            try SharedExportFile(data: data, filename: filename)
        }.value
        sharedExportFile?.cleanup()
        sharedExportFile = file
        #else
        exportedDocument = BinaryExportDocument(data: data)
        exportedContentType = contentType
        exportedFilename = filename
        presentsExporter = true
        #endif
    }

    /// Prints the same paginated PDF the export pipeline produces.
    private func printDocument() {
        guard !isPrinting, controller.isDocumentLoaded else { return }
        isPrinting = true
        Task {
            defer { isPrinting = false }
            do {
                let data = try await controller.makePDF(title: baseFilename)
                guard data.starts(with: Data("%PDF".utf8)) else {
                    throw MarkdownExportError.invalidPDF
                }
                try presentPrintPanel(pdfData: data)
            } catch {
                presentedError = PresentedAppError(message: error.localizedDescription)
            }
        }
    }

    #if os(macOS)
    @MainActor
    private func presentPrintPanel(pdfData: Data) throws {
        guard let pdfDocument = PDFDocument(data: pdfData),
              let operation = pdfDocument.printOperation(
                  for: nil,
                  scalingMode: .pageScaleToFit,
                  autoRotate: true
              )
        else {
            throw MarkdownExportError.invalidPDF
        }
        operation.showsPrintPanel = true
        operation.run()
    }
    #else
    @MainActor
    private func presentPrintPanel(pdfData: Data) throws {
        let printController = UIPrintInteractionController.shared
        printController.printingItem = pdfData
        printController.present(animated: true)
    }
    #endif

    private var focusedDocument: MossmarkFocusedDocument {
        MossmarkFocusedDocument(
            controller: controller,
            isEditable: isEditable,
            presentLinkPrompt: { showsLinkPrompt = true },
            printDocument: printDocument
        )
    }
}

private extension EditorStatusSeverity {
    var systemImage: String {
        switch self {
        case .info: "info.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    var color: Color {
        switch self {
        case .info: .accentColor
        case .warning: .yellow
        case .error: .red
        }
    }
}
