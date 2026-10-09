import Testing

@testable import MarkdownCore

@Test("Outline parser recognizes ATX and setext headings but ignores fences")
func parsesOutline() {
    let source = """
    # **标题**

    ## [链接标题](https://example.com)

    Setext
    ------

    ```markdown
    # 代码中的标题
    ```
    """
    let items = MarkdownOutlineParser.parse(source)

    #expect(items.map(\.level) == [1, 2, 2])
    #expect(items.map(\.title) == ["标题", "链接标题", "Setext"])
    #expect(items.map(\.id) == [0, 1, 2])
}

@Test("Outline parser does not treat YAML front matter as a setext heading")
func ignoresFrontMatter() {
    let source = """
    ---
    title: Sample
    author: Local-first
    ---

    # Visible title
    """

    let items = MarkdownOutlineParser.parse(source)

    #expect(items.map(\.title) == ["Visible title"])
    #expect(items.map(\.line) == [6])
}

@Test("Outline parser ignores comments, nested headings, and shorter fence closers")
func keepsOutlineOrdinalsAlignedWithRenderedPreview() {
    let source = """
    # A

    <!--
    # Hidden in comment
    -->

    > # Quoted

    ````markdown
    # Hidden in four-backtick fence
    ```
    ## Still inside fence
    ````

    B
    ---
    """

    let items = MarkdownOutlineParser.parse(source)

    #expect(items.map(\.title) == ["A", "B"])
    #expect(items.map(\.id) == [0, 1])
    #expect(items.map(\.line) == [1, 15])
}
