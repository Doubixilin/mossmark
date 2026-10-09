import Foundation

public struct MarkdownExportDocument: Equatable, Sendable {
    public var title: String
    public var blocks: [MarkdownExportBlock]
    public var footnotes: [String: [MarkdownExportRun]]

    public init(
        title: String,
        blocks: [MarkdownExportBlock],
        footnotes: [String: [MarkdownExportRun]] = [:]
    ) {
        self.title = title
        self.blocks = blocks
        self.footnotes = footnotes
    }
}

public struct MarkdownExportBlock: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case paragraph
        case heading
        case blockquote
        case codeBlock
        case listItem
        case table
        case horizontalRule
        case tableOfContents
        case rawHTML
        case mathBlock
        case diagram
    }

    public var kind: Kind
    public var level: Int
    public var runs: [MarkdownExportRun]
    public var language: String?
    public var ordered: Bool
    public var listStart: Int
    public var checked: Bool?
    public var tableRows: [[MarkdownExportTableCell]]

    public init(
        kind: Kind,
        level: Int = 0,
        runs: [MarkdownExportRun] = [],
        language: String? = nil,
        ordered: Bool = false,
        listStart: Int = 1,
        checked: Bool? = nil,
        tableRows: [[MarkdownExportTableCell]] = []
    ) {
        self.kind = kind
        self.level = level
        self.runs = runs
        self.language = language
        self.ordered = ordered
        self.listStart = listStart
        self.checked = checked
        self.tableRows = tableRows
    }
}

public struct MarkdownExportTableCell: Equatable, Sendable {
    public var runs: [MarkdownExportRun]
    public var isHeader: Bool

    public init(runs: [MarkdownExportRun], isHeader: Bool = false) {
        self.runs = runs
        self.isHeader = isHeader
    }
}

public struct MarkdownExportRun: Equatable, Sendable {
    public var text: String
    public var bold: Bool
    public var italic: Bool
    public var strikethrough: Bool
    public var code: Bool
    public var math: Bool
    public var link: String?
    public var imageSource: String?
    public var footnoteIdentifier: String?

    public init(
        text: String,
        bold: Bool = false,
        italic: Bool = false,
        strikethrough: Bool = false,
        code: Bool = false,
        math: Bool = false,
        link: String? = nil,
        imageSource: String? = nil,
        footnoteIdentifier: String? = nil
    ) {
        self.text = text
        self.bold = bold
        self.italic = italic
        self.strikethrough = strikethrough
        self.code = code
        self.math = math
        self.link = link
        self.imageSource = imageSource
        self.footnoteIdentifier = footnoteIdentifier
    }
}

public struct MarkdownExportImage: Equatable, Sendable {
    public var data: Data
    public var fileExtension: String
    public var widthPixels: Int
    public var heightPixels: Int

    public init(
        data: Data,
        fileExtension: String,
        widthPixels: Int,
        heightPixels: Int
    ) {
        self.data = data
        self.fileExtension = fileExtension
        self.widthPixels = widthPixels
        self.heightPixels = heightPixels
    }
}
