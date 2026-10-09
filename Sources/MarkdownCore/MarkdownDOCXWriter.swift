import Foundation
import ZIPFoundation

public enum MarkdownDOCXWriter {
    public enum WriterError: Error, Equatable {
        case couldNotCreateArchive
    }

    public static func makeDocument(
        from document: MarkdownExportDocument,
        images: [String: MarkdownExportImage] = [:],
        createdAt: Date = Date()
    ) throws -> Data {
        let builder = Builder(document: document, images: images)
        let documentXML = builder.documentXML()
        let footnotesXML = builder.footnotesXML()

        let archive = try Archive(accessMode: .create)
        try add(builder.contentTypesXML(includeFootnotes: footnotesXML != nil), at: "[Content_Types].xml", to: archive)
        try add(rootRelationshipsXML, at: "_rels/.rels", to: archive)
        try add(documentXML, at: "word/document.xml", to: archive)
        try add(builder.documentRelationshipsXML, at: "word/_rels/document.xml.rels", to: archive)
        try add(stylesXML, at: "word/styles.xml", to: archive)
        try add(builder.numberingXML(), at: "word/numbering.xml", to: archive)
        try add(settingsXML, at: "word/settings.xml", to: archive)
        try add(corePropertiesXML(title: document.title, createdAt: createdAt), at: "docProps/core.xml", to: archive)
        try add(appPropertiesXML, at: "docProps/app.xml", to: archive)
        if let footnotesXML {
            try add(footnotesXML, at: "word/footnotes.xml", to: archive)
        }
        for part in builder.mediaParts {
            try add(part.data, at: "word/media/\(part.name)", to: archive)
        }

        guard let data = archive.data else {
            throw WriterError.couldNotCreateArchive
        }
        return data
    }

    private static func add(_ string: String, at path: String, to archive: Archive) throws {
        try add(Data(string.utf8), at: path, to: archive)
    }

    private static func add(_ data: Data, at path: String, to archive: Archive) throws {
        try archive.addEntry(
            with: path,
            type: .file,
            uncompressedSize: Int64(data.count),
            compressionMethod: .deflate
        ) { position, size in
            let start = Int(position)
            let end = min(data.count, start + size)
            guard start < end else { return Data() }
            return data.subdata(in: start..<end)
        }
    }
}

private extension MarkdownDOCXWriter {
    final class Builder {
        struct Relationship {
            var id: String
            var type: String
            var target: String
            var external = false
        }

        struct MediaPart {
            var name: String
            var data: Data
            var contentType: String
        }

        let document: MarkdownExportDocument
        let images: [String: MarkdownExportImage]
        var relationships: [Relationship] = [
            .init(id: "rId1", type: relationshipNamespace + "/styles", target: "styles.xml"),
            .init(id: "rId2", type: relationshipNamespace + "/numbering", target: "numbering.xml"),
            .init(id: "rId3", type: relationshipNamespace + "/settings", target: "settings.xml"),
        ]
        var mediaParts: [MediaPart] = []
        var mediaBySource: [String: (relationshipID: String, name: String, image: MarkdownExportImage)] = [:]
        var hyperlinkRelationshipByTarget: [String: String] = [:]
        var footnoteNumbers: [String: Int] = [:]
        var orderedListNumberingByBlock: [Int: Int] = [:]
        var orderedListNumberings: [(numberingID: Int, start: Int)] = []
        var nextRelationshipNumber = 4
        var nextDrawingNumber = 1
        var nextBookmarkNumber = 1
        var nextDiagramNumber = 0

        init(document: MarkdownExportDocument, images: [String: MarkdownExportImage]) {
            self.document = document
            self.images = images
            assignFootnoteNumbers()
            assignOrderedListNumberings()
            if !footnoteNumbers.isEmpty {
                relationships.append(.init(
                    id: nextRelationshipID(),
                    type: relationshipNamespace + "/footnotes",
                    target: "footnotes.xml"
                ))
            }
        }

        // Each ordered list separated from the previous one by a non-ordered-item
        // block gets its own numbering instance so numbering restarts per list.
        private func assignOrderedListNumberings() {
            var nextNumberingID = 2
            var continuesList = false
            var currentNumberingID = 0
            for (index, block) in document.blocks.enumerated() {
                if block.kind == .listItem, block.ordered {
                    if !continuesList {
                        currentNumberingID = nextNumberingID
                        nextNumberingID += 1
                        orderedListNumberings.append((currentNumberingID, max(1, block.listStart)))
                    }
                    orderedListNumberingByBlock[index] = currentNumberingID
                    continuesList = true
                } else {
                    continuesList = false
                }
            }
        }

        func documentXML() -> String {
            var body = ""
            var headingOrdinal = 0
            for (blockIndex, block) in document.blocks.enumerated() {
                switch block.kind {
                case .paragraph:
                    body += paragraph(runs: block.runs)
                case .heading:
                    headingOrdinal += 1
                    let bookmark = "heading_\(headingOrdinal)"
                    body += paragraph(
                        runs: block.runs,
                        style: "Heading\(max(1, min(6, block.level)))",
                        bookmark: bookmark
                    )
                case .blockquote:
                    body += paragraph(runs: block.runs, style: "BlockQuote")
                case .codeBlock:
                    body += paragraph(runs: block.runs, style: "CodeBlock")
                case .diagram:
                    let source = "markdown-generated://diagram/\(nextDiagramNumber)"
                    nextDiagramNumber += 1
                    if images[source] != nil {
                        body += paragraph(runs: [
                            .init(
                                text: String(localized: "export.mermaid-diagram"),
                                imageSource: source
                            ),
                        ])
                    } else {
                        body += paragraph(
                            runs: [.init(text: "Mermaid\n" + block.runs.map(\.text).joined(), code: true)],
                            style: "CodeBlock"
                        )
                    }
                case .mathBlock:
                    body += paragraph(runs: block.runs, style: "MathBlock")
                case .rawHTML:
                    body += paragraph(runs: block.runs, style: "CodeBlock")
                case .listItem:
                    var runs = block.runs
                    if let checked = block.checked {
                        runs.insert(.init(text: checked ? "☒ " : "☐ "), at: 0)
                    }
                    let numberingID = block.ordered ? orderedListNumberingByBlock[blockIndex] ?? 2 : 1
                    body += paragraph(
                        runs: runs,
                        numbering: (numberingID, max(0, min(8, block.level)))
                    )
                case .table:
                    body += table(block.tableRows)
                case .horizontalRule:
                    body += "<w:p><w:pPr><w:pBdr><w:bottom w:val=\"single\" w:sz=\"8\" w:space=\"1\" w:color=\"BFBFBF\"/></w:pBdr></w:pPr></w:p>"
                case .tableOfContents:
                    body += tableOfContents()
                }
            }

            return xmlHeader + """
            <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"
              xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"
              xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"
              xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"
              xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">
              <w:body>\(body)<w:sectPr><w:pgSz w:w="11906" w:h="16838"/><w:pgMar w:top="1021" w:right="964" w:bottom="1134" w:left="964" w:header="425" w:footer="425" w:gutter="0"/></w:sectPr></w:body>
            </w:document>
            """
        }

        func contentTypesXML(includeFootnotes: Bool) -> String {
            var defaults: [String: String] = [
                "rels": "application/vnd.openxmlformats-package.relationships+xml",
                "xml": "application/xml",
            ]
            for part in mediaParts {
                defaults[String(part.name.split(separator: ".").last ?? "bin")] = part.contentType
            }
            let defaultsXML = defaults.keys.sorted().map {
                "<Default Extension=\"\(xml($0))\" ContentType=\"\(xml(defaults[$0]!))\"/>"
            }.joined()
            let footnotesOverride = includeFootnotes
                ? "<Override PartName=\"/word/footnotes.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.footnotes+xml\"/>"
                : ""
            return xmlHeader + """
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
              \(defaultsXML)
              <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
              <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>
              <Override PartName="/word/numbering.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml"/>
              <Override PartName="/word/settings.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.settings+xml"/>
              \(footnotesOverride)
              <Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>
              <Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>
            </Types>
            """
        }

        var documentRelationshipsXML: String {
            let values = relationships.map { relationship in
                let targetMode = relationship.external ? " TargetMode=\"External\"" : ""
                return "<Relationship Id=\"\(relationship.id)\" Type=\"\(xml(relationship.type))\" Target=\"\(xml(relationship.target))\"\(targetMode)/>"
            }.joined()
            return xmlHeader + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">\(values)</Relationships>"
        }

        func footnotesXML() -> String? {
            guard !footnoteNumbers.isEmpty else { return nil }
            let definitions = footnoteNumbers.sorted(by: { $0.value < $1.value }).map { identifier, number in
                let runs = document.footnotes[identifier] ?? [.init(text: identifier)]
                return "<w:footnote w:id=\"\(number)\">\(paragraph(runs: runs, includeFootnoteMark: true, allowRelationships: false))</w:footnote>"
            }.joined()
            return xmlHeader + """
            <w:footnotes xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
              <w:footnote w:type="separator" w:id="-1"><w:p><w:r><w:separator/></w:r></w:p></w:footnote>
              <w:footnote w:type="continuationSeparator" w:id="0"><w:p><w:r><w:continuationSeparator/></w:r></w:p></w:footnote>
              \(definitions)
            </w:footnotes>
            """
        }

        private func paragraph(
            runs: [MarkdownExportRun],
            style: String? = nil,
            numbering: (id: Int, level: Int)? = nil,
            bookmark: String? = nil,
            includeFootnoteMark: Bool = false,
            allowRelationships: Bool = true
        ) -> String {
            var properties = ""
            if let style { properties += "<w:pStyle w:val=\"\(style)\"/>" }
            if let numbering {
                properties += "<w:numPr><w:ilvl w:val=\"\(numbering.level)\"/><w:numId w:val=\"\(numbering.id)\"/></w:numPr>"
            }
            let paragraphProperties = properties.isEmpty ? "" : "<w:pPr>\(properties)</w:pPr>"
            var contents = includeFootnoteMark
                ? "<w:r><w:rPr><w:rStyle w:val=\"FootnoteReference\"/></w:rPr><w:footnoteRef/><w:t xml:space=\"preserve\"> </w:t></w:r>"
                : ""
            if let bookmark {
                let id = nextBookmarkNumber
                nextBookmarkNumber += 1
                contents += "<w:bookmarkStart w:id=\"\(id)\" w:name=\"\(bookmark)\"/>"
                contents += render(runs: runs, allowRelationships: allowRelationships)
                contents += "<w:bookmarkEnd w:id=\"\(id)\"/>"
            } else {
                contents += render(runs: runs, allowRelationships: allowRelationships)
            }
            return "<w:p>\(paragraphProperties)\(contents)</w:p>"
        }

        private func render(runs: [MarkdownExportRun], allowRelationships: Bool) -> String {
            runs.map { run in
                if let identifier = run.footnoteIdentifier,
                   let number = footnoteNumbers[identifier]
                {
                    return "<w:r><w:rPr><w:rStyle w:val=\"FootnoteReference\"/></w:rPr><w:footnoteReference w:id=\"\(number)\"/></w:r>"
                }
                if let source = run.imageSource {
                    guard allowRelationships else {
                        return imagePlaceholder(source: source, alt: run.text)
                    }
                    return image(source: source, alt: run.text)
                }
                if let link = run.link {
                    if isExternalLink(link) {
                        guard allowRelationships else {
                            return textRun(run, forceHyperlinkStyle: true)
                                + textRun(.init(text: " (\(link))"))
                        }
                        let relationshipID: String
                        if let existing = hyperlinkRelationshipByTarget[link] {
                            relationshipID = existing
                        } else {
                            relationshipID = nextRelationshipID()
                            relationships.append(.init(
                                id: relationshipID,
                                type: relationshipNamespace + "/hyperlink",
                                target: link,
                                external: true
                            ))
                            hyperlinkRelationshipByTarget[link] = relationshipID
                        }
                        return "<w:hyperlink r:id=\"\(relationshipID)\">\(textRun(run, forceHyperlinkStyle: true))</w:hyperlink>"
                    }
                    if link.hasPrefix("#") {
                        let anchor = String(link.dropFirst())
                        return "<w:hyperlink w:anchor=\"\(xml(anchor))\" w:history=\"1\">\(textRun(run, forceHyperlinkStyle: true))</w:hyperlink>"
                    }
                    // Relative links cannot be opened from the exported file; keep the
                    // text visibly styled as a link and show the target next to it.
                    return textRun(run, forceHyperlinkStyle: true) + textRun(.init(text: " (\(link))"))
                }
                return textRun(run)
            }.joined()
        }

        private func textRun(_ run: MarkdownExportRun, forceHyperlinkStyle: Bool = false) -> String {
            var properties = run.math
                ? "<w:rFonts w:ascii=\"Cambria Math\" w:hAnsi=\"Cambria Math\" w:eastAsia=\"Cambria Math\" w:cs=\"Cambria Math\"/>"
                : run.code
                    ? "<w:rFonts w:ascii=\"Menlo\" w:hAnsi=\"Menlo\" w:eastAsia=\"Arial Unicode MS\" w:cs=\"Arial Unicode MS\"/>"
                    : "<w:rFonts w:ascii=\"Arial Unicode MS\" w:hAnsi=\"Arial Unicode MS\" w:eastAsia=\"Arial Unicode MS\" w:cs=\"Arial Unicode MS\"/>"
            if forceHyperlinkStyle { properties += "<w:rStyle w:val=\"Hyperlink\"/>" }
            if run.bold { properties += "<w:b/>" }
            if run.italic { properties += "<w:i/>" }
            if run.strikethrough { properties += "<w:strike/>" }
            if run.code { properties += "<w:rStyle w:val=\"CodeChar\"/>" }
            let runProperties = "<w:rPr>\(properties)</w:rPr>"
            let pieces = run.text.split(separator: "\n", omittingEmptySubsequences: false)
            let content = pieces.enumerated().map { offset, piece in
                let breakXML = offset == 0 ? "" : "<w:br/>"
                return breakXML + "<w:t xml:space=\"preserve\">\(xml(String(piece)))</w:t>"
            }.joined()
            return "<w:r>\(runProperties)\(content)</w:r>"
        }

        private func image(source: String, alt: String) -> String {
            guard let image = images[source],
                  let fileExtension = normalizedImageExtension(image.fileExtension)
            else {
                return imagePlaceholder(source: source, alt: alt)
            }
            let value: (relationshipID: String, name: String, image: MarkdownExportImage)
            if let existing = mediaBySource[source] {
                value = existing
            } else {
                let name = "image\(mediaParts.count + 1).\(fileExtension)"
                let relationshipID = nextRelationshipID()
                relationships.append(.init(
                    id: relationshipID,
                    type: relationshipNamespace + "/image",
                    target: "media/\(name)"
                ))
                mediaParts.append(.init(
                    name: name,
                    data: image.data,
                    contentType: imageContentType(fileExtension)
                ))
                value = (relationshipID, name, image)
                mediaBySource[source] = value
            }

            let maximumWidthEMU = 5_800_000.0
            let originalWidthEMU = Double(max(1, value.image.widthPixels)) * 9_525.0
            let scale = min(1.0, maximumWidthEMU / originalWidthEMU)
            let width = Int64(originalWidthEMU * scale)
            let height = Int64(Double(max(1, value.image.heightPixels)) * 9_525.0 * scale)
            let drawingID = nextDrawingNumber
            nextDrawingNumber += 1
            let safeAlt = xml(alt.isEmpty ? source : alt)

            return """
            <w:r><w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0">
              <wp:extent cx="\(width)" cy="\(height)"/><wp:docPr id="\(drawingID)" name="Picture \(drawingID)" descr="\(safeAlt)"/>
              <a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">
                <pic:pic><pic:nvPicPr><pic:cNvPr id="0" name="\(xml(value.name))"/><pic:cNvPicPr/></pic:nvPicPr>
                  <pic:blipFill><a:blip r:embed="\(value.relationshipID)"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>
                  <pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\(width)" cy="\(height)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr>
                </pic:pic>
              </a:graphicData></a:graphic>
            </wp:inline></w:drawing></w:r>
            """
        }

        private func imagePlaceholder(source: String, alt: String) -> String {
            let label = alt.isEmpty ? source : alt
            return textRun(.init(
                text: String.localizedStringWithFormat(
                    String(localized: "export.image-placeholder %@"),
                    label
                ),
                italic: true
            ))
        }

        private func table(_ rows: [[MarkdownExportTableCell]]) -> String {
            guard !rows.isEmpty else { return "" }
            let columnCount = max(1, rows.map(\.count).max() ?? 1)
            let width = 9_000 / columnCount
            let grid = Array(repeating: "<w:gridCol w:w=\"\(width)\"/>", count: columnCount).joined()
            let rowXML = rows.map { row in
                let cells = (0..<columnCount).map { index in
                    let cell = index < row.count ? row[index] : .init(runs: [])
                    let shading = cell.isHeader ? "<w:shd w:val=\"clear\" w:fill=\"EDEDED\"/>" : ""
                    let runs = cell.isHeader
                        ? cell.runs.map {
                            var value = $0
                            value.bold = true
                            return value
                        }
                        : cell.runs
                    return "<w:tc><w:tcPr><w:tcW w:w=\"\(width)\" w:type=\"dxa\"/>\(shading)</w:tcPr>\(paragraph(runs: runs))</w:tc>"
                }.joined()
                return "<w:tr>\(cells)</w:tr>"
            }.joined()
            return "<w:tbl><w:tblPr><w:tblStyle w:val=\"TableGrid\"/><w:tblW w:w=\"0\" w:type=\"auto\"/><w:tblLook w:val=\"04A0\" w:firstRow=\"1\" w:lastRow=\"0\" w:firstColumn=\"1\" w:lastColumn=\"0\" w:noHBand=\"0\" w:noVBand=\"1\"/></w:tblPr><w:tblGrid>\(grid)</w:tblGrid>\(rowXML)</w:tbl>"
        }

        private func tableOfContents() -> String {
            var result = paragraph(
                runs: [.init(text: String(localized: "export.table-of-contents"), bold: true)],
                style: "Heading1"
            )
            var headingOrdinal = 0
            for block in document.blocks where block.kind == .heading {
                headingOrdinal += 1
                let text = block.runs.map(\.text).joined()
                let indentation = max(0, block.level - 1) * 360
                result += "<w:p><w:pPr><w:ind w:left=\"\(indentation)\"/></w:pPr><w:hyperlink w:anchor=\"heading_\(headingOrdinal)\" w:history=\"1\"><w:r><w:rPr><w:rFonts w:ascii=\"Arial Unicode MS\" w:hAnsi=\"Arial Unicode MS\" w:eastAsia=\"Arial Unicode MS\" w:cs=\"Arial Unicode MS\"/><w:rStyle w:val=\"Hyperlink\"/></w:rPr><w:t xml:space=\"preserve\">\(xml(text))</w:t></w:r></w:hyperlink></w:p>"
            }
            return result
        }

        // Visits every run in the document body, including table cells.
        private func forEachRun(_ visit: (MarkdownExportRun) -> Void) {
            for block in document.blocks {
                block.runs.forEach(visit)
                for row in block.tableRows {
                    for cell in row {
                        cell.runs.forEach(visit)
                    }
                }
            }
        }

        private func assignFootnoteNumbers() {
            var next = 1
            forEachRun { run in
                guard let identifier = run.footnoteIdentifier,
                      footnoteNumbers[identifier] == nil
                else { return }
                footnoteNumbers[identifier] = next
                next += 1
            }
        }

        func numberingXML() -> String {
            func levels(bullet: Bool) -> String {
                (0..<9).map { level in
                    let format = bullet ? "bullet" : "decimal"
                    let text = bullet ? "•" : "%\(level + 1)."
                    let font = bullet ? "<w:rPr><w:rFonts w:ascii=\"Symbol\" w:hAnsi=\"Symbol\"/></w:rPr>" : ""
                    return "<w:lvl w:ilvl=\"\(level)\"><w:start w:val=\"1\"/><w:numFmt w:val=\"\(format)\"/><w:lvlText w:val=\"\(text)\"/><w:lvlJc w:val=\"left\"/><w:pPr><w:tabs><w:tab w:val=\"num\" w:pos=\"\(720 + level * 360)\"/></w:tabs><w:ind w:left=\"\(720 + level * 360)\" w:hanging=\"360\"/></w:pPr>\(font)</w:lvl>"
                }.joined()
            }
            let abstractNums = "<w:abstractNum w:abstractNumId=\"0\"><w:multiLevelType w:val=\"hybridMultilevel\"/>\(levels(bullet: true))</w:abstractNum><w:abstractNum w:abstractNumId=\"1\"><w:multiLevelType w:val=\"multilevel\"/>\(levels(bullet: false))</w:abstractNum>"
            var nums = "<w:num w:numId=\"1\"><w:abstractNumId w:val=\"0\"/></w:num>"
            for entry in orderedListNumberings {
                let startOverride = entry.start > 1
                    ? "<w:lvlOverride w:ilvl=\"0\"><w:startOverride w:val=\"\(entry.start)\"/></w:lvlOverride>"
                    : ""
                nums += "<w:num w:numId=\"\(entry.numberingID)\"><w:abstractNumId w:val=\"1\"/>\(startOverride)</w:num>"
            }
            return xmlHeader + "<w:numbering xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\">\(abstractNums)\(nums)</w:numbering>"
        }

        private func nextRelationshipID() -> String {
            defer { nextRelationshipNumber += 1 }
            return "rId\(nextRelationshipNumber)"
        }
    }
}

private let xmlHeader = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
private let relationshipNamespace = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"

private func xml(_ value: String) -> String {
    var result = ""
    result.reserveCapacity(value.utf8.count)
    for scalar in value.unicodeScalars {
        switch scalar {
        case "&": result += "&amp;"
        case "<": result += "&lt;"
        case ">": result += "&gt;"
        case "\"": result += "&quot;"
        case "'": result += "&apos;"
        default:
            if isLegalXMLScalar(scalar) {
                result.unicodeScalars.append(scalar)
            }
        }
    }
    return result
}

// XML 1.0 legal characters: #x9 | #xA | #xD | [#x20-#xD7FF] | [#xE000-#xFFFD] | [#x10000-#x10FFFF]
private func isLegalXMLScalar(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x9, 0xA, 0xD,
         0x20...0xD7FF,
         0xE000...0xFFFD,
         0x10000...0x10FFFF:
        true
    default:
        false
    }
}

private func isExternalLink(_ value: String) -> Bool {
    guard let scheme = URLComponents(string: value)?.scheme?.lowercased() else { return false }
    return scheme == "https" || scheme == "http" || scheme == "mailto"
}

// Only formats Word can actually render are passed through; anything else
// (webp, heic, svg, ...) falls back to a text placeholder.
private func normalizedImageExtension(_ value: String) -> String? {
    switch value.lowercased() {
    case "png": "png"
    case "jpg", "jpeg": "jpeg"
    case "gif": "gif"
    case "bmp": "bmp"
    case "tif", "tiff": "tiff"
    default: nil
    }
}

private func imageContentType(_ fileExtension: String) -> String {
    switch fileExtension {
    case "jpeg": "image/jpeg"
    case "gif": "image/gif"
    case "bmp": "image/bmp"
    case "tiff": "image/tiff"
    default: "image/png"
    }
}

private let rootRelationshipsXML = xmlHeader + """
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
  <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>
  <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/>
</Relationships>
"""

private let settingsXML = xmlHeader + """
<w:settings xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:zoom w:percent="100"/><w:updateFields w:val="true"/><w:compat/>
</w:settings>
"""

private let stylesXML = xmlHeader + """
<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Arial Unicode MS" w:hAnsi="Arial Unicode MS" w:eastAsia="Arial Unicode MS" w:cs="Arial Unicode MS"/><w:sz w:val="22"/><w:szCs w:val="22"/><w:lang w:val="en-US" w:eastAsia="zh-CN"/></w:rPr></w:rPrDefault><w:pPrDefault><w:pPr><w:spacing w:after="160" w:line="360" w:lineRule="auto"/></w:pPr></w:pPrDefault></w:docDefaults>
  <w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/><w:rPr><w:rFonts w:ascii="Arial Unicode MS" w:hAnsi="Arial Unicode MS" w:eastAsia="Arial Unicode MS" w:cs="Arial Unicode MS"/></w:rPr></w:style>
  <w:style w:type="character" w:default="1" w:styleId="DefaultParagraphFont"><w:name w:val="Default Paragraph Font"/><w:rPr><w:rFonts w:ascii="Arial Unicode MS" w:hAnsi="Arial Unicode MS" w:eastAsia="Arial Unicode MS" w:cs="Arial Unicode MS"/></w:rPr></w:style>
  <w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:pPr><w:keepNext/><w:keepLines/><w:spacing w:before="360" w:after="180"/><w:outlineLvl w:val="0"/></w:pPr><w:rPr><w:b/><w:sz w:val="36"/><w:szCs w:val="36"/></w:rPr></w:style>
  <w:style w:type="paragraph" w:styleId="Heading2"><w:name w:val="heading 2"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:pPr><w:keepNext/><w:keepLines/><w:spacing w:before="300" w:after="160"/><w:outlineLvl w:val="1"/></w:pPr><w:rPr><w:b/><w:sz w:val="30"/><w:szCs w:val="30"/></w:rPr></w:style>
  <w:style w:type="paragraph" w:styleId="Heading3"><w:name w:val="heading 3"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:pPr><w:keepNext/><w:keepLines/><w:spacing w:before="240" w:after="120"/><w:outlineLvl w:val="2"/></w:pPr><w:rPr><w:b/><w:sz w:val="26"/><w:szCs w:val="26"/></w:rPr></w:style>
  <w:style w:type="paragraph" w:styleId="Heading4"><w:name w:val="heading 4"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:pPr><w:keepNext/><w:outlineLvl w:val="3"/></w:pPr><w:rPr><w:b/></w:rPr></w:style>
  <w:style w:type="paragraph" w:styleId="Heading5"><w:name w:val="heading 5"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:pPr><w:keepNext/><w:outlineLvl w:val="4"/></w:pPr><w:rPr><w:b/><w:i/></w:rPr></w:style>
  <w:style w:type="paragraph" w:styleId="Heading6"><w:name w:val="heading 6"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:pPr><w:keepNext/><w:outlineLvl w:val="5"/></w:pPr><w:rPr><w:i/></w:rPr></w:style>
  <w:style w:type="paragraph" w:styleId="CodeBlock"><w:name w:val="Code Block"/><w:basedOn w:val="Normal"/><w:pPr><w:keepLines/><w:spacing w:before="100" w:after="160"/><w:shd w:val="clear" w:fill="F3F3F3"/><w:ind w:left="180" w:right="180"/></w:pPr><w:rPr><w:rFonts w:ascii="Menlo" w:hAnsi="Menlo" w:eastAsia="Arial Unicode MS"/><w:sz w:val="19"/></w:rPr></w:style>
  <w:style w:type="paragraph" w:styleId="MathBlock"><w:name w:val="Math Block"/><w:basedOn w:val="Normal"/><w:pPr><w:jc w:val="center"/><w:keepLines/></w:pPr><w:rPr><w:rFonts w:ascii="Cambria Math" w:hAnsi="Cambria Math" w:eastAsia="Cambria Math"/></w:rPr></w:style>
  <w:style w:type="paragraph" w:styleId="BlockQuote"><w:name w:val="Block Quote"/><w:basedOn w:val="Normal"/><w:pPr><w:ind w:left="540" w:right="180"/><w:pBdr><w:left w:val="single" w:sz="18" w:space="8" w:color="4A90E2"/></w:pBdr></w:pPr><w:rPr><w:color w:val="666666"/><w:i/></w:rPr></w:style>
  <w:style w:type="character" w:styleId="Hyperlink"><w:name w:val="Hyperlink"/><w:basedOn w:val="DefaultParagraphFont"/><w:uiPriority w:val="99"/><w:unhideWhenUsed/><w:rPr><w:color w:val="2677D9"/><w:u w:val="single"/></w:rPr></w:style>
  <w:style w:type="character" w:styleId="CodeChar"><w:name w:val="Code Char"/><w:basedOn w:val="DefaultParagraphFont"/><w:rPr><w:rFonts w:ascii="Menlo" w:hAnsi="Menlo" w:eastAsia="Arial Unicode MS"/><w:shd w:val="clear" w:fill="F3F3F3"/><w:sz w:val="20"/></w:rPr></w:style>
  <w:style w:type="character" w:styleId="FootnoteReference"><w:name w:val="footnote reference"/><w:basedOn w:val="DefaultParagraphFont"/><w:rPr><w:vertAlign w:val="superscript"/></w:rPr></w:style>
  <w:style w:type="table" w:styleId="TableGrid"><w:name w:val="Table Grid"/><w:uiPriority w:val="59"/><w:qFormat/><w:tblPr><w:tblBorders><w:top w:val="single" w:sz="4" w:color="BFBFBF"/><w:left w:val="single" w:sz="4" w:color="BFBFBF"/><w:bottom w:val="single" w:sz="4" w:color="BFBFBF"/><w:right w:val="single" w:sz="4" w:color="BFBFBF"/><w:insideH w:val="single" w:sz="4" w:color="BFBFBF"/><w:insideV w:val="single" w:sz="4" w:color="BFBFBF"/></w:tblBorders><w:tblCellMar><w:top w:w="80" w:type="dxa"/><w:left w:w="100" w:type="dxa"/><w:bottom w:w="80" w:type="dxa"/><w:right w:w="100" w:type="dxa"/></w:tblCellMar></w:tblPr></w:style>
</w:styles>
"""

private func corePropertiesXML(title: String, createdAt: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    let timestamp = formatter.string(from: createdAt)
    return xmlHeader + """
    <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" xmlns:dcmitype="http://purl.org/dc/dcmitype/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <dc:title>\(xml(title))</dc:title><dc:creator>Markdown</dc:creator><cp:lastModifiedBy>Markdown</cp:lastModifiedBy><dcterms:created xsi:type="dcterms:W3CDTF">\(timestamp)</dcterms:created><dcterms:modified xsi:type="dcterms:W3CDTF">\(timestamp)</dcterms:modified>
    </cp:coreProperties>
    """
}

private let appPropertiesXML = xmlHeader + """
<Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties" xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes"><Application>Markdown</Application><AppVersion>1.0</AppVersion></Properties>
"""
