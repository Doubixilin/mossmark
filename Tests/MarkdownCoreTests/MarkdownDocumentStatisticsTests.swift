import Testing

@testable import MarkdownCore

@Test("Document statistics count rendered text instead of Markdown punctuation")
func calculatesRenderedDocumentStatistics() {
    let statistics = MarkdownDocumentStatistics.calculate(
        """
        # 标题

        Hello **Mossmark** 2026.

        | 功能 | 状态 |
        | --- | --- |
        | 阅读 | good |
        """
    )

    #expect(statistics.wordCount == 12)
    #expect(statistics.characterCount == 30)
    #expect(statistics.estimatedReadingMinutes == 1)
}

@Test("Code blocks and raw HTML are excluded from document statistics")
func excludesCodeBlocksFromStatistics() {
    let statistics = MarkdownDocumentStatistics.calculate(
        """
        Hello world.

        ```swift
        let lots = "of code words here that should not count"
        ```
        """
    )

    #expect(statistics.wordCount == 2)
}

@Test("Empty documents have no estimated reading time")
func emptyDocumentStatistics() {
    #expect(MarkdownDocumentStatistics.calculate("   \n\n") == .empty)
}
