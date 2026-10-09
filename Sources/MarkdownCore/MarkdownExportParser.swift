import Foundation

public enum MarkdownExportParser {
    private static let metadataTitlePattern = makeExpression(#"^title\s*:\s*[\"']?(.*?)[\"']?\s*$"#)
    private static let footnoteDefinitionPattern = makeExpression(#"^\[\^([^\]]+)\]:\s*(.*)$"#)
    private static let fencePattern = makeExpression(#"^\s{0,3}(`{3,}|~{3,})\s*([^ ]*)\s*$"#)
    private static let fenceStartPattern = makeExpression(#"^\s{0,3}(`{3,}|~{3,})"#)
    private static let headingPattern = makeExpression(#"^\s{0,3}(#{1,6})\s+(.+?)\s*#*\s*$"#)
    private static let headingStartPattern = makeExpression(#"^\s{0,3}(#{1,6})\s+"#)
    private static let horizontalRulePattern = makeExpression(#"^\s{0,3}((\*\s*){3,}|(-\s*){3,}|(_\s*){3,})$"#)
    private static let htmlBlockPattern = makeExpression(#"^\s*</?[A-Za-z][^>]*>"#)
    private static let htmlCommentPattern = makeExpression(#"^\s*<!--"#)
    private static let listItemPattern = makeExpression(#"^(\s*)([-+*]|\d+[.)])\s+(.+)$"#)
    private static let taskMarkerPattern = makeExpression(#"^\[([ xX])\]\s+(.*)$"#)
    private static let tableSeparatorCellPattern = makeExpression(#"^:?-{3,}:?$"#)

    // All patterns are compile-time constants; NSRegularExpression is thread-safe
    // and safe to share across parser invocations.
    private static func makeExpression(_ pattern: String) -> NSRegularExpression {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: pattern)
    }

    public static func parse(_ markdown: String, fallbackTitle: String = "Markdown") -> MarkdownExportDocument {
        let normalized = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var lines = normalized.components(separatedBy: "\n")
        var metadataTitle: String?

        if lines.first?.trimmingCharacters(in: .whitespaces) == "---",
           let end = lines.dropFirst().firstIndex(where: {
               let value = $0.trimmingCharacters(in: .whitespaces)
               return value == "---" || value == "..."
           })
        {
            for line in lines[1..<end] {
                if let fields = captures(metadataTitlePattern, in: line),
                   let title = fields[safe: 1], !title.isEmpty
                {
                    metadataTitle = title
                }
            }
            lines.removeSubrange(0...end)
        }

        var footnotes: [String: [MarkdownExportRun]] = [:]
        var filteredLines: [String] = []
        var index = 0
        // Footnote definitions are collected only outside fenced code blocks;
        // a `[^x]:` line inside a fence is literal example text and must stay
        // in the exported content. The fence tracking mirrors the block
        // parser below (``` or ~~~ markers, optional info string).
        var fenceMarker: String?
        while index < lines.count {
            let line = lines[index]
            if let marker = fenceMarker {
                filteredLines.append(line)
                index += 1
                if line.trimmingCharacters(in: .whitespaces).hasPrefix(marker) {
                    fenceMarker = nil
                }
                continue
            }
            if let fence = captures(fencePattern, in: line),
               let marker = fence[safe: 1]
            {
                fenceMarker = marker
                filteredLines.append(line)
                index += 1
                continue
            }
            if let fields = captures(footnoteDefinitionPattern, in: line),
               let identifier = fields[safe: 1],
               var body = fields[safe: 2]
            {
                index += 1
                while index < lines.count,
                      lines[index].hasPrefix("    ") || lines[index].hasPrefix("\t")
                {
                    body += " " + lines[index].trimmingCharacters(in: .whitespaces)
                    index += 1
                }
                footnotes[identifier] = parseInline(body)
                continue
            }
            filteredLines.append(lines[index])
            index += 1
        }
        lines = filteredLines

        var blocks: [MarkdownExportBlock] = []
        index = 0
        while index < lines.count {
            let line = lines[index]
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                index += 1
                continue
            }

            if let fence = captures(fencePattern, in: line),
               let marker = fence[safe: 1]
            {
                let language = fence[safe: 2] ?? ""
                var body: [String] = []
                index += 1
                while index < lines.count,
                      !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(marker)
                {
                    body.append(lines[index])
                    index += 1
                }
                if index < lines.count { index += 1 }
                let kind: MarkdownExportBlock.Kind = language.lowercased() == "mermaid"
                    ? .diagram
                    : .codeBlock
                blocks.append(.init(
                    kind: kind,
                    runs: [.init(text: body.joined(separator: "\n"), code: true)],
                    language: language.isEmpty ? nil : language
                ))
                continue
            }

            if line.trimmingCharacters(in: .whitespaces) == "$$" {
                var body: [String] = []
                index += 1
                while index < lines.count,
                      lines[index].trimmingCharacters(in: .whitespaces) != "$$"
                {
                    body.append(lines[index])
                    index += 1
                }
                if index < lines.count { index += 1 }
                blocks.append(.init(
                    kind: .mathBlock,
                    runs: [.init(text: body.joined(separator: "\n"), math: true)]
                ))
                continue
            }

            if let heading = captures(headingPattern, in: line),
               let marks = heading[safe: 1], let body = heading[safe: 2]
            {
                blocks.append(.init(kind: .heading, level: marks.count, runs: parseInline(body)))
                index += 1
                continue
            }

            if matches(horizontalRulePattern, in: line) {
                blocks.append(.init(kind: .horizontalRule))
                index += 1
                continue
            }

            if line.trimmingCharacters(in: .whitespaces).lowercased() == "[toc]" {
                blocks.append(.init(kind: .tableOfContents))
                index += 1
                continue
            }

            if line.hasPrefix(">") {
                var quoteLines: [String] = []
                while index < lines.count, lines[index].hasPrefix(">") {
                    var value = String(lines[index].dropFirst())
                    if value.hasPrefix(" ") { value.removeFirst() }
                    quoteLines.append(value)
                    index += 1
                }
                let body = joinParagraphLines(quoteLines)
                blocks.append(.init(kind: .blockquote, runs: parseInline(body)))
                continue
            }

            if index + 1 < lines.count, isTableSeparator(lines[index + 1]) {
                var rows: [[MarkdownExportTableCell]] = [
                    splitTableRow(line).map { .init(runs: parseInline($0), isHeader: true) },
                ]
                index += 2
                while index < lines.count,
                      lines[index].contains("|"),
                      !lines[index].trimmingCharacters(in: .whitespaces).isEmpty
                {
                    rows.append(splitTableRow(lines[index]).map { .init(runs: parseInline($0)) })
                    index += 1
                }
                blocks.append(.init(kind: .table, tableRows: rows))
                continue
            }

            if let list = listItem(from: line) {
                blocks.append(list)
                index += 1
                while index < lines.count, let next = listItem(from: lines[index]) {
                    blocks.append(next)
                    index += 1
                }
                continue
            }

            if matches(htmlBlockPattern, in: line) || matches(htmlCommentPattern, in: line) {
                var htmlLines = [line]
                index += 1
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                    htmlLines.append(lines[index])
                    index += 1
                }
                blocks.append(.init(
                    kind: .rawHTML,
                    runs: [.init(text: htmlLines.joined(separator: "\n"), code: true)]
                ))
                continue
            }

            var paragraphLines = [line]
            index += 1
            while index < lines.count,
                  !lines[index].trimmingCharacters(in: .whitespaces).isEmpty,
                  !startsBlock(lines, at: index)
            {
                paragraphLines.append(lines[index])
                index += 1
            }
            blocks.append(.init(
                kind: .paragraph,
                runs: parseInline(joinParagraphLines(paragraphLines))
            ))
        }

        let firstHeading = blocks.first(where: { $0.kind == .heading && $0.level == 1 })
        let headingTitle = firstHeading?.runs.map(\.text).joined()
        return MarkdownExportDocument(
            title: metadataTitle ?? headingTitle ?? fallbackTitle,
            blocks: blocks,
            footnotes: footnotes
        )
    }

    private static func joinParagraphLines(_ lines: [String]) -> String {
        lines.enumerated().map { index, originalLine in
            var line = originalLine
            let trailingSpaces = line.reversed().prefix { $0 == " " }.count
            let trailingBackslashes = line.reversed().prefix { $0 == "\\" }.count
            let hardBreak: Bool
            if trailingSpaces >= 2 {
                line.removeLast(trailingSpaces)
                hardBreak = true
            } else if !trailingBackslashes.isMultiple(of: 2) {
                line.removeLast()
                hardBreak = true
            } else {
                if trailingSpaces == 1 { line.removeLast() }
                hardBreak = false
            }

            guard index < lines.count - 1 else { return line }
            return line + (hardBreak ? "\n" : " ")
        }.joined()
    }

    public static func imageSources(in document: MarkdownExportDocument) -> Set<String> {
        var result: Set<String> = []
        for block in document.blocks {
            for run in block.runs where run.imageSource != nil {
                result.insert(run.imageSource!)
            }
            for row in block.tableRows {
                for cell in row {
                    for run in cell.runs where run.imageSource != nil {
                        result.insert(run.imageSource!)
                    }
                }
            }
        }
        for runs in document.footnotes.values {
            for run in runs where run.imageSource != nil {
                result.insert(run.imageSource!)
            }
        }
        return result
    }

    private struct InlineStyle {
        var bold = false
        var italic = false
        var strikethrough = false
        var code = false
        var math = false
        var link: String?
    }

    private static func parseInline(_ source: String, style: InlineStyle = .init()) -> [MarkdownExportRun] {
        var runs: [MarkdownExportRun] = []
        var index = source.startIndex
        var plain = ""

        func appendPlain() {
            guard !plain.isEmpty else { return }
            appendRun(.init(
                text: plain,
                bold: style.bold,
                italic: style.italic,
                strikethrough: style.strikethrough,
                code: style.code,
                math: style.math,
                link: style.link
            ), to: &runs)
            plain = ""
        }

        while index < source.endIndex {
            if source[index] == "\\" {
                let next = source.index(after: index)
                if next < source.endIndex {
                    plain.append(source[next])
                    index = source.index(after: next)
                    continue
                }
            }

            if source[index...].hasPrefix("!["),
               let labelEnd = source[index...].range(of: "]("),
               let targetEnd = source[labelEnd.upperBound...].firstIndex(of: ")")
            {
                appendPlain()
                let altStart = source.index(index, offsetBy: 2)
                let alt = String(source[altStart..<labelEnd.lowerBound])
                let target = String(source[labelEnd.upperBound..<targetEnd])
                    .split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
                appendRun(.init(text: alt, imageSource: target), to: &runs)
                index = source.index(after: targetEnd)
                continue
            }

            if source[index...].hasPrefix("[^"),
               let end = source[index...].firstIndex(of: "]")
            {
                appendPlain()
                let start = source.index(index, offsetBy: 2)
                let identifier = String(source[start..<end])
                appendRun(.init(text: identifier, footnoteIdentifier: identifier), to: &runs)
                index = source.index(after: end)
                continue
            }

            if source[index] == "[",
               let labelEnd = source[index...].range(of: "]("),
               let targetEnd = source[labelEnd.upperBound...].firstIndex(of: ")")
            {
                appendPlain()
                let labelStart = source.index(after: index)
                let label = String(source[labelStart..<labelEnd.lowerBound])
                let target = String(source[labelEnd.upperBound..<targetEnd])
                    .split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
                var nestedStyle = style
                nestedStyle.link = target
                for run in parseInline(label, style: nestedStyle) {
                    appendRun(run, to: &runs)
                }
                index = source.index(after: targetEnd)
                continue
            }

            // CommonMark-style boundaries for inline math: an opening "$" must not be
            // followed by whitespace, a closing "$" must not be preceded by whitespace.
            // This keeps plain prices like "$5 and $10" from being parsed as math.
            if source[index] == "$" {
                let contentStart = source.index(after: index)
                if contentStart < source.endIndex,
                   !source[contentStart].isWhitespace,
                   source[contentStart] != "$",
                   let closing = source[contentStart...].range(of: "$"),
                   closing.lowerBound > contentStart,
                   !source[source.index(before: closing.lowerBound)].isWhitespace
                {
                    appendPlain()
                    appendRun(.init(
                        text: String(source[contentStart..<closing.lowerBound]),
                        bold: style.bold,
                        italic: style.italic,
                        strikethrough: style.strikethrough,
                        code: style.code,
                        math: true,
                        link: style.link
                    ), to: &runs)
                    index = closing.upperBound
                    continue
                }
            }

            let delimiters: [(String, (inout InlineStyle) -> Void)] = [
                ("**", { $0.bold = true }),
                ("__", { $0.bold = true }),
                ("~~", { $0.strikethrough = true }),
                ("`", { $0.code = true }),
                ("*", { $0.italic = true }),
                ("_", { $0.italic = true }),
            ]
            var consumedDelimiter = false
            for (delimiter, mutate) in delimiters where source[index...].hasPrefix(delimiter) {
                let contentStart = source.index(index, offsetBy: delimiter.count)
                guard let closing = source[contentStart...].range(of: delimiter) else { continue }
                appendPlain()
                var nestedStyle = style
                mutate(&nestedStyle)
                let body = String(source[contentStart..<closing.lowerBound])
                let nestedRuns: [MarkdownExportRun]
                if delimiter == "`" {
                    nestedRuns = [.init(
                        text: body,
                        bold: nestedStyle.bold,
                        italic: nestedStyle.italic,
                        strikethrough: nestedStyle.strikethrough,
                        code: nestedStyle.code,
                        math: nestedStyle.math,
                        link: nestedStyle.link
                    )]
                } else {
                    nestedRuns = parseInline(body, style: nestedStyle)
                }
                for run in nestedRuns { appendRun(run, to: &runs) }
                index = closing.upperBound
                consumedDelimiter = true
                break
            }
            if consumedDelimiter { continue }

            plain.append(source[index])
            index = source.index(after: index)
        }
        appendPlain()
        return runs
    }

    private static func appendRun(_ run: MarkdownExportRun, to runs: inout [MarkdownExportRun]) {
        if let last = runs.last,
           last.bold == run.bold,
           last.italic == run.italic,
           last.strikethrough == run.strikethrough,
           last.code == run.code,
           last.math == run.math,
           last.link == run.link,
           last.imageSource == nil,
           run.imageSource == nil,
           last.footnoteIdentifier == nil,
           run.footnoteIdentifier == nil
        {
            runs[runs.count - 1].text += run.text
        } else {
            runs.append(run)
        }
    }

    private static func listItem(from line: String) -> MarkdownExportBlock? {
        guard let fields = captures(listItemPattern, in: line),
              let indentation = fields[safe: 1],
              let marker = fields[safe: 2],
              var body = fields[safe: 3]
        else {
            return nil
        }
        var checked: Bool?
        if let task = captures(taskMarkerPattern, in: body),
           let mark = task[safe: 1], let taskBody = task[safe: 2]
        {
            checked = mark.lowercased() == "x"
            body = taskBody
        }
        let ordered = marker.first?.isNumber == true
        let listStart = ordered ? Int(marker.dropLast()) ?? 1 : 1
        return .init(
            kind: .listItem,
            level: min(8, indentation.replacingOccurrences(of: "\t", with: "    ").count / 2),
            runs: parseInline(body),
            ordered: ordered,
            listStart: listStart,
            checked: checked
        )
    }

    private static func startsBlock(_ lines: [String], at index: Int) -> Bool {
        let line = lines[index]
        if line.hasPrefix(">") || listItem(from: line) != nil { return true }
        if line.trimmingCharacters(in: .whitespaces).lowercased() == "[toc]" { return true }
        if matches(headingStartPattern, in: line) { return true }
        if matches(fenceStartPattern, in: line) { return true }
        if matches(htmlBlockPattern, in: line) { return true }
        if index + 1 < lines.count, isTableSeparator(lines[index + 1]) { return true }
        return false
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let cells = splitTableRow(line)
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { matches(tableSeparatorCellPattern, in: $0) }
    }

    private static func splitTableRow(_ line: String) -> [String] {
        var value = line.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("|") { value.removeFirst() }
        if value.hasSuffix("|") { value.removeLast() }
        var cells: [String] = []
        var current = ""
        var escaped = false
        for character in value {
            if escaped {
                current.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "|" {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    private static func captures(_ expression: NSRegularExpression, in value: String) -> [String]? {
        guard let match = expression.firstMatch(
            in: value,
            range: NSRange(value.startIndex..., in: value)
        ) else {
            return nil
        }
        return (0..<match.numberOfRanges).map { index in
            let range = match.range(at: index)
            guard range.location != NSNotFound, let swiftRange = Range(range, in: value) else {
                return ""
            }
            return String(value[swiftRange])
        }
    }

    private static func matches(_ expression: NSRegularExpression, in value: String) -> Bool {
        expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
