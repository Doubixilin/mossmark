import Foundation
import Testing
import ZIPFoundation

@testable import MarkdownCore

private let exportFixture = """
---
title: 示例文档
---

# 一级标题

正文包含 **粗体**、*斜体*、[链接](https://example.com) 和脚注[^note]，
这一行在 Markdown 中是软换行，导出 Word 后应当自然重排而不是强制换行。

- [x] 完成事项
1. 第一项

| 名称 | 值 |
| --- | --- |
| A | 1 |

![图片](images/example.png)

```swift
print("hello")
```

```mermaid
flowchart LR
    Markdown --> DOCX
```

[^note]: 脚注正文
"""

@Test("Markdown export parser produces structured editable blocks")
func parsesExportDocument() {
    let document = MarkdownExportParser.parse(exportFixture)

    #expect(document.title == "示例文档")
    #expect(document.blocks.contains { $0.kind == .heading && $0.level == 1 })
    #expect(document.blocks.contains { $0.kind == .table && $0.tableRows.count == 2 })
    #expect(document.blocks.contains { $0.kind == .listItem && $0.checked == true })
    #expect(document.blocks.contains { $0.kind == .listItem && $0.ordered })
    #expect(document.blocks.contains { $0.kind == .codeBlock && $0.language == "swift" })
    #expect(document.blocks.contains { $0.kind == .diagram && $0.language == "mermaid" })
    #expect(document.footnotes["note"]?.map(\.text).joined() == "脚注正文")
    #expect(MarkdownExportParser.imageSources(in: document) == ["images/example.png"])

    let paragraph = document.blocks.first { $0.kind == .paragraph }
    #expect(paragraph?.runs.contains { $0.bold && $0.text == "粗体" } == true)
    #expect(paragraph?.runs.contains { $0.italic && $0.text == "斜体" } == true)
    #expect(paragraph?.runs.contains { $0.link == "https://example.com" } == true)
}

@Test("DOCX paragraphs reflow Markdown soft breaks and preserve hard breaks")
func reflowsSoftBreaksForDOCX() {
    let markdown = "第一行\n第二行" + "  \n第三行\n第四行\\\n第五行"
    let document = MarkdownExportParser.parse(markdown)
    let paragraph = document.blocks.first { $0.kind == .paragraph }

    #expect(paragraph?.runs.map(\.text).joined() == "第一行 第二行\n第三行 第四行\n第五行")
}

@Test("DOCX writer emits native Word structures and relationships")
func writesStructuredDOCX() throws {
    let document = MarkdownExportParser.parse(exportFixture)
    let image = MarkdownExportImage(
        data: Data([0x89, 0x50, 0x4E, 0x47]),
        fileExtension: "png",
        widthPixels: 640,
        heightPixels: 480
    )
    let data = try MarkdownDOCXWriter.makeDocument(
        from: document,
        images: [
            "images/example.png": image,
            "markdown-generated://diagram/0": image,
        ],
        createdAt: Date(timeIntervalSince1970: 0)
    )
    let archive = try Archive(data: data, accessMode: .read)
    try assertValidXMLParts(in: archive)

    #expect(archive["word/document.xml"] != nil)
    #expect(archive["word/styles.xml"] != nil)
    #expect(archive["word/numbering.xml"] != nil)
    #expect(archive["word/footnotes.xml"] != nil)
    #expect(archive["word/media/image1.png"] != nil)
    #expect(archive["word/media/image2.png"] != nil)

    let documentXML = try string(path: "word/document.xml", from: archive)
    let stylesXML = try string(path: "word/styles.xml", from: archive)
    let relationshipsXML = try string(path: "word/_rels/document.xml.rels", from: archive)
    #expect(documentXML.contains("w:pStyle w:val=\"Heading1\""))
    #expect(documentXML.contains("<w:tbl>"))
    #expect(documentXML.contains("<w:numPr>"))
    #expect(documentXML.contains("<w:footnoteReference"))
    #expect(documentXML.contains("<w:drawing>"))
    #expect(documentXML.components(separatedBy: "<w:drawing>").count - 1 == 2)
    #expect(documentXML.contains("<w:rFonts w:ascii=\"Arial Unicode MS\" w:hAnsi=\"Arial Unicode MS\" w:eastAsia=\"Arial Unicode MS\""))
    #expect(stylesXML.contains("w:eastAsia=\"Arial Unicode MS\""))
    #expect(relationshipsXML.contains("relationships/hyperlink"))
    #expect(relationshipsXML.contains("relationships/image"))
}

@Test("DOCX writer handles a long mixed document")
func writesLongMixedDOCX() throws {
    let longMarkdown = (1...600).map { index in
        """
        ## Section \(index)

        Paragraph \(index) contains a long unbroken token `mossmark-\(String(repeating: "x", count: 180))` and Chinese text 长文档分页验证。

        | Column | Value |
        | --- | --- |
        | \(index) | \(index * 2) |
        """
    }.joined(separator: "\n\n")
    let document = MarkdownExportParser.parse(longMarkdown, fallbackTitle: "Long document")
    let data = try MarkdownDOCXWriter.makeDocument(
        from: document,
        createdAt: Date(timeIntervalSince1970: 0)
    )
    let archive = try Archive(data: data, accessMode: .read)
    try assertValidXMLParts(in: archive)
    let documentXML = try string(path: "word/document.xml", from: archive)

        #expect(data.count > 10_000)
    #expect(documentXML.contains("Section 600"))
    #expect(documentXML.components(separatedBy: "<w:tbl>").count - 1 == 600)
}

@Test("DOCX writer strips illegal XML control characters from text")
func stripsIllegalXMLControlCharacters() throws {
    let markdown = "含控制字符\u{0B}和\u{08}的段落"
    let document = MarkdownExportParser.parse(markdown)
    let data = try MarkdownDOCXWriter.makeDocument(
        from: document,
        createdAt: Date(timeIntervalSince1970: 0)
    )
    let archive = try Archive(data: data, accessMode: .read)
    try assertValidXMLParts(in: archive)

    let documentXML = try string(path: "word/document.xml", from: archive)
    #expect(!documentXML.contains("\u{0B}"))
    #expect(!documentXML.contains("\u{08}"))
    #expect(documentXML.contains("含控制字符和的段落"))
}

@Test("DOCX writer restarts numbering for each independent ordered list")
func restartsOrderedListNumbering() throws {
    let markdown = """
    1. 第一组甲
    2. 第一组乙

    中间段落

    1. 第二组甲
    2. 第二组乙
    """
    let document = MarkdownExportParser.parse(markdown)
    let data = try MarkdownDOCXWriter.makeDocument(
        from: document,
        createdAt: Date(timeIntervalSince1970: 0)
    )
    let archive = try Archive(data: data, accessMode: .read)
    try assertValidXMLParts(in: archive)

    let documentXML = try string(path: "word/document.xml", from: archive)
    let numberingXML = try string(path: "word/numbering.xml", from: archive)
    #expect(documentXML.contains("<w:numId w:val=\"2\"/>"))
    #expect(documentXML.contains("<w:numId w:val=\"3\"/>"))
    #expect(numberingXML.contains("<w:num w:numId=\"2\">"))
    #expect(numberingXML.contains("<w:num w:numId=\"3\">"))
    #expect(!numberingXML.contains("startOverride"))
}

@Test("DOCX writer preserves ordered list start numbers")
func preservesOrderedListStartNumber() throws {
    let document = MarkdownExportParser.parse("3. 第三项\n5. 第五项")
    #expect(document.blocks.first?.listStart == 3)

    let data = try MarkdownDOCXWriter.makeDocument(
        from: document,
        createdAt: Date(timeIntervalSince1970: 0)
    )
    let archive = try Archive(data: data, accessMode: .read)
    try assertValidXMLParts(in: archive)

    let numberingXML = try string(path: "word/numbering.xml", from: archive)
    #expect(numberingXML.contains("<w:startOverride w:val=\"3\"/>"))
}

@Test("DOCX writer replaces unsupported image formats with a placeholder")
func degradesUnsupportedImagesToPlaceholder() throws {
    let document = MarkdownExportParser.parse("![示意图](images/figure.webp)")
    let webp = MarkdownExportImage(
        data: Data([0x52, 0x49, 0x46, 0x46]),
        fileExtension: "webp",
        widthPixels: 10,
        heightPixels: 10
    )
    let data = try MarkdownDOCXWriter.makeDocument(
        from: document,
        images: ["images/figure.webp": webp],
        createdAt: Date(timeIntervalSince1970: 0)
    )
    let archive = try Archive(data: data, accessMode: .read)
    try assertValidXMLParts(in: archive)

    let documentXML = try string(path: "word/document.xml", from: archive)
    #expect(!documentXML.contains("<w:drawing>"))
    #expect(documentXML.contains("示意图"))
    #expect(archive["word/media/image1.webp"] == nil)
    #expect(archive["word/media/image1.png"] == nil)
}

@Test("DOCX writer numbers footnotes referenced inside table cells")
func numbersFootnotesInsideTables() throws {
    let markdown = """
    | 名称 | 说明 |
    | --- | --- |
    | A | 带脚注[^cell] |

    [^cell]: 表格脚注正文
    """
    let document = MarkdownExportParser.parse(markdown)
    let data = try MarkdownDOCXWriter.makeDocument(
        from: document,
        createdAt: Date(timeIntervalSince1970: 0)
    )
    let archive = try Archive(data: data, accessMode: .read)
    try assertValidXMLParts(in: archive)

    let documentXML = try string(path: "word/document.xml", from: archive)
    let footnotesXML = try string(path: "word/footnotes.xml", from: archive)
    #expect(documentXML.contains("<w:footnoteReference w:id=\"1\"/>"))
    #expect(footnotesXML.contains("表格脚注正文"))
}

@Test("DOCX writer degrades relationship-backed footnote content to visible text")
func degradesRichFootnotesToRelationshipFreeText() throws {
    let markdown = """
    正文脚注[^rich]

    [^rich]: 查看[站点](https://footnote.example.com)和![图示](images/footnote.png)
    """
    let document = MarkdownExportParser.parse(markdown)
    let image = MarkdownExportImage(
        data: Data([0x89, 0x50, 0x4E, 0x47]),
        fileExtension: "png",
        widthPixels: 32,
        heightPixels: 32
    )
    let data = try MarkdownDOCXWriter.makeDocument(
        from: document,
        images: ["images/footnote.png": image],
        createdAt: Date(timeIntervalSince1970: 0)
    )
    let archive = try Archive(data: data, accessMode: .read)
    try assertValidXMLParts(in: archive)

    let footnotesXML = try string(path: "word/footnotes.xml", from: archive)
    let relationshipsXML = try string(path: "word/_rels/document.xml.rels", from: archive)
    #expect(footnotesXML.contains("站点"))
    #expect(footnotesXML.contains("https://footnote.example.com"))
    #expect(footnotesXML.contains("图示"))
    #expect(!footnotesXML.contains("<w:hyperlink"))
    #expect(!footnotesXML.contains("r:id="))
    #expect(!footnotesXML.contains("r:embed="))
    #expect(!footnotesXML.contains("<w:drawing>"))
    #expect(!relationshipsXML.contains("https://footnote.example.com"))
    #expect(!relationshipsXML.contains("relationships/image"))
    #expect(archive["word/_rels/footnotes.xml.rels"] == nil)
    #expect(archive["word/media/image1.png"] == nil)
}

@Test("Footnote extraction skips fenced code blocks and keeps their content")
func footnoteDefinitionsInsideFencesStayInExportedContent() throws {
    let markdown = """
    正文引用真实脚注[^real]。

    ```markdown
    脚注写法示例：
    [^sample]: 这只是围栏内的示例文本
    ```

    ~~~text
    [^tilde]: 波浪围栏内的示例
    ~~~

    [^real]: 真实脚注正文
    """
    let document = MarkdownExportParser.parse(markdown)

    #expect(document.footnotes["real"]?.map(\.text).joined() == "真实脚注正文")
    #expect(document.footnotes["sample"] == nil)
    #expect(document.footnotes["tilde"] == nil)

    let fenceBodies = document.blocks
        .filter { $0.kind == .codeBlock }
        .map { $0.runs.map(\.text).joined() }
    #expect(fenceBodies.contains { $0.contains("[^sample]: 这只是围栏内的示例文本") })
    #expect(fenceBodies.contains { $0.contains("[^tilde]: 波浪围栏内的示例") })

    // The fenced example text must also survive the DOCX round trip, and the
    // real footnote outside the fences must still be exported as a footnote.
    let data = try MarkdownDOCXWriter.makeDocument(
        from: document,
        createdAt: Date(timeIntervalSince1970: 0)
    )
    let archive = try Archive(data: data, accessMode: .read)
    try assertValidXMLParts(in: archive)

    let documentXML = try string(path: "word/document.xml", from: archive)
    let footnotesXML = try string(path: "word/footnotes.xml", from: archive)
    #expect(documentXML.contains("[^sample]: 这只是围栏内的示例文本"))
    #expect(documentXML.contains("[^tilde]: 波浪围栏内的示例"))
    #expect(documentXML.contains("<w:footnoteReference"))
    #expect(footnotesXML.contains("真实脚注正文"))
    #expect(!footnotesXML.contains("示例文本"))
}

@Test("Inline math delimiters do not swallow prices like $5 and $10")
func dollarSignsAroundPricesAreNotMath() {
    let document = MarkdownExportParser.parse("价格是 $5 和 $10 之间")
    let paragraph = document.blocks.first { $0.kind == .paragraph }
    #expect(paragraph?.runs.contains { $0.math } == false)
    #expect(paragraph?.runs.map(\.text).joined() == "价格是 $5 和 $10 之间")

    let math = MarkdownExportParser.parse("公式 $x+y$ 结束")
    let mathParagraph = math.blocks.first { $0.kind == .paragraph }
    #expect(mathParagraph?.runs.contains { $0.math && $0.text == "x+y" } == true)
}

private func assertValidXMLParts(in archive: Archive, sourceLocation: SourceLocation = #_sourceLocation) throws {
    for entry in archive where entry.path.hasSuffix(".xml") || entry.path.hasSuffix(".rels") {
        var data = Data()
        _ = try archive.extract(entry) { data.append($0) }
        #expect(
            XMLParser(data: data).parse(),
            "\(entry.path) is not well-formed XML",
            sourceLocation: sourceLocation
        )
    }
}

private func string(path: String, from archive: Archive) throws -> String {
    guard let entry = archive[path] else {
        throw CocoaError(.fileReadNoSuchFile)
    }
    var data = Data()
    _ = try archive.extract(entry) { data.append($0) }
    guard let value = String(data: data, encoding: .utf8) else {
        throw CocoaError(.fileReadInapplicableStringEncoding)
    }
    return value
}
