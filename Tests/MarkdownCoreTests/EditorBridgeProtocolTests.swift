import MarkdownCore
import Testing

@Test("Editor modes present reading first")
func editorModesPresentReadingFirst() {
    #expect(MarkdownEditorMode.allCases == [.preview, .wysiwym, .source])
    #expect(MarkdownEditorMode.preview.localizationKey == "mode.reading")
}

@Test("Editor bridge exposes outline position messages")
func editorBridgeExposesOutlineMessages() {
    #expect(EditorBridgeMessageType.outline.rawValue == "outline")
}
