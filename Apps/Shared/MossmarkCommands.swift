import MarkdownCore
import SwiftUI

/// Handles for the document window that currently has focus, surfaced to the
/// menu bar (macOS) and the keyboard shortcut panel (iPad) via focused values.
@MainActor
struct MossmarkFocusedDocument {
    let controller: MarkdownEditorController
    let isEditable: Bool
    let presentLinkPrompt: () -> Void
    let printDocument: () -> Void
}

private struct MossmarkFocusedDocumentKey: FocusedValueKey {
    typealias Value = MossmarkFocusedDocument
}

extension FocusedValues {
    var mossmarkDocument: MossmarkFocusedDocument? {
        get { self[MossmarkFocusedDocumentKey.self] }
        set { self[MossmarkFocusedDocumentKey.self] = newValue }
    }
}

struct MossmarkDocumentCommands: Commands {
    @FocusedValue(\.mossmarkDocument) private var document: MossmarkFocusedDocument?
    @AppStorage("mossmark.typography-preset") private var typographyPresetRaw =
        MarkdownTypographyPreset.quiet.rawValue

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Button("mode.reading") {
                document?.controller.setMode(.preview)
            }
            .keyboardShortcut("1", modifiers: .command)
            .disabled(document == nil)
            Button("mode.edit") {
                document?.controller.setMode(.wysiwym)
            }
            .keyboardShortcut("2", modifiers: .command)
            .disabled(document == nil)
            Button("mode.source") {
                document?.controller.setMode(.source)
            }
            .keyboardShortcut("3", modifiers: .command)
            .disabled(document == nil)

            Divider()

            Toggle("专注模式（仅当前段落保持亮度）", isOn: focusModeBinding)
                .disabled(document == nil)
            Toggle("打字机模式（输入行始终居中）", isOn: typewriterModeBinding)
                .disabled(document == nil)
            Button("沉浸阅读") {
                document?.controller.toggleImmersiveReading()
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(document?.controller.mode != .preview)

            Divider()

            Menu("typography.title") {
                Picker("typography.title", selection: $typographyPresetRaw) {
                    ForEach(MarkdownTypographyPreset.allCases, id: \.self) { preset in
                        Text(LocalizedStringKey(preset.localizationKey)).tag(preset.rawValue)
                    }
                }
            }
        }

        CommandMenu("格式") {
            Button("粗体") {
                document?.controller.applyFormatting(.bold)
            }
            .keyboardShortcut("b", modifiers: .command)
            .disabled(!canFormat)
            Button("斜体") {
                document?.controller.applyFormatting(.italic)
            }
            .keyboardShortcut("i", modifiers: .command)
            .disabled(!canFormat)
            Button("删除线") {
                document?.controller.applyFormatting(.strikethrough)
            }
            .keyboardShortcut("x", modifiers: [.command, .shift])
            .disabled(!canFormat)

            Divider()

            ForEach(1...3, id: \.self) { level in
                Button(
                    String.localizedStringWithFormat(
                        String(localized: "标题 %lld"),
                        level
                    )
                ) {
                    document?.controller.applyFormatting(.heading, numberValue: level)
                }
                .keyboardShortcut(KeyEquivalent(Character("\(level)")), modifiers: [.command, .option])
                .disabled(!canFormat)
            }

            Divider()

            Button("插入链接") {
                document?.presentLinkPrompt()
            }
            .keyboardShortcut("k", modifiers: .command)
            .disabled(!canFormat)
        }

        #if os(macOS)
        CommandGroup(replacing: .printItem) {
            Button("print.menu-item") {
                document?.printDocument()
            }
            .keyboardShortcut("p", modifiers: .command)
            .disabled(document == nil || document?.controller.isReady != true)
        }
        #endif
    }

    private var canFormat: Bool {
        guard let document, document.isEditable else { return false }
        return document.controller.isReady && document.controller.mode != .preview
    }

    private var focusModeBinding: Binding<Bool> {
        Binding(
            get: { document?.controller.focusMode ?? false },
            set: { document?.controller.setFocusMode($0) }
        )
    }

    private var typewriterModeBinding: Binding<Bool> {
        Binding(
            get: { document?.controller.typewriterMode ?? false },
            set: { document?.controller.setTypewriterMode($0) }
        )
    }
}
