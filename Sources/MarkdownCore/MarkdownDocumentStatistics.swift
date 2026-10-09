import Foundation

public struct MarkdownDocumentStatistics: Equatable, Sendable {
    public static let empty = MarkdownDocumentStatistics(
        wordCount: 0,
        characterCount: 0,
        estimatedReadingMinutes: 0
    )

    public var wordCount: Int
    public var characterCount: Int
    public var estimatedReadingMinutes: Int

    public init(
        wordCount: Int,
        characterCount: Int,
        estimatedReadingMinutes: Int
    ) {
        self.wordCount = wordCount
        self.characterCount = characterCount
        self.estimatedReadingMinutes = estimatedReadingMinutes
    }

    public static func calculate(_ markdown: String) -> Self {
        let document = MarkdownExportParser.parse(markdown)
        var fragments: [String] = []
        for block in document.blocks {
            if block.kind == .table {
                fragments.append(contentsOf: block.tableRows.flatMap { row in
                    row.map { cell in cell.runs.map(\.text).joined() }
                })
            } else if block.kind != .horizontalRule,
                      block.kind != .tableOfContents,
                      block.kind != .codeBlock,
                      block.kind != .rawHTML
            {
                fragments.append(block.runs.map(\.text).joined())
            }
        }
        fragments.append(contentsOf: document.footnotes.values.map { runs in
            runs.map(\.text).joined()
        })

        let visibleText = fragments.joined(separator: "\n")
        var cjkCharacters = 0
        var latinWords = 0
        var characterCount = 0
        var insideWord = false

        func finishWord() {
            if insideWord { latinWords += 1 }
            insideWord = false
        }

        for character in visibleText {
            if character.isWhitespace {
                finishWord()
                continue
            }
            characterCount += 1
            if isCJK(character) {
                finishWord()
                cjkCharacters += 1
            } else if character.isLetter || character.isNumber {
                insideWord = true
            } else {
                finishWord()
            }
        }
        finishWord()

        let wordCount = cjkCharacters + latinWords
        let readingEstimate = Double(cjkCharacters) / 300 + Double(latinWords) / 220
        return MarkdownDocumentStatistics(
            wordCount: wordCount,
            characterCount: characterCount,
            estimatedReadingMinutes: wordCount == 0 ? 0 : max(1, Int(ceil(readingEstimate)))
        )
    }

    private static func isCJK(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3400...0x4DBF,
                 0x4E00...0x9FFF,
                 0xF900...0xFAFF,
                 0x20000...0x2FA1F,
                 0x3040...0x30FF,
                 0xAC00...0xD7AF:
                true
            default:
                false
            }
        }
    }
}
