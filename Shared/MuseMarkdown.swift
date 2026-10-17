import Foundation

/// Small block parser for chat Markdown. Inline syntax is handled by Foundation's
/// Markdown parser, while block layout stays native and readable on a Watch.
struct MuseMarkdown {
    struct Block: Equatable {
        enum Kind: Equatable {
            case paragraph
            case heading(Int)
            case listItem(marker: String, depth: Int, checked: Bool?)
            case quote
            case code(language: String?)
            case table(headers: [String], rows: [[String]])
            case divider
        }
        var kind: Kind
        var text: String
    }

    let blocks: [Block]

    init(_ source: String) {
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        var result: [Block] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { index += 1; continue }
            if let fence = Self.fence(trimmed) {
                let language = String(trimmed.dropFirst(fence.count)).trimmingCharacters(in: .whitespaces)
                var content: [String] = []
                index += 1
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    if candidate.count >= fence.count,
                       candidate.allSatisfy({ $0 == fence.character }) { index += 1; break }
                    content.append(lines[index]); index += 1
                }
                result.append(Block(kind: .code(language: language.isEmpty ? nil : language), text: content.joined(separator: "\n")))
                continue
            }
            if index + 1 < lines.count, let headers = Self.tableCells(trimmed),
               let separators = Self.tableCells(lines[index + 1]), headers.count == separators.count,
               separators.allSatisfy(Self.isTableSeparator) {
                var rows: [[String]] = []
                index += 2
                while index < lines.count, let cells = Self.tableCells(lines[index]), cells.count == headers.count {
                    rows.append(cells); index += 1
                }
                result.append(Block(kind: .table(headers: headers, rows: rows), text: "")); continue
            }
            if Self.isDivider(trimmed) {
                result.append(Block(kind: .divider, text: "")); index += 1; continue
            }
            if let heading = Self.heading(trimmed) {
                result.append(heading); index += 1; continue
            }
            // Setext headings: only a plain preceding line becomes the heading.
            if index + 1 < lines.count, let level = Self.setextLevel(lines[index + 1]),
               Self.listItem(line) == nil, !trimmed.hasPrefix(">") {
                result.append(Block(kind: .heading(level), text: trimmed)); index += 2; continue
            }
            if var item = Self.listItem(line) {
                index += 1
                // Preserve wrapped list text; a new nested marker stays its own row.
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).isEmpty,
                      Self.indentation(lines[index]) > Self.indentation(line),
                      Self.listItem(lines[index]) == nil,
                      Self.fence(lines[index].trimmingCharacters(in: .whitespaces)) == nil {
                    item.text += "\n" + lines[index].trimmingCharacters(in: .whitespaces)
                    index += 1
                }
                result.append(item); continue
            }
            if trimmed.hasPrefix(">") {
                var content: [String] = []
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    guard candidate.hasPrefix(">") else { break }
                    var text = String(candidate.dropFirst())
                    if text.first == " " { text.removeFirst() }
                    content.append(text); index += 1
                }
                result.append(Block(kind: .quote, text: content.joined(separator: "\n"))); continue
            }
            var content = [line]
            index += 1
            while index < lines.count {
                let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                if candidate.isEmpty || Self.fence(candidate) != nil || Self.isDivider(candidate)
                    || Self.heading(candidate) != nil || Self.listItem(lines[index]) != nil
                    || candidate.hasPrefix(">") { break }
                if index + 1 < lines.count, let cells = Self.tableCells(candidate),
                   let separators = Self.tableCells(lines[index + 1]), cells.count == separators.count,
                   separators.allSatisfy(Self.isTableSeparator) { break }
                // Let the next iteration recognize a setext heading on this line.
                if index + 1 < lines.count, Self.setextLevel(lines[index + 1]) != nil { break }
                content.append(lines[index]); index += 1
            }
            result.append(Block(kind: .paragraph, text: content.joined(separator: "\n")))
        }
        blocks = result
    }

    /// No HTML rendering, remote images, or extended attributes. Keep unsupported
    /// links as readable text rather than passing custom schemes to another app.
    static func inline(_ source: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false, interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible)
        var value = (try? AttributedString(markdown: source, options: options)) ?? AttributedString(source)
        for run in value.runs {
            if run[AttributeScopes.FoundationAttributes.ImageURLAttribute.self] != nil {
                value[run.range][AttributeScopes.FoundationAttributes.ImageURLAttribute.self] = nil
            }
            if let link = run[AttributeScopes.FoundationAttributes.LinkAttribute.self],
               !["https", "http", "mailto"].contains(link.scheme?.lowercased() ?? "") {
                value[run.range][AttributeScopes.FoundationAttributes.LinkAttribute.self] = nil
            }
        }
        return value
    }

    private static func fence(_ line: String) -> (character: Character, count: Int)? {
        guard let first = line.first, first == "`" || first == "~" else { return nil }
        let count = line.prefix(while: { $0 == first }).count
        return count >= 3 ? (first, count) : nil
    }

    private static func isTableSeparator(_ cell: String) -> Bool {
        let marker = cell.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: ":"))
        return marker.count >= 3 && marker.allSatisfy { $0 == "-" }
    }

    /// Ignore escaped pipes and pipes inside code spans when finding columns.
    private static func tableCells(_ line: String) -> [String]? {
        let source = line.trimmingCharacters(in: .whitespaces)
        guard !source.isEmpty else { return nil }
        let characters = Array(source)
        var cells: [String] = [], cell = "", index = 0, codeDelimiter = 0, foundPipe = false
        while index < characters.count {
            let character = characters[index]
            if character == "\\", index + 1 < characters.count {
                cell.append(character); cell.append(characters[index + 1]); index += 2; continue
            }
            if character == "`" {
                var count = 1
                while index + count < characters.count, characters[index + count] == "`" { count += 1 }
                if codeDelimiter == 0 { codeDelimiter = count }
                else if codeDelimiter == count { codeDelimiter = 0 }
                cell += String(repeating: "`", count: count); index += count; continue
            }
            if character == "|", codeDelimiter == 0 {
                cells.append(cell.trimmingCharacters(in: .whitespaces)); cell = ""; foundPipe = true
            } else { cell.append(character) }
            index += 1
        }
        guard foundPipe else { return nil }
        cells.append(cell.trimmingCharacters(in: .whitespaces))
        if source.first == "|", cells.first == "" { cells.removeFirst() }
        if cells.last == "" { cells.removeLast() }
        return cells.isEmpty ? nil : cells
    }

    private static func isDivider(_ line: String) -> Bool {
        let compact = line.filter { !$0.isWhitespace }
        guard compact.count >= 3, let first = compact.first, "*-_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    private static func setextLevel(_ line: String) -> Int? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let first = trimmed.first, first == "=" || first == "-",
              trimmed.allSatisfy({ $0 == first }) else { return nil }
        return first == "=" ? 1 : 2
    }

    private static func heading(_ line: String) -> Block? {
        let level = line.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(level) else { return nil }
        let rest = line.dropFirst(level)
        guard rest.isEmpty || rest.first?.isWhitespace == true else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        if text.last == "#" {
            let suffix = text.reversed().prefix(while: { $0 == "#" }).count
            let before = text.dropLast(suffix)
            if before.last?.isWhitespace == true { text = before.trimmingCharacters(in: .whitespaces) }
        }
        return Block(kind: .heading(level), text: text)
    }

    private static func indentation(_ line: String) -> Int {
        line.prefix(while: { $0 == " " || $0 == "\t" }).reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
    }

    private static func listItem(_ line: String) -> Block? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        var rest: Substring
        let marker: String
        if let first = trimmed.first, "-*+".contains(first),
           trimmed.dropFirst().first?.isWhitespace == true {
            marker = "•"; rest = trimmed.dropFirst()
        } else {
            let digits = trimmed.prefix(while: { $0.isASCII && $0.isNumber })
            guard !digits.isEmpty, digits.count <= 9 else { return nil }
            let tail = trimmed.dropFirst(digits.count)
            guard let punctuation = tail.first, punctuation == "." || punctuation == ")",
                  tail.dropFirst().first?.isWhitespace == true else { return nil }
            marker = String(digits) + "."; rest = tail.dropFirst()
        }
        rest = Substring(rest.trimmingCharacters(in: .whitespaces))
        var checked: Bool?
        if rest.hasPrefix("[ ] ") || rest.hasPrefix("[x] ") || rest.hasPrefix("[X] ") {
            checked = !rest.hasPrefix("[ ] "); rest = rest.dropFirst(4)
        }
        return Block(kind: .listItem(marker: marker, depth: min(indentation(line) / 2, 3), checked: checked), text: String(rest))
    }
}
