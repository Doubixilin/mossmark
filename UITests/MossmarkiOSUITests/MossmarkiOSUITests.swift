import XCTest

final class MossmarkiOSUITests: XCTestCase {
    /// Smoke test: the self-built document library replaces the system
    /// document browser and must come up with its creation affordance.
    @MainActor
    func testDocumentLibraryLaunches() {
        let app = Self.launchApp()
        let importButton = app.buttons["mossmark.import-document"]
        let newButton = app.buttons["mossmark.new-document"]
        XCTAssertTrue(importButton.waitForExistence(timeout: 15))
        XCTAssertTrue(newButton.waitForExistence(timeout: 15))
        XCTAssertEqual(importButton.label, "Import from Files")
        XCTAssertEqual(newButton.label, "New Document")
        XCTAssertGreaterThanOrEqual(importButton.frame.height, 44)
        XCTAssertGreaterThanOrEqual(newButton.frame.height, 44)
    }

    /// Regression for issue #3 in the new architecture: create a document in
    /// the library, type, go back, reopen from the list, and require the
    /// typed marker to be rendered.
    @MainActor
    func testNewDocumentRoundtripThroughLibrary() throws {
        // Deterministic naming: with an empty library the new document is
        // always "Untitled.md" (en locale).
        try Self.clearSeededDocuments()
        let app = Self.launchApp()
        let marker = "qmrt\(Int(Date().timeIntervalSince1970))"

        let createButton = app.buttons["mossmark.new-document"]
        XCTAssertTrue(createButton.waitForExistence(timeout: 15), "Library must offer document creation")
        createButton.tap()

        Self.waitForEditor(in: app)
        Self.switchToSourceMode(in: app)
        try Self.typeIntoEditor(marker, in: app)
        Self.closeEditor(in: app)

        // The new document must be listed in the library (en locale: Untitled).
        let documentRow = app.buttons["mossmark.document-row.Untitled.md"]
        XCTAssertTrue(
            documentRow.waitForExistence(timeout: 15),
            "Newly created document must appear in the document library"
        )
        documentRow.tap()

        Self.waitForEditor(in: app)
        let renderedMarker = app.webViews.staticTexts
            .matching(NSPredicate(format: "label CONTAINS %@", marker))
            .firstMatch
        XCTAssertTrue(
            renderedMarker.waitForExistence(timeout: 20),
            "Reopened new document must contain the typed marker '\(marker)' (issue #3 regression)"
        )
    }

    /// Opening a document from the library must add it to the reading
    /// history, shown in the Recent section after returning.
    @MainActor
    func testReadingHistoryRecordsOpenedDocument() throws {
        let documentName = "UITest-History"
        try Self.seedDocument(named: "\(documentName).md", contents: "# History\n\n")

        let app = Self.launchApp()

        let documentRow = app.buttons["mossmark.document-row.\(documentName).md"]
        XCTAssertTrue(
            documentRow.waitForExistence(timeout: 15),
            "Seeded document must appear in the document library"
        )
        documentRow.tap()

        Self.waitForEditor(in: app)
        Self.closeEditor(in: app)

        let recentRow = app.buttons["mossmark.recent-row.\(documentName).md"]
        XCTAssertTrue(
            recentRow.waitForExistence(timeout: 15),
            "Opened document must appear in the Recent section (reading history)"
        )
    }

    /// A scan triggered while leaving the editor used to be able to publish
    /// after deletion and reinsert a stale row. Deletion must remain durable
    /// through subsequent refreshes and a full application relaunch.
    @MainActor
    func testDeletedDocumentDoesNotReappear() throws {
        try Self.clearSeededDocuments()
        let documentName = "UITest-Delete-\(UUID().uuidString)"
        let fileName = "\(documentName).md"
        let fileURL = try Self.seedDocument(
            named: fileName,
            contents: "# Delete regression\n\nThis file must stay deleted.\n"
        )

        let app = Self.launchApp()
        let allRow = app.buttons["mossmark.document-row.\(fileName)"]
        XCTAssertTrue(allRow.waitForExistence(timeout: 15))

        // Put the document in both Recent and All, then return to the library.
        // The on-dismiss refresh deliberately overlaps the deletion flow that
        // produced the original intermittent reappearance.
        allRow.tap()
        Self.waitForEditor(in: app)
        Self.closeEditor(in: app)

        let recentRow = app.buttons["mossmark.recent-row.\(fileName)"]
        XCTAssertTrue(recentRow.waitForExistence(timeout: 15))
        let rowToDelete = app.buttons["mossmark.document-row.\(fileName)"]
        XCTAssertTrue(rowToDelete.waitForExistence(timeout: 15))
        rowToDelete.swipeLeft()

        let swipeDelete = app.buttons["Delete"]
        XCTAssertTrue(swipeDelete.waitForExistence(timeout: 5))
        swipeDelete.tap()

        let confirmationDialog = app.sheets.firstMatch
        XCTAssertTrue(confirmationDialog.waitForExistence(timeout: 5))
        XCTAssertTrue(
            rowToDelete.exists,
            "Requesting confirmation must not optimistically remove and reinsert the row"
        )
        XCTAssertTrue(recentRow.exists)
        let confirmDelete = confirmationDialog.buttons["Delete"]
        XCTAssertTrue(confirmDelete.waitForExistence(timeout: 5))
        confirmDelete.tap()

        XCTAssertTrue(Self.waitForNonExistence(rowToDelete, timeout: 10))
        XCTAssertTrue(Self.waitForNonExistence(recentRow, timeout: 10))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))

        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        XCTAssertFalse(app.buttons["mossmark.document-row.\(fileName)"].exists)
        XCTAssertFalse(app.buttons["mossmark.recent-row.\(fileName)"].exists)

        app.terminate()
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        XCTAssertFalse(app.buttons["mossmark.document-row.\(fileName)"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["mossmark.recent-row.\(fileName)"].exists)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    /// Formatting controls are persistent above the keyboard on iPhone, so
    /// their hit regions must remain finger-sized instead of collapsing to
    /// the intrinsic SF Symbol bounds.
    @MainActor
    func testFormattingControlsHaveMinimumTouchTargets() throws {
        let documentName = "UITest-FormattingTargets"
        try Self.seedDocument(named: "\(documentName).md", contents: "# Formatting\n\nBody\n")

        let app = Self.launchApp()
        let documentRow = app.buttons["mossmark.document-row.\(documentName).md"]
        XCTAssertTrue(documentRow.waitForExistence(timeout: 15))
        documentRow.tap()

        Self.waitForEditor(in: app)
        Self.switchToSourceMode(in: app)

        for identifier in [
            "mossmark.format.bold",
            "mossmark.format.italic",
            "mossmark.format.strikethrough",
            "mossmark.format.inline-code",
            "mossmark.format.heading",
        ] {
            let control = app.buttons[identifier]
            XCTAssertTrue(control.waitForExistence(timeout: 10), "Missing formatting control \(identifier)")
            XCTAssertGreaterThanOrEqual(control.frame.width, 44, "\(identifier) is too narrow")
            XCTAssertGreaterThanOrEqual(control.frame.height, 44, "\(identifier) is too short")
        }
    }

    /// Repeated outline selections in one editor session must each be
    /// acknowledged by the engine before the sidebar dismisses.
    @MainActor
    func testOutlineSelectionScrollsAfterSidebarDismissal() throws {
        // Use a fresh URL on every run so a prior test's reading-history
        // position cannot make a failed outline tap look successful.
        try Self.clearSeededDocuments()
        let documentName = "UITest-Outline-\(UUID().uuidString)"
        let markdown = (1...200).map { index in
            "# Section \(index)\n\n" + String(repeating: "Body \(index). ", count: 16)
        }.joined(separator: "\n\n")
        try Self.seedDocument(named: "\(documentName).md", contents: markdown)

        let app = Self.launchApp()
        let row = app.buttons["mossmark.document-row.\(documentName).md"]
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.tap()
        Self.waitForEditor(in: app)

        func selectHeading(_ index: Int, title: String) {
            let sidebar = app.buttons["mossmark.document-sidebar"]
            XCTAssertTrue(sidebar.waitForExistence(timeout: 10))
            sidebar.tap()

            let heading = app.buttons["mossmark.outline.\(index)"]
            let sidebarList = app.collectionViews["mossmark.document-sidebar-list"]
            let sidebarDone = app.buttons["mossmark.sidebar-done"]
            XCTAssertTrue(sidebarList.waitForExistence(timeout: 10))
            XCTAssertTrue(sidebarDone.waitForExistence(timeout: 10))
            // A new sidebar sheet starts at the top. Avoid enumerating all 200
            // lazy rows on every swipe; that masks timing races by adding tens
            // of seconds of accessibility queries.
            for _ in 0..<45 where !heading.isHittable {
                if index > 10 {
                    sidebarList.swipeUp(velocity: .fast)
                } else {
                    sidebarList.swipeDown(velocity: .fast)
                }
            }
            XCTAssertTrue(heading.exists, "Outline item \(index) must exist after scrolling")
            XCTAssertTrue(heading.isHittable, "Outline item \(index) must be tappable")
            XCTAssertGreaterThanOrEqual(heading.frame.height, 44)
            XCTAssertGreaterThan(heading.frame.width, sidebarList.frame.width * 0.8)
            Self.tapTrailingVisibleEdge(of: heading, below: sidebarDone, in: app)

            XCTAssertTrue(
                Self.waitForNonExistence(heading, timeout: 10),
                "Sidebar item must disappear after the engine accepts the outline selection"
            )
            let target = app.webViews.staticTexts[title]
            XCTAssertTrue(
                Self.waitUntilHittable(target, timeout: 10),
                "\(title) must be visible after outline navigation"
            )
        }

        // Exercise a far target in each rendering surface. Keeping both
        // selections monotonic avoids spending minutes scrolling the native
        // sidebar back and forth, while the document itself still has 200
        // headings and forces a large WebKit/CodeMirror jump.
        selectHeading(149, title: "Section 150")

        Self.switchToSourceMode(in: app)
        selectHeading(199, title: "Section 200")
    }

    /// Repeated sibling selections must finish dismissing the old full-screen
    /// editor before a freshly owned document store is presented.
    @MainActor
    func testSiblingSelectionOpensInsideLibraryEditor() throws {
        try Self.clearSeededDocuments()
        let firstName = "UITest-Sibling-A"
        let secondName = "UITest-Sibling-B"
        let thirdName = "UITest-Sibling-C"
        let firstMarker = "Sibling A marker"
        let secondMarker = "Sibling B marker"
        let thirdMarker = "Sibling C marker"
        try Self.seedDocument(named: "\(firstName).md", contents: "# \(firstMarker)\n")
        try Self.seedDocument(named: "\(secondName).md", contents: "# \(secondMarker)\n")
        try Self.seedDocument(named: "\(thirdName).md", contents: "# \(thirdMarker)\n")

        let app = Self.launchApp()
        let row = app.buttons["mossmark.document-row.\(firstName).md"]
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.tap()
        Self.waitForEditor(in: app)
        XCTAssertTrue(Self.waitUntilHittable(app.webViews.staticTexts[firstMarker], timeout: 10))
        // WKWebView exposes nested WebView accessibility nodes on this OS.
        // Stability relative to the initial editor is the leak/regression gate.
        let baselineWebViewCount = app.webViews.count
        XCTAssertGreaterThan(baselineWebViewCount, 0)

        func openSibling(_ name: String, marker: String, replacing oldMarker: String) {
            let sidebar = app.buttons["mossmark.document-sidebar"]
            XCTAssertTrue(sidebar.waitForExistence(timeout: 20))
            sidebar.tap()
            let sibling = app.buttons["mossmark.sibling.\(name).md"]
            let sidebarList = app.collectionViews["mossmark.document-sidebar-list"]
            let sidebarDone = app.buttons["mossmark.sidebar-done"]
            XCTAssertTrue(sidebarList.waitForExistence(timeout: 10))
            XCTAssertTrue(sidebarDone.waitForExistence(timeout: 10))
            for _ in 0..<16 where !sibling.isHittable {
                sidebarList.swipeUp(velocity: .fast)
            }
            XCTAssertTrue(sibling.exists, "Missing sibling \(name)")
            XCTAssertTrue(sibling.isHittable, "Sibling \(name) must be tappable")
            XCTAssertGreaterThanOrEqual(sibling.frame.height, 44)
            XCTAssertGreaterThan(sibling.frame.width, sidebarList.frame.width * 0.8)
            Self.tapTrailingVisibleEdge(of: sibling, below: sidebarDone, in: app)

            XCTAssertFalse(
                app.buttons["mossmark.new-document"].isHittable,
                "Sibling switching must not flash the document library"
            )
            XCTAssertFalse(app.buttons["mossmark.import-document"].isHittable)
            XCTAssertTrue(
                app.navigationBars[name].waitForExistence(timeout: 15),
                "Navigation title must change to \(name)"
            )
            Self.waitForEditor(in: app)
            XCTAssertTrue(
                Self.waitUntilHittable(app.webViews.staticTexts[marker], timeout: 15),
                "Selecting \(name) must load that document's marker"
            )
            XCTAssertTrue(
                Self.waitForNonExistence(app.webViews.staticTexts[oldMarker], timeout: 10),
                "The previous document marker must leave the accessibility tree"
            )
            XCTAssertEqual(
                app.webViews.count,
                baselineWebViewCount,
                "Switching must not accumulate editor web-view accessibility layers"
            )
            XCTAssertFalse(app.buttons["mossmark.new-document"].isHittable)
            XCTAssertFalse(app.buttons["mossmark.import-document"].isHittable)
        }

        // Two complete A -> B -> C -> A cycles exercise repeated in-place
        // replacement without allowing a return to the library between opens.
        for _ in 0..<2 {
            openSibling(secondName, marker: secondMarker, replacing: firstMarker)
            openSibling(thirdName, marker: thirdMarker, replacing: secondMarker)
            openSibling(firstName, marker: firstMarker, replacing: thirdMarker)
        }
    }

    /// iOS presents native sharing first, followed by converted export formats.
    @MainActor
    func testShareMenuOffersMarkdownAndConvertedFormats() throws {
        let documentName = "UITest-Sharing"
        try Self.seedDocument(
            named: "\(documentName).md",
            contents: "# Sharing\n\nShare sheet fixture.\n"
        )

        let app = Self.launchApp()
        let row = app.buttons["mossmark.document-row.\(documentName).md"]
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.tap()
        Self.waitForEditor(in: app)

        let shareMenu = app.buttons["mossmark.export-menu"]
        XCTAssertTrue(shareMenu.waitForExistence(timeout: 10))
        XCTAssertEqual(shareMenu.label, "Share")
        shareMenu.tap()

        let markdown = app.buttons["Share Markdown…"]
        let pdf = app.buttons["Convert to PDF and Share…"]
        let docx = app.buttons["Convert to DOCX and Share…"]
        let html = app.buttons["Convert to HTML and Share…"]
        for item in [markdown, pdf, docx, html] {
            XCTAssertTrue(item.waitForExistence(timeout: 5), "Missing share action \(item.label)")
        }
        XCTAssertLessThan(markdown.frame.minY, pdf.frame.minY, "Markdown sharing must be first")
        XCTAssertLessThan(markdown.frame.minY, docx.frame.minY)
        XCTAssertLessThan(markdown.frame.minY, html.frame.minY)

        markdown.tap()
        let activityList = app.otherElements["ActivityListView"]
        let shareSheetAppeared = app.sheets.firstMatch.waitForExistence(timeout: 10)
            || activityList.waitForExistence(timeout: 3)
        XCTAssertTrue(shareSheetAppeared, "Share Markdown must present the system share sheet")

        let saveToFiles = app.descendants(matching: .any)
            .matching(
                NSPredicate(
                    format: "label == %@ OR label == %@",
                    "Save to Files",
                    "保存到“文件”"
                )
            )
            .firstMatch
        XCTAssertTrue(
            saveToFiles.waitForExistence(timeout: 10),
            "The system share sheet must offer Save to Files"
        )

        func dismissShareSheet() {
            let closeButton = app.buttons["header.closeButton"]
            XCTAssertTrue(closeButton.waitForExistence(timeout: 10))
            closeButton.tap()
            XCTAssertTrue(Self.waitForNonExistence(activityList, timeout: 10))
        }

        dismissShareSheet()

        for actionName in [
            "Convert to PDF and Share…",
            "Convert to DOCX and Share…",
            "Convert to HTML and Share…",
        ] {
            XCTAssertTrue(shareMenu.waitForExistence(timeout: 10))
            shareMenu.tap()
            let action = app.buttons[actionName]
            XCTAssertTrue(action.waitForExistence(timeout: 5), "Missing share action \(actionName)")
            action.tap()
            XCTAssertTrue(
                activityList.waitForExistence(timeout: 20),
                "\(actionName) must finish conversion and present the system share sheet"
            )
            dismissShareSheet()
        }
    }

    /// iOS offers Photos and Files as distinct image sources, and the Photos
    /// action must outlive the transient formatting menu long enough to
    /// present the system picker.
    @MainActor
    func testImageMenuOffersPhotosAndFiles() throws {
        let documentName = "UITest-ImageSources"
        try Self.seedDocument(named: "\(documentName).md", contents: "# Images\n\nBody\n")

        let app = Self.launchApp()
        let row = app.buttons["mossmark.document-row.\(documentName).md"]
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.tap()
        Self.waitForEditor(in: app)
        Self.switchToSourceMode(in: app)

        let imageMenu = app.buttons["mossmark.format.image"]
        XCTAssertTrue(imageMenu.waitForExistence(timeout: 10))
        let window = app.windows.firstMatch
        let dragStart = window.coordinate(withNormalizedOffset: CGVector(dx: 0.88, dy: 0.88))
        let dragEnd = window.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.88))
        for _ in 0..<3 {
            dragStart.press(forDuration: 0.05, thenDragTo: dragEnd)
        }
        imageMenu.tap()
        let choosePhotos = app.buttons["Choose from Photos…"]
        XCTAssertTrue(choosePhotos.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Choose from Files…"].waitForExistence(timeout: 5))
        choosePhotos.tap()

        XCTAssertTrue(
            app.navigationBars["Photos"].waitForExistence(timeout: 10),
            "Choosing Photos must present the system photo picker after the menu dismisses"
        )
    }

    /// Inserting an image used to leave the generated alt text selected. The
    /// next Return or typed character then replaced part of the image syntax,
    /// making a freshly imported image appear impossible to type after.
    @MainActor
    func testInsertedImageLeavesCaretAfterMarkdown() throws {
        try Self.clearSeededDocuments()
        let fileName = "UITest-ImageCaret-\(UUID().uuidString).md"
        try Self.seedDocument(named: fileName, contents: "")

        let app = Self.launchApp()
        let row = app.buttons["mossmark.document-row.\(fileName)"]
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.tap()
        Self.waitForEditor(in: app)
        Self.switchToSourceMode(in: app)

        let imageMenu = app.buttons["mossmark.format.image"]
        XCTAssertTrue(imageMenu.waitForExistence(timeout: 10))
        let window = app.windows.firstMatch
        let dragStart = window.coordinate(withNormalizedOffset: CGVector(dx: 0.88, dy: 0.88))
        let dragEnd = window.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.88))
        for _ in 0..<3 {
            dragStart.press(forDuration: 0.05, thenDragTo: dragEnd)
        }
        imageMenu.tap()
        let enterPath = app.buttons["Enter Image Path…"]
        XCTAssertTrue(enterPath.waitForExistence(timeout: 5))
        enterPath.tap()

        let insertAlert = app.alerts["Insert Image"]
        XCTAssertTrue(insertAlert.waitForExistence(timeout: 5))
        insertAlert.buttons["Insert"].tap()

        // applyFormatting is asynchronous across the WKWebView bridge. Once
        // focus returns to CodeMirror, type exactly as the reported user flow.
        let editorTextView = app.webViews.firstMatch.textViews.firstMatch
        XCTAssertTrue(editorTextView.waitForExistence(timeout: 10))
        let focusedExpectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hasKeyboardFocus == true"),
            object: editorTextView
        )
        XCTAssertEqual(XCTWaiter.wait(for: [focusedExpectation], timeout: 10), .completed)
        app.typeText("\nText after image")
        Self.closeEditor(in: app)

        // XCUIApplication may migrate the app data to a new container during
        // installation, so resolve the current container again before host-side
        // evidence collection instead of retaining the pre-launch URL.
        let savedURL = try Self.mossmarkDocumentsDirectory()
            .appendingPathComponent(fileName)
        let saved = try String(contentsOf: savedURL, encoding: .utf8)
        XCTAssertTrue(
            saved.contains("![image description](images/image.png)\nText after image"),
            "Typing after insertion must preserve the full image Markdown; saved: \(saved)"
        )
    }

    // MARK: - Flow helpers

    @MainActor
    private static func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        return app
    }

    @MainActor
    private static func waitForEditor(in app: XCUIApplication) {
        XCTAssertTrue(
            app.webViews.firstMatch.waitForExistence(timeout: 30),
            "Editor web view must load after opening a document"
        )
        let loadingOverlay = app.descendants(matching: .any)["mossmark.editor-loading"]
        XCTAssertTrue(
            waitForNonExistence(loadingOverlay, timeout: 30),
            "Editor loading overlay must disappear after the document is applied"
        )
    }

    /// Switches the editor to Source mode through the navigation bar mode menu.
    @MainActor
    private static func switchToSourceMode(in app: XCUIApplication) {
        let modeButton = app.buttons["mossmark.mode-picker"]
        XCTAssertTrue(modeButton.waitForExistence(timeout: 15), "Editor mode menu must exist")

        // The menu stays disabled until the engine reports ready.
        let enabledExpectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isEnabled == true"),
            object: modeButton
        )
        XCTAssertEqual(XCTWaiter.wait(for: [enabledExpectation], timeout: 20), .completed)

        modeButton.tap()
        let sourceItem = app.buttons["Source"]
        XCTAssertTrue(sourceItem.waitForExistence(timeout: 5), "Source mode menu item must exist")
        sourceItem.tap()

        let sourceModeExpectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "Source"),
            object: modeButton
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [sourceModeExpectation], timeout: 15),
            .completed,
            "Mode picker must report Source after the engine accepts the switch"
        )
    }

    @MainActor
    private static func waitUntilHittable(
        _ element: XCUIElement,
        timeout: TimeInterval
    ) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND hittable == true"),
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    @MainActor
    private static func waitForNonExistence(
        _ element: XCUIElement,
        timeout: TimeInterval
    ) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    /// Taps near the row's trailing edge while excluding any portion that is
    /// visually covered by the fixed sheet header. XCUITest can report a row
    /// behind that header as hittable, even though the header receives the tap.
    @MainActor
    private static func tapTrailingVisibleEdge(
        of element: XCUIElement,
        below header: XCUIElement,
        in app: XCUIApplication
    ) {
        let frame = element.frame
        let visibleTop = max(frame.minY, header.frame.maxY)
        XCTAssertGreaterThan(frame.maxY - visibleTop, 8, "Row must have a visible tappable area")
        let tapY = min(frame.maxY - 6, max(frame.midY, visibleTop + 6))
        let appOrigin = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
        appOrigin.withOffset(CGVector(dx: frame.maxX - 8, dy: tapY)).tap()
    }

    /// Types into the CodeMirror contenteditable hosted inside the editor web view.
    @MainActor
    private static func typeIntoEditor(_ text: String, in app: XCUIApplication) throws {
        let webView = app.webViews.firstMatch
        XCTAssertTrue(webView.waitForExistence(timeout: 20))

        let editorTextView = webView.textViews.firstMatch
        if editorTextView.waitForExistence(timeout: 10) {
            editorTextView.tap()
            editorTextView.typeText(" \(text)")
            return
        }

        // Fallback: focus the editor area by coordinate and type into the app.
        webView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
        app.typeText(" \(text)")
    }

    /// Leaves the editor via the library back button in the full-screen cover.
    @MainActor
    private static func closeEditor(in app: XCUIApplication) {
        let backButton = app.buttons["mossmark.library-back-button"]
        XCTAssertTrue(backButton.waitForExistence(timeout: 10), "Editor must show the library back button")
        backButton.tap()
        XCTAssertTrue(
            app.buttons["mossmark.new-document"].waitForExistence(timeout: 15),
            "Closing the editor must return to the document library"
        )
    }

    // MARK: - Container seeding

    /// Writes a fixture document into the installed app's Documents directory.
    /// On the Simulator all containers share the host file system, so the test
    /// runner can locate Mossmark's data container via its metadata plist.
    @MainActor
    @discardableResult
    private static func seedDocument(named name: String, contents: String) throws -> URL {
        let documents = try mossmarkDocumentsDirectory()
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        let url = documents.appendingPathComponent(name)
        try contents.write(
            to: url,
            atomically: true,
            encoding: .utf8
        )
        return url
    }

    /// Removes every Markdown fixture from the app container's Documents
    /// directory so document-creation tests start from an empty library.
    @MainActor
    private static func clearSeededDocuments() throws {
        let documents = try mossmarkDocumentsDirectory()
        let fileManager = FileManager.default
        guard let contents = try? fileManager.contentsOfDirectory(
            at: documents,
            includingPropertiesForKeys: nil
        ) else {
            return
        }
        for url in contents where DocumentLibraryStoreExtensions.contains(url.pathExtension.lowercased()) {
            try fileManager.removeItem(at: url)
        }
    }

    /// Locates the installed Mossmark app's Documents directory. On the
    /// Simulator all containers share the host file system, so the test
    /// runner can find the data container via its metadata plist.
    @MainActor
    private static func mossmarkDocumentsDirectory() throws -> URL {
        #if targetEnvironment(simulator)
        let fileManager = FileManager.default
        // Test runner home: .../data/Containers/Data/Application/<runner-uuid>
        let containersDirectory = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .deletingLastPathComponent()
        let containers = try fileManager.contentsOfDirectory(
            at: containersDirectory,
            includingPropertiesForKeys: nil
        )
        for container in containers {
            let metadataURL = container
                .appendingPathComponent(".com.apple.mobile_container_manager.metadata.plist")
            guard let metadata = NSDictionary(contentsOf: metadataURL),
                  metadata["MCMMetadataIdentifier"] as? String == "com.doubixilin.quietmark"
            else {
                continue
            }
            return container.appendingPathComponent("Documents", isDirectory: true)
        }
        throw XCTSkip("Mossmark app container not found on this Simulator")
        #else
        throw XCTSkip("Container seeding is only supported on the iOS Simulator")
        #endif
    }
}

/// Mirrors the library's supported file extensions (the test target cannot
/// see the app's types).
private let DocumentLibraryStoreExtensions: Set<String> = ["md", "markdown", "mdown", "mkd"]
