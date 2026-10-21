import Foundation

/// CSV/TSV parsing and the text formats tables can be written as.
public enum Table {
    /// RFC 4180 parser: quoted fields, escaped quotes, embedded delimiters and newlines.
    public static func parse(_ text: String, delimiter: Character = ",") -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var fieldStarted = false
        var iterator = (text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text).makeIterator()
        var pending: Character? = nil

        func endField() {
            row.append(field)
            field = ""
            fieldStarted = false
        }
        func endRow() {
            endField()
            rows.append(row)
            row = []
        }

        while true {
            let char: Character
            if let saved = pending {
                char = saved
                pending = nil
            } else if let next = iterator.next() {
                char = next
            } else {
                break
            }
            if inQuotes {
                if char == "\"" {
                    if let next = iterator.next() {
                        if next == "\"" { field.append("\"") } else { inQuotes = false; pending = next }
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(char)
                }
                continue
            }
            switch char {
            case "\"" where !fieldStarted && field.isEmpty:
                inQuotes = true
                fieldStarted = true
            case delimiter:
                endField()
            case "\n", "\r", "\r\n":
                endRow()
            default:
                field.append(char)
                fieldStarted = true
            }
        }
        if fieldStarted || !field.isEmpty || !row.isEmpty { endRow() }
        // Drop blank lines.
        return rows.filter { !($0.count == 1 && $0[0].isEmpty) }
    }

    public static func serialize(_ rows: [[String]], delimiter: Character = ",") -> String {
        rows.map { row in
            row.map { field in
                let needsQuotes = field.contains(delimiter) || field.contains("\"") || field.contains("\n") || field.contains("\r")
                return needsQuotes ? "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : field
            }.joined(separator: String(delimiter))
        }.joined(separator: "\n") + "\n"
    }

    /// Array of objects keyed by the header row, keys kept in column order.
    public static func json(from rows: [[String]]) -> String {
        guard let header = rows.first else { return "[]\n" }
        let records = rows.dropFirst().map { row -> String in
            let pairs = header.enumerated().map { index, key in
                "    \(jsonString(key)): \(jsonString(index < row.count ? row[index] : ""))"
            }
            return "  {\n" + pairs.joined(separator: ",\n") + "\n  }"
        }
        return records.isEmpty ? "[]\n" : "[\n" + records.joined(separator: ",\n") + "\n]\n"
    }

    public static func markdown(from rows: [[String]]) -> String {
        guard let header = rows.first else { return "" }
        let width = rows.map(\.count).max() ?? header.count
        func line(_ row: [String]) -> String {
            let cells = (0..<width).map { $0 < row.count ? row[$0] : "" }
                .map { $0.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: "<br>") }
            return "| " + cells.joined(separator: " | ") + " |"
        }
        let separator = "| " + Array(repeating: "---", count: width).joined(separator: " | ") + " |"
        return ([line(header), separator] + rows.dropFirst().map(line)).joined(separator: "\n") + "\n"
    }

    public static func html(from rows: [[String]], title: String = "") -> String {
        guard let header = rows.first else { return "" }
        func cells(_ row: [String], tag: String) -> String {
            row.map { "<\(tag)>\(Markup.escape($0))</\(tag)>" }.joined()
        }
        let body = rows.dropFirst().map { "<tr>\(cells($0, tag: "td"))</tr>" }.joined(separator: "\n")
        let table = "<table>\n<thead><tr>\(cells(header, tag: "th"))</tr></thead>\n<tbody>\n\(body)\n</tbody>\n</table>"
        return Markup.document(title: title, body: table)
    }

    /// Rows from a JSON array of objects (or of arrays). Nested values are written as compact JSON.
    public static func rows(fromJSON data: Data) throws -> [[String]] {
        let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        let items: [Any]
        if let array = object as? [Any] {
            items = array
        } else if let dictionary = object as? [String: Any] {
            items = [dictionary]
        } else {
            throw KumquatError.invalidInput("JSON must be an array of objects to become a table.")
        }
        if items.allSatisfy({ $0 is [Any] }) {
            return items.map { ($0 as! [Any]).map(cellText) }
        }
        var keys: [String] = []
        var seen = Set<String>()
        for case let record as [String: Any] in items {
            for key in record.keys.sorted() where seen.insert(key).inserted { keys.append(key) }
        }
        guard !keys.isEmpty else { throw KumquatError.invalidInput("JSON contains no objects to tabulate.") }
        let body = items.map { item -> [String] in
            let record = item as? [String: Any] ?? [:]
            return keys.map { record[$0].map(cellText) ?? "" }
        }
        return [keys] + body
    }

    static func cellText(_ value: Any) -> String {
        switch value {
        case let string as String: return string
        case is NSNull: return ""
        case let number as NSNumber:
            #if canImport(Darwin)
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
            #endif
            return number.stringValue
        default:
            if JSONSerialization.isValidJSONObject(value),
               let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) {
                return String(decoding: data, as: UTF8.self)
            }
            return "\(value)"
        }
    }

    public static func jsonString(_ text: String) -> String {
        var result = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            default:
                if scalar.value < 0x20 {
                    result += String(format: "\\u%04x", scalar.value)
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result + "\""
    }
}

/// Small HTML helpers shared by the Markdown and table writers.
public enum Markup {
    public static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    static let stylesheet = """
    body { font-family: -apple-system, "Helvetica Neue", Helvetica, Arial, sans-serif; font-size: 12pt; line-height: 1.45; max-width: 46em; margin: 2em auto; padding: 0 1em; color: #1d1d1f; }
    pre, code { font-family: Menlo, Monaco, monospace; font-size: 10.5pt; }
    pre { background: #f5f5f7; padding: 0.8em; border-radius: 6px; overflow-x: auto; }
    blockquote { border-left: 3px solid #d2d2d7; margin-left: 0; padding-left: 1em; color: #555; }
    table { border-collapse: collapse; }
    th, td { border: 1px solid #d2d2d7; padding: 4px 8px; text-align: left; }
    th { background: #f5f5f7; }
    """

    public static func document(title: String, body: String) -> String {
        """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <title>\(escape(title))</title>
        <style>
        \(stylesheet)
        </style>
        </head>
        <body>
        \(body)
        </body>
        </html>

        """
    }
}
