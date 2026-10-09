import Foundation

public struct MarkdownOutlineItem: Equatable, Identifiable, Sendable {
    public let id: Int
    public let level: Int
    public let title: String
    public let line: Int

    public init(id: Int, level: Int, title: String, line: Int) {
        self.id = id
        self.level = level
        self.title = title
        self.line = line
    }
}

public enum MarkdownOutlineParser {
    private static let atxHeadingRegex = try! NSRegularExpression(
        pattern: #"^\s{0,3}(#{1,6})\s+(.+?)\s*#*\s*$"#
    )
    private static let setextUnderlineRegex = try! NSRegularExpression(
        pattern: #"^\s*(=+|-+)\s*$"#
    )

    public static func parse(_ source: String) -> [MarkdownOutlineItem] {
        let rawLines = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        var isInsideHTMLComment = false
        let lines = rawLines.map {
            strippingHTMLComments($0, isInside: &isInsideHTMLComment)
        }
        var items: [MarkdownOutlineItem] = []
        var fence: (marker: Character, length: Int)?
        var isInFrontMatter = lines.first?.trimmingCharacters(in: .whitespaces) == "---"

        for index in lines.indices {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if isInFrontMatter {
                if index > 0, trimmed == "---" || trimmed == "..." {
                    isInFrontMatter = false
                }
                continue
            }
            if let run = fenceRun(in: line) {
                if let openFence = fence {
                    if run.marker == openFence.marker,
                       run.length >= openFence.length,
                       run.remainder.trimmingCharacters(in: .whitespaces).isEmpty
                    {
                        fence = nil
                    }
                } else if run.length >= 3 {
                    fence = (run.marker, run.length)
                }
                continue
            }
            guard fence == nil else { continue }

            if let match = atxHeadingRegex
                .firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
               let marksRange = Range(match.range(at: 1), in: line),
               let titleRange = Range(match.range(at: 2), in: line)
            {
                items.append(.init(
                    id: items.count,
                    level: line[marksRange].count,
                    title: cleanTitle(String(line[titleRange])),
                    line: index + 1
                ))
                continue
            }

            if index + 1 < lines.count,
               !trimmed.isEmpty,
               isSetextUnderline(lines[index + 1])
            {
                let underline = lines[index + 1].trimmingCharacters(in: .whitespaces)
                items.append(.init(
                    id: items.count,
                    level: underline.first == "=" ? 1 : 2,
                    title: cleanTitle(trimmed),
                    line: index + 1
                ))
            }
        }
        return items
    }

    private static func isSetextUnderline(_ line: String) -> Bool {
        setextUnderlineRegex.firstMatch(
            in: line,
            range: NSRange(line.startIndex..., in: line)
        ) != nil
    }

    private static func cleanTitle(_ value: String) -> String {
        value
            .replacingOccurrences(of: #"!\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"\[([^\]]+)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"[*_~`]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func fenceRun(
        in line: String
    ) -> (marker: Character, length: Int, remainder: Substring)? {
        let indentation = line.prefix(while: { $0 == " " }).count
        guard indentation <= 3 else { return nil }
        let content = line.dropFirst(indentation)
        guard let marker = content.first, marker == "`" || marker == "~" else {
            return nil
        }
        let length = content.prefix(while: { $0 == marker }).count
        guard length >= 3 else { return nil }
        return (marker, length, content.dropFirst(length))
    }

    /// Removes HTML comments before parsing while preserving the original
    /// line array, so multiline comments cannot create phantom headings and
    /// reported source line numbers stay stable.
    private static func strippingHTMLComments(
        _ line: String,
        isInside: inout Bool
    ) -> String {
        var remainder = line[...]
        var result = ""
        while !remainder.isEmpty {
            if isInside {
                guard let end = remainder.range(of: "-->") else { return result }
                remainder = remainder[end.upperBound...]
                isInside = false
            } else if let start = remainder.range(of: "<!--") {
                result += remainder[..<start.lowerBound]
                remainder = remainder[start.upperBound...]
                isInside = true
            } else {
                result += remainder
                break
            }
        }
        return result
    }
}
