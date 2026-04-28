import Foundation

/// A native subset of Markdown blocks used to render AI-generated reports without a web view.
public enum MarkdownBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case unorderedList([String])
    case orderedList([String])
    case codeBlock(language: String?, code: String)
    case blockquote(String)
    case table(headers: [String], rows: [[String]])
    case divider
}

/// Parses the Markdown structures commonly produced by Steno's AI agents.
public enum MarkdownBlockParser {
    public static func parse(_ markdown: String) -> [MarkdownBlock] {
        let normalized = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var blocks: [MarkdownBlock] = []
        var index = 0

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

            if trimmed.isEmpty {
                index += 1
                continue
            }

            if isCodeFence(trimmed) {
                let language = fenceLanguage(trimmed)
                let result = parseCodeBlock(lines: lines, startIndex: index + 1, language: language)
                blocks.append(.codeBlock(language: language, code: result.code))
                index = result.nextIndex
                continue
            }

            if let heading = heading(from: trimmed) {
                blocks.append(.heading(level: heading.level, text: heading.text))
                index += 1
                continue
            }

            if isDivider(trimmed) {
                blocks.append(.divider)
                index += 1
                continue
            }

            if isTableStart(lines: lines, index: index) {
                let result = parseTable(lines: lines, startIndex: index)
                blocks.append(.table(headers: result.headers, rows: result.rows))
                index = result.nextIndex
                continue
            }

            if let item = unorderedListItem(line) {
                let result = parseList(lines: lines, startIndex: index, firstItem: item, itemParser: unorderedListItem)
                blocks.append(.unorderedList(result.items))
                index = result.nextIndex
                continue
            }

            if let item = orderedListItem(line) {
                let result = parseList(lines: lines, startIndex: index, firstItem: item, itemParser: orderedListItem)
                blocks.append(.orderedList(result.items))
                index = result.nextIndex
                continue
            }

            if let quote = blockquoteLine(line) {
                let result = parseBlockquote(lines: lines, startIndex: index, firstLine: quote)
                blocks.append(.blockquote(result.text))
                index = result.nextIndex
                continue
            }

            let result = parseParagraph(lines: lines, startIndex: index)
            blocks.append(.paragraph(result.text))
            index = result.nextIndex
        }

        return blocks
    }

    private static func fenceLanguage(_ trimmedLine: String) -> String? {
        guard trimmedLine.hasPrefix("```") else {
            return nil
        }
        let language = trimmedLine.dropFirst(3).trimmingCharacters(in: .whitespacesAndNewlines)
        return language.isEmpty ? nil : language
    }

    private static func isCodeFence(_ trimmedLine: String) -> Bool {
        trimmedLine.hasPrefix("```")
    }

    private static func parseCodeBlock(
        lines: [String],
        startIndex: Int,
        language: String?
    ) -> (code: String, nextIndex: Int) {
        var codeLines: [String] = []
        var index = startIndex

        while index < lines.count {
            if lines[index].trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("```") {
                return (codeLines.joined(separator: "\n"), index + 1)
            }
            codeLines.append(lines[index])
            index += 1
        }

        return (codeLines.joined(separator: "\n"), index)
    }

    private static func heading(from trimmedLine: String) -> (level: Int, text: String)? {
        let level = trimmedLine.prefix { $0 == "#" }.count
        guard (1...6).contains(level) else {
            return nil
        }
        let remainder = trimmedLine.dropFirst(level)
        guard remainder.first == " " else {
            return nil
        }
        let text = remainder.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return nil
        }
        return (level, text)
    }

    private static func isDivider(_ trimmedLine: String) -> Bool {
        guard trimmedLine.count >= 3 else {
            return false
        }
        return trimmedLine.allSatisfy { $0 == "-" } || trimmedLine.allSatisfy { $0 == "*" }
    }

    private static func isTableStart(lines: [String], index: Int) -> Bool {
        guard index + 1 < lines.count,
              lines[index].contains("|"),
              lines[index + 1].contains("|") else {
            return false
        }
        return isTableSeparator(lines[index + 1])
    }

    private static func parseTable(
        lines: [String],
        startIndex: Int
    ) -> TableParseResult {
        let headers = tableCells(lines[startIndex])
        var rows: [[String]] = []
        var index = startIndex + 2

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, line.contains("|") else {
                break
            }
            rows.append(tableCells(line))
            index += 1
        }

        return TableParseResult(headers: headers, rows: rows, nextIndex: index)
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let cells = tableCells(line)
        guard !cells.isEmpty else {
            return false
        }
        return cells.allSatisfy { cell in
            let stripped = cell.trimmingCharacters(in: .whitespacesAndNewlines)
            let hyphenCount = stripped.filter { $0 == "-" }.count
            let allowed = stripped.allSatisfy { $0 == "-" || $0 == ":" || $0 == " " }
            return hyphenCount >= 3 && allowed
        }
    }

    private static func tableCells(_ line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("|") {
            trimmed.removeFirst()
        }
        if trimmed.hasSuffix("|") {
            trimmed.removeLast()
        }
        return trimmed
            .split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private static func unorderedListItem(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !isDivider(trimmed),
              trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") else {
            return nil
        }
        return String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func orderedListItem(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let dotIndex = trimmed.firstIndex(of: ".") else {
            return nil
        }
        let number = trimmed[..<dotIndex]
        guard !number.isEmpty, number.allSatisfy(\.isNumber) else {
            return nil
        }
        let remainder = trimmed[trimmed.index(after: dotIndex)...]
        guard remainder.first == " " else {
            return nil
        }
        return String(remainder.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parseList(
        lines: [String],
        startIndex: Int,
        firstItem: String,
        itemParser: (String) -> String?
    ) -> (items: [String], nextIndex: Int) {
        var items = [firstItem]
        var index = startIndex + 1

        while index < lines.count {
            guard let item = itemParser(lines[index]) else {
                break
            }
            items.append(item)
            index += 1
        }

        return (items, index)
    }

    private static func blockquoteLine(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix(">") else {
            return nil
        }
        return String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
    }

    private static func parseBlockquote(
        lines: [String],
        startIndex: Int,
        firstLine: String
    ) -> (text: String, nextIndex: Int) {
        var quoteLines = [firstLine]
        var index = startIndex + 1

        while index < lines.count {
            guard let line = blockquoteLine(lines[index]) else {
                break
            }
            quoteLines.append(line)
            index += 1
        }

        return (quoteLines.joined(separator: "\n"), index)
    }

    private static func parseParagraph(lines: [String], startIndex: Int) -> (text: String, nextIndex: Int) {
        var paragraphLines: [String] = []
        var index = startIndex

        while index < lines.count {
            let line = lines[index]
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isBlockStart(lines: lines, index: index) {
                break
            }
            paragraphLines.append(line.trimmingCharacters(in: .whitespacesAndNewlines))
            index += 1
        }

        return (paragraphLines.joined(separator: "\n"), index)
    }

    private static func isBlockStart(lines: [String], index: Int) -> Bool {
        guard index < lines.count else {
            return false
        }
        let line = lines[index]
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return isCodeFence(trimmed) ||
            heading(from: trimmed) != nil ||
            isDivider(trimmed) ||
            isTableStart(lines: lines, index: index) ||
            unorderedListItem(line) != nil ||
            orderedListItem(line) != nil ||
            blockquoteLine(line) != nil
    }
}

private struct TableParseResult {
    var headers: [String]
    var rows: [[String]]
    var nextIndex: Int
}
