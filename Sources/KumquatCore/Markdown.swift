import Foundation

/// A compact CommonMark-flavoured Markdown → HTML renderer (headings, emphasis, links, images, lists,
/// task lists, block quotes, fenced code, GFM tables). Used for MD → HTML/DOCX/PDF/RTF without Pandoc.
public enum MarkdownRenderer {
    /// Renders Markdown. With a `title`, wraps the result in a styled standalone HTML document.
    public static func html(fromMarkdown markdown: String, title: String? = nil) -> String {
        let body = renderBody(markdown)
        guard let title else { return body }
        return Markup.document(title: title, body: body)
    }

    public static func renderBody(_ markdown: String) -> String {
        let lines = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        return renderBlocks(lines).joined(separator: "\n")
    }

    // MARK: Blocks

    static func renderBlocks(_ lines: [String]) -> [String] {
        var output: [String] = []
        var paragraph: [String] = []
        var i = 0

        func flush() {
            guard !paragraph.isEmpty else { return }
            let text = paragraph.joined(separator: "\n")
            output.append("<p>\(inline(text))</p>")
            paragraph = []
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                flush()
                i += 1
                continue
            }

            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flush()
                let fence = String(trimmed.prefix(3))
                let language = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(lines[i])
                    i += 1
                }
                i += 1
                let attribute = language.isEmpty ? "" : " class=\"language-\(Markup.escape(language))\""
                output.append("<pre><code\(attribute)>\(Markup.escape(code.joined(separator: "\n")))</code></pre>")
                continue
            }

            if !paragraph.isEmpty, matches(trimmed, "^(=+|-+)$") {
                let level = trimmed.hasPrefix("=") ? 1 : 2
                let text = paragraph.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
                output.append("<h\(level)>\(inline(text))</h\(level)>")
                paragraph = []
                i += 1
                continue
            }

            if let parsed = heading(trimmed) {
                flush()
                output.append("<h\(parsed.level)>\(inline(parsed.text))</h\(parsed.level)>")
                i += 1
                continue
            }

            if isRule(trimmed) {
                flush()
                output.append("<hr>")
                i += 1
                continue
            }

            if trimmed.hasPrefix(">") {
                flush()
                var quoted: [String] = []
                while i < lines.count {
                    let current = lines[i].trimmingCharacters(in: .whitespaces)
                    guard current.hasPrefix(">") else { break }
                    var rest = current.dropFirst()
                    if rest.hasPrefix(" ") { rest = rest.dropFirst() }
                    quoted.append(String(rest))
                    i += 1
                }
                output.append("<blockquote>\n\(renderBlocks(quoted).joined(separator: "\n"))\n</blockquote>")
                continue
            }

            if line.contains("|"), i + 1 < lines.count, isTableSeparator(lines[i + 1]) {
                flush()
                let alignments = tableCells(lines[i + 1]).map(alignment)
                var rows = [tableCells(line)]
                i += 2
                while i < lines.count, lines[i].contains("|"), !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                    rows.append(tableCells(lines[i]))
                    i += 1
                }
                output.append(table(rows, alignments: alignments))
                continue
            }

            if listItem(line) != nil {
                flush()
                let (html, next) = renderList(lines, from: i)
                output.append(html)
                i = next
                continue
            }

            paragraph.append(trimmed)
            i += 1
        }
        flush()
        return output
    }

    static func heading(_ line: String) -> (level: Int, text: String)? {
        let hashes = line.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashes) else { return nil }
        let rest = line.dropFirst(hashes)
        guard rest.isEmpty || rest.hasPrefix(" ") || rest.hasPrefix("\t") else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        // Optional closing hashes: "## Title ##".
        while text.hasSuffix("#") { text.removeLast() }
        return (hashes, text.trimmingCharacters(in: .whitespaces))
    }

    static func isRule(_ line: String) -> Bool {
        let compact = line.replacingOccurrences(of: " ", with: "")
        return matches(compact, "^(\\*{3,}|-{3,}|_{3,})$")
    }

    // MARK: Lists

    static func indentation(of line: String) -> Int {
        var count = 0
        for char in line {
            if char == " " { count += 1 } else if char == "\t" { count += 4 } else { break }
        }
        return count
    }

    static func dedent(_ line: String, by amount: Int) -> String {
        var removed = 0
        var index = line.startIndex
        while index < line.endIndex, removed < amount {
            let char = line[index]
            if char == " " { removed += 1 } else if char == "\t" { removed += 4 } else { break }
            index = line.index(after: index)
        }
        return String(line[index...])
    }

    static func listItem(_ line: String) -> (indent: Int, ordered: Bool, number: Int, content: String)? {
        let indent = indentation(of: line)
        let body = line.drop(while: { $0 == " " || $0 == "\t" })
        if let first = body.first, "-*+".contains(first) {
            let rest = body.dropFirst()
            guard rest.first == " " || rest.first == "\t" else { return nil }
            return (indent, false, 1, rest.trimmingCharacters(in: .whitespaces))
        }
        let digits = body.prefix(while: { $0.isASCII && $0.isNumber })
        guard (1...9).contains(digits.count), let number = Int(digits) else { return nil }
        let rest = body.dropFirst(digits.count)
        guard let delimiter = rest.first, delimiter == "." || delimiter == ")" else { return nil }
        let afterDelimiter = rest.dropFirst()
        guard afterDelimiter.first == " " || afterDelimiter.first == "\t" else { return nil }
        return (indent, true, number, afterDelimiter.trimmingCharacters(in: .whitespaces))
    }

    static func renderList(_ lines: [String], from start: Int) -> (String, Int) {
        guard let first = listItem(lines[start]) else { return ("", start + 1) }
        let base = first.indent
        var items: [[String]] = []
        var i = start
        var previousBlank = false

        while i < lines.count {
            let line = lines[i]
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                guard i + 1 < lines.count else { break }
                let next = lines[i + 1]
                if let item = listItem(next), item.indent <= base + 1, item.ordered == first.ordered {
                    previousBlank = true
                    i += 1
                    continue
                }
                if indentation(of: next) > base, !items.isEmpty {
                    items[items.count - 1].append("")
                    previousBlank = true
                    i += 1
                    continue
                }
                break
            }
            if let item = listItem(line), item.indent <= base + 1 {
                guard item.ordered == first.ordered else { break }
                items.append([item.content])
            } else if indentation(of: line) > base, !items.isEmpty {
                items[items.count - 1].append(dedent(line, by: base + 2))
            } else if !items.isEmpty, !previousBlank, heading(line.trimmingCharacters(in: .whitespaces)) == nil {
                // Lazy continuation of the item's paragraph.
                items[items.count - 1].append(line.trimmingCharacters(in: .whitespaces))
            } else {
                break
            }
            previousBlank = false
            i += 1
        }

        let tag = first.ordered ? "ol" : "ul"
        let startAttribute = first.ordered && first.number != 1 ? " start=\"\(first.number)\"" : ""
        let body = items.map(renderListItem).joined(separator: "\n")
        return ("<\(tag)\(startAttribute)>\n\(body)\n</\(tag)>", i)
    }

    static func renderListItem(_ lines: [String]) -> String {
        var textLines = [lines[0]]
        var index = 1
        while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).isEmpty, listItem(lines[index]) == nil {
            textLines.append(lines[index].trimmingCharacters(in: .whitespaces))
            index += 1
        }
        var text = textLines.joined(separator: "\n")
        var prefix = ""
        if text.hasPrefix("[ ] ") || text.hasPrefix("[x] ") || text.hasPrefix("[X] ") {
            let checked = !text.hasPrefix("[ ]")
            prefix = "<input type=\"checkbox\" disabled\(checked ? " checked" : "")> "
            text = String(text.dropFirst(4))
        }
        let nested = renderBlocks(Array(lines[index...])).joined(separator: "\n")
        return "<li>\(prefix)\(inline(text))\(nested.isEmpty ? "" : "\n" + nested)</li>"
    }

    // MARK: Tables

    static func isTableSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.contains("|") && trimmed.contains("-")
            && matches(trimmed, "^\\|?\\s*:?-+:?\\s*(\\|\\s*:?-+:?\\s*)*\\|?$")
    }

    static func tableCells(_ line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|") && !trimmed.hasSuffix("\\|") { trimmed.removeLast() }
        let placeholder = "\u{1}PIPE\u{1}"
        return trimmed.replacingOccurrences(of: "\\|", with: placeholder)
            .components(separatedBy: "|")
            .map { $0.replacingOccurrences(of: placeholder, with: "|").trimmingCharacters(in: .whitespaces) }
    }

    static func alignment(_ cell: String) -> String? {
        let left = cell.hasPrefix(":"), right = cell.hasSuffix(":")
        if left && right { return "center" }
        if right { return "right" }
        if left { return "left" }
        return nil
    }

    static func table(_ rows: [[String]], alignments: [String?]) -> String {
        func cells(_ row: [String], tag: String) -> String {
            row.enumerated().map { index, cell in
                let align = index < alignments.count ? alignments[index] : nil
                let style = align.map { " style=\"text-align: \($0)\"" } ?? ""
                return "<\(tag)\(style)>\(inline(cell))</\(tag)>"
            }.joined()
        }
        let head = "<thead><tr>\(cells(rows[0], tag: "th"))</tr></thead>"
        let body = rows.dropFirst().map { "<tr>\(cells($0, tag: "td"))</tr>" }.joined(separator: "\n")
        return "<table>\n\(head)\n<tbody>\n\(body)\n</tbody>\n</table>"
    }

    // MARK: Inline

    public static func inline(_ text: String) -> String {
        var stash: [String] = []
        func protect(_ html: String) -> String {
            stash.append(html)
            return "\u{0}\(stash.count - 1)\u{0}"
        }

        var working = replace(text, "`([^`]+)`") { protect("<code>\(Markup.escape($0[1]))</code>") }
        working = replace(working, "\\\\([\\\\`*_{}\\[\\]()#+\\-.!|~<>])") { protect(Markup.escape($0[1])) }
        working = Markup.escape(working)
        working = replace(working, "!\\[([^\\]]*)\\]\\(([^)\\s]+)(?:\\s+&quot;[^&]*&quot;)?\\)") {
            protect("<img src=\"\($0[2])\" alt=\"\($0[1])\">")
        }
        working = replace(working, "\\[([^\\]]+)\\]\\(([^)\\s]+)(?:\\s+&quot;[^&]*&quot;)?\\)") {
            "<a href=\"\(protect($0[2]))\">\($0[1])</a>"
        }
        working = replace(working, "&lt;((?:https?|mailto):[^\\s&]+)&gt;") {
            let url = protect($0[1])
            return "<a href=\"\(url)\">\(url)</a>"
        }
        working = regexReplace(working, "\\*\\*(?=\\S)(.+?)(?<=\\S)\\*\\*", "<strong>$1</strong>")
        working = regexReplace(working, "(?<![\\w_])__(?=\\S)(.+?)(?<=\\S)__(?![\\w_])", "<strong>$1</strong>")
        working = regexReplace(working, "~~(?=\\S)(.+?)(?<=\\S)~~", "<del>$1</del>")
        working = regexReplace(working, "(?<![*\\w])\\*(?=[^\\s*])(.+?)(?<=[^\\s*])\\*(?![*\\w])", "<em>$1</em>")
        working = regexReplace(working, "(?<![_\\w])_(?=[^\\s_])(.+?)(?<=[^\\s_])_(?![_\\w])", "<em>$1</em>")
        working = working.replacingOccurrences(of: "  \n", with: "<br>\n")

        // Restore in reverse so placeholders nested inside stashed HTML resolve too.
        for (index, html) in stash.enumerated().reversed() {
            working = working.replacingOccurrences(of: "\u{0}\(index)\u{0}", with: html)
        }
        return working
    }

    // MARK: Regex helpers

    static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    static func regexReplace(_ text: String, _ pattern: String, _ template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return text }
        let range = NSRange(location: 0, length: NSString(string: text).length)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
    }

    static func replace(_ text: String, _ pattern: String, _ transform: ([String]) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = NSString(string: text)
        var output = ""
        var last = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            output += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            let groups = (0..<match.numberOfRanges).map { index -> String in
                let range = match.range(at: index)
                return range.location == NSNotFound ? "" : ns.substring(with: range)
            }
            output += transform(groups)
            last = match.range.location + match.range.length
        }
        output += ns.substring(from: last)
        return output
    }
}
