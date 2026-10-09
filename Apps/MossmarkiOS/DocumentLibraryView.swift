import MarkdownCore
import SwiftUI
import UniformTypeIdentifiers

private struct PresentedLibraryError: Identifiable {
    let id = UUID()
    let message: String
}

/// Root of the self-built iOS document library that replaces the system
/// DocumentGroup browser: a searchable list of the Markdown files inside
/// the app's `Documents/` directory plus a reading-history section.
struct DocumentLibraryView: View {
    @StateObject private var library = DocumentLibraryStore()
    @EnvironmentObject private var readingHistory: ReadingHistory
    @Environment(\.scenePhase) private var scenePhase

    @State private var searchText = ""
    @State private var showsSettings = false
    @State private var presentsImporter = false
    @State private var renameTarget: LibraryDocument?
    @State private var renameText = ""
    @State private var deleteTarget: LibraryDocument?
    @State private var editorPresentation: EditorPresentation?
    @State private var presentedError: PresentedLibraryError?

    private struct EditorPresentation: Identifiable {
        let id = UUID()
        let store: OpenedDocumentStore
        let startEditing: Bool
    }

    var body: some View {
        NavigationStack {
            libraryContent
                .navigationTitle(Text("library.title"))
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            showsSettings = true
                        } label: {
                            Label("settings.title", systemImage: "gearshape")
                        }
                        .accessibilityIdentifier("mossmark.settings-button")
                    }
                }
                .searchable(text: $searchText, prompt: Text("library.search"))
        }
        .task {
            await library.refresh()
            readingHistory.pruneMissing()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task {
                await library.refresh()
                readingHistory.pruneMissing()
            }
        }
        .onOpenURL { url in
            importAndOpen(url)
        }
        .fileImporter(
            isPresented: $presentsImporter,
            allowedContentTypes: [MarkdownFileDocument.markdownContentType, .plainText]
        ) { result in
            switch result {
            case let .success(url):
                importAndOpen(url)
            case let .failure(error):
                presentedError = PresentedLibraryError(message: error.localizedDescription)
            }
        }
        .fullScreenCover(
            item: $editorPresentation,
            onDismiss: {
                Task { await library.refresh() }
            }
        ) { presentation in
            DocumentEditorView(
                store: presentation.store,
                startEditing: presentation.startEditing
            )
            .id(presentation.id)
        }
        .sheet(isPresented: $showsSettings) {
            NavigationStack {
                MossmarkSettingsView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("common.done") { showsSettings = false }
                        }
                    }
            }
        }
        .alert(
            Text("library.rename.title"),
            isPresented: renameAlertPresented
        ) {
            TextField("library.rename.title", text: $renameText)
            Button("common.cancel", role: .cancel) {}
            Button("common.done") {
                performRename()
            }
        }
        .confirmationDialog(
            deleteConfirmationTitle,
            isPresented: deleteConfirmationPresented,
            titleVisibility: .visible
        ) {
            if let document = deleteTarget {
                Button("library.delete", role: .destructive) {
                    deleteTarget = nil
                    performDelete(document)
                }
            }
            Button("common.cancel", role: .cancel) {
                deleteTarget = nil
            }
        }
        .alert(item: $presentedError) { error in
            Alert(
                title: Text("error.title"),
                message: Text(error.message),
                dismissButton: .default(Text("common.ok"))
            )
        }
    }

    @ViewBuilder
    private var libraryContent: some View {
        VStack(spacing: 0) {
            libraryActionBar
            if library.documents.isEmpty, searchText.isEmpty {
                ContentUnavailableView {
                    Label("library.empty.title", systemImage: "doc.text")
                } description: {
                    Text("library.empty.hint")
                }
            } else {
                List {
                    if !recentDocuments.isEmpty {
                        Section("library.recent") {
                            ForEach(recentDocuments) { document in
                                documentRow(document, identifierPrefix: "mossmark.recent-row")
                            }
                        }
                    }
                    Section("library.all") {
                        ForEach(filteredDocuments) { document in
                            documentRow(document, identifierPrefix: "mossmark.document-row")
                        }
                    }
                }
                .accessibilityIdentifier("mossmark.library-list")
            }
        }
    }

    private var libraryActionBar: some View {
        HStack(spacing: 12) {
            Button {
                presentsImporter = true
            } label: {
                Label("library.import", systemImage: "tray.and.arrow.down")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .accessibilityIdentifier("mossmark.import-document")

            Button {
                createAndOpen()
            } label: {
                Label("library.new", systemImage: "doc.badge.plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityIdentifier("mossmark.new-document")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func documentRow(
        _ document: LibraryDocument,
        identifierPrefix: String
    ) -> some View {
        Button {
            open(document.url, startEditing: false)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "doc.text")
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(document.name)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        if let relativeDirectory = document.relativeDirectory {
                            Text(relativeDirectory)
                        }
                        Text(
                            document.modifiedAt,
                            format: .dateTime.month().day().hour().minute()
                        )
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
            }
        }
        .accessibilityIdentifier("\(identifierPrefix).\(document.name)")
        .swipeActions(edge: .trailing) {
            // This button only asks for confirmation. Giving the preliminary
            // swipe action a destructive role makes SwiftUI animate the row
            // away immediately, then insert it again while the confirmation
            // dialog is visible because the file has not been deleted yet.
            Button {
                deleteTarget = document
            } label: {
                Label("library.delete", systemImage: "trash")
            }
            .tint(.red)
            Button {
                renameText = document.url.deletingPathExtension().lastPathComponent
                renameTarget = document
            } label: {
                Label("library.rename", systemImage: "pencil")
            }
            .tint(.orange)
        }
        .contextMenu {
            Button {
                renameText = document.url.deletingPathExtension().lastPathComponent
                renameTarget = document
            } label: {
                Label("library.rename", systemImage: "pencil")
            }
            Button {
                performDuplicate(document)
            } label: {
                Label("library.duplicate", systemImage: "plus.square.on.square")
            }
            Divider()
            Button(role: .destructive) {
                deleteTarget = document
            } label: {
                Label("library.delete", systemImage: "trash")
            }
        }
    }

    // MARK: - Filtering

    private var filteredDocuments: [LibraryDocument] {
        library.documents.filter(matchesSearch)
    }

    private var recentDocuments: [LibraryDocument] {
        let byURL = Dictionary(
            library.documents.map { ($0.url.standardizedFileURL, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return readingHistory.recentDocumentURLs()
            .compactMap { byURL[$0.standardizedFileURL] }
            .filter(matchesSearch)
    }

    private func matchesSearch(_ document: LibraryDocument) -> Bool {
        searchText.isEmpty || document.name.localizedCaseInsensitiveContains(searchText)
    }

    private var renameAlertPresented: Binding<Bool> {
        Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )
    }

    private var deleteConfirmationPresented: Binding<Bool> {
        Binding(
            get: { deleteTarget != nil },
            set: { if !$0 { deleteTarget = nil } }
        )
    }

    private var deleteConfirmationTitle: String {
        guard let deleteTarget else { return "" }
        return String.localizedStringWithFormat(
            String(localized: "library.delete.confirm %@"),
            deleteTarget.name
        )
    }

    // MARK: - Actions

    private func createAndOpen() {
        Task {
            do {
                let url = try await library.createDocument()
                open(url, startEditing: true)
            } catch {
                presentedError = PresentedLibraryError(message: error.localizedDescription)
            }
        }
    }

    private func importAndOpen(_ sourceURL: URL) {
        Task {
            do {
                let url = try await library.importDocument(from: sourceURL)
                open(url, startEditing: false)
            } catch {
                presentedError = PresentedLibraryError(message: error.localizedDescription)
            }
        }
    }

    private func open(_ url: URL, startEditing: Bool) {
        do {
            let store = try OpenedDocumentStore(fileURL: url)
            readingHistory.record(url)
            editorPresentation = EditorPresentation(store: store, startEditing: startEditing)
        } catch {
            presentedError = PresentedLibraryError(message: error.localizedDescription)
        }
    }

    private func performRename() {
        guard let target = renameTarget else { return }
        let newName = renameText
        renameTarget = nil
        Task {
            do {
                let destination = try await library.rename(target, to: newName)
                readingHistory.move(from: target.url, to: destination)
            } catch {
                presentedError = PresentedLibraryError(message: error.localizedDescription)
            }
        }
    }

    private func performDuplicate(_ document: LibraryDocument) {
        Task {
            do {
                try await library.duplicate(document)
            } catch {
                presentedError = PresentedLibraryError(message: error.localizedDescription)
            }
        }
    }

    private func performDelete(_ document: LibraryDocument) {
        Task {
            do {
                try await library.delete(document)
                readingHistory.remove(document.url)
            } catch {
                presentedError = PresentedLibraryError(message: error.localizedDescription)
            }
        }
    }
}

/// Full-screen editor hosted by the library. The store replaces the
/// DocumentGroup autosave; leaving the editor or backgrounding the app
/// flushes pending changes.
struct DocumentEditorView: View {
    private struct EditorSession: Identifiable {
        let id = UUID()
        let store: OpenedDocumentStore
        let startEditing: Bool
    }

    @State private var session: EditorSession
    @State private var presentedError: PresentedLibraryError?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var readingHistory: ReadingHistory

    init(store: OpenedDocumentStore, startEditing: Bool) {
        _session = State(
            initialValue: EditorSession(store: store, startEditing: startEditing)
        )
    }

    var body: some View {
        NavigationStack {
            DocumentEditorContent(
                store: session.store,
                startEditing: session.startEditing,
                openDocument: switchDocument
            )
            .id(session.id)
            .navigationTitle(
                session.store.fileURL.deletingPathExtension().lastPathComponent
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        if session.store.flush() {
                            dismiss()
                        }
                    } label: {
                        Label("library.title", systemImage: "chevron.left")
                    }
                    .accessibilityIdentifier("mossmark.library-back-button")
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                session.store.flush()
            }
        }
        .onDisappear {
            session.store.flush()
        }
        .alert(item: $presentedError) { error in
            Alert(
                title: Text("error.title"),
                message: Text(error.message),
                dismissButton: .default(Text("common.ok"))
            )
        }
    }

    /// Replaces only the document session inside the existing full-screen
    /// editor. Keeping the outer presentation alive removes the UIKit race
    /// caused by dismissing and immediately re-presenting a fullScreenCover.
    private func switchDocument(_ url: URL) {
        guard url.standardizedFileURL != session.store.fileURL.standardizedFileURL else {
            return
        }
        guard session.store.flush() else { return }
        do {
            let store = try OpenedDocumentStore(fileURL: url)
            readingHistory.record(url)
            session = EditorSession(store: store, startEditing: false)
        } catch {
            presentedError = PresentedLibraryError(message: error.localizedDescription)
        }
    }
}

private struct DocumentEditorContent: View {
    @ObservedObject var store: OpenedDocumentStore
    let startEditing: Bool
    let openDocument: (URL) -> Void

    var body: some View {
        MarkdownDocumentView(
            document: $store.document,
            fileURL: store.fileURL,
            isEditable: store.isEditable,
            initialMode: startEditing ? .wysiwym : .preview,
            onOpenDocument: openDocument
        )
        .alert(
            "error.title",
            isPresented: saveErrorPresented,
            presenting: store.saveError
        ) { _ in
            Button("common.ok") { store.saveError = nil }
        } message: { message in
            Text(message)
        }
    }

    private var saveErrorPresented: Binding<Bool> {
        Binding(
            get: { store.saveError != nil },
            set: { if !$0 { store.saveError = nil } }
        )
    }
}
