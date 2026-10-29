import Foundation

/// A property's value, typed the way Obsidian's Properties panel types it.
enum PropertyValue: Equatable, Sendable {
    case text(String)
    /// A number that writes back exactly as it was read (no leading zeros,
    /// `+`, exponent or trailing `.0`); anything else is text.
    case number(String)
    case checkbox(Bool)
    /// `YYYY-MM-DD`.
    case date(String)
    /// `YYYY-MM-DDTHH:mm` or `YYYY-MM-DDTHH:mm:ss`, no zone.
    case dateTime(String)
    case list([String])
    /// A key with no value.
    case empty
    /// Something this parser does not edit: kept byte-for-byte, shown
    /// read-only.
    case unsupported

    var kind: String {
        switch self {
        case .text: return "text"
        case .number: return "number"
        case .checkbox: return "checkbox"
        case .date: return "date"
        case .dateTime: return "datetime"
        case .list: return "list"
        case .empty: return "empty"
        case .unsupported: return "unsupported"
        }
    }
}

/// One `key: value` entry of the front matter, with every line it spans.
struct Property: Equatable, Sendable, Identifiable {
    /// Stable across edits of other properties: the lower-cased key and which
    /// occurrence of it this is.
    let id: String
    /// As written.
    let key: String
    /// Lower-cased and trimmed; how special keys and duplicates are matched.
    let keyNorm: String
    let value: PropertyValue
    /// All of the entry's lines, line breaks included.
    let range: NSRange
    /// Those lines verbatim, so an edit can check nothing changed under it.
    let text: String
    /// The comment after the key line's value, without the `#`.
    let comment: String?
    /// Whether the editor may change or remove it.
    let isEditable: Bool
}

struct PropertySet: Equatable, Sendable {
    let block: FrontMatter.Block
    let properties: [Property]
    /// More entries than `FrontMatterYAML.maxProperties`; none is editable.
    let truncated: Bool

    func property(forKey key: String) -> Property? {
        properties.first { $0.key == key }
    }
}

/// A YAML subset: what Obsidian's Properties panel reads and writes.
///
/// Supported: `key: value` with plain, `"double"` and `'single'` scalars;
/// `[flow, lists]`; block lists; booleans, numbers, dates and datetimes;
/// trailing `# comments`; blank and comment lines between entries.
/// Everything else is `unsupported`, and unsupported entries are never
/// rewritten.
///
/// Every function here is total: bounds are checked, nothing traps on odd
/// input, and an entry that cannot be understood is kept as it is.
enum FrontMatterYAML {
    static let maxProperties = 200
    static let listKeys: Set<String> = ["tags", "aliases", "cssclasses"]
    /// Read-only spellings of the list keys.
    static let singularKeys: Set<String> = ["tag", "alias", "cssclass"]

    /// A value that starts with one of these is block text, an anchor, an alias,
    /// a tag, a mapping or a directive. It is shown read-only and never rewritten.
    private static let unsupportedValueStarts = Set("|>&*!{%@`".unicodeScalars)

    /// YAML indicators. A plain (unquoted) key or value cannot start with one, so
    /// the writer quotes such a value and refuses such a key.
    private static let plainScalarCannotStartWith = Set("-?:,[]{}#&*!|>'\"%@`".unicodeScalars)

    // MARK: - Parsing

    static func parse(_ text: String) -> PropertySet? {
        parse(text as NSString)
    }

    static func parse(_ ns: NSString) -> PropertySet? {
        guard let block = FrontMatter.properties(in: ns) else { return nil }
        let lines = readLines(ns, block.innerRange)

        var entries: [RawEntry] = []
        var gap: [Line] = []
        for line in lines {
            let kind = classify(line.content)
            switch kind {
            case .blank, .comment:
                gap.append(line)
            case .continuation:
                if entries.isEmpty {
                    entries.append(RawEntry(lines: [line], strayLines: true))
                } else {
                    if !gap.isEmpty {
                        entries[entries.count - 1].lines.append(contentsOf: gap)
                        entries[entries.count - 1].hasGap = true
                    }
                    entries[entries.count - 1].lines.append(line)
                }
                gap = []
            case .key:
                entries.append(RawEntry(lines: [line]))
                gap = []
            }
        }

        let truncated = entries.count > maxProperties
        let kept = Array(entries.prefix(maxProperties))
        var counts: [String: Int] = [:]
        for entry in kept {
            counts[entry.keyNorm, default: 0] += 1
        }
        var seen: [String: Int] = [:]
        var properties: [Property] = []
        for entry in kept where !entry.strayLines {
            let occurrence = seen[entry.keyNorm, default: 0]
            seen[entry.keyNorm] = occurrence + 1
            let duplicate = (counts[entry.keyNorm] ?? 0) > 1
            properties.append(makeProperty(entry, ns: ns, occurrence: occurrence,
                                           duplicate: duplicate, truncated: truncated))
        }
        // Stray continuation lines at the top belong to no key; nothing is
        // editable around them.
        if entries.contains(where: { $0.strayLines }) {
            properties = properties.map { $0.withEditable(false) }
        }
        return PropertySet(block: block, properties: properties, truncated: truncated)
    }

    // MARK: - Lines

    private struct Line {
        let range: NSRange
        let content: String
    }

    private struct RawEntry {
        var lines: [Line]
        var hasGap = false
        var strayLines = false

        var keyNorm: String {
            guard !strayLines, let first = lines.first,
                  let split = FrontMatterYAML.splitKey(first.content) else { return "" }
            return split.key.lowercased()
        }
    }

    private enum LineKind { case blank, comment, continuation, key }

    private static func readLines(_ ns: NSString, _ inner: NSRange) -> [Line] {
        ns.lines(in: inner).map { Line(range: $0.range, content: ns.substring(with: $0.contents)) }
    }

    private static func classify(_ content: String) -> LineKind {
        let trimmed = content.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return .blank }
        guard let first = content.unicodeScalars.first else { return .blank }
        if first == " " || first == "\t" { return .continuation }
        if first == "#" { return .comment }
        if first == "-", content.count == 1 || content.dropFirst().first == " " { return .continuation }
        return splitKey(content) == nil ? .continuation : .key
    }

    /// The key and the text after its colon, for a `key:` line.
    fileprivate static func splitKey(_ content: String) -> (key: String, rest: String)? {
        let scalars = Array(content.unicodeScalars)
        var i = 0
        while i < scalars.count {
            if scalars[i] == ":", i + 1 == scalars.count || scalars[i + 1] == " " || scalars[i + 1] == "\t" {
                guard i > 0 else { return nil }
                let key = String(String.UnicodeScalarView(scalars[0..<i]))
                    .trimmingCharacters(in: .whitespaces)
                let rest = String(String.UnicodeScalarView(scalars[(i + 1)...]))
                return key.isEmpty ? nil : (key, rest)
            }
            i += 1
        }
        return nil
    }

    // MARK: - Entries

    private static func makeProperty(
        _ entry: RawEntry, ns: NSString, occurrence: Int, duplicate: Bool, truncated: Bool
    ) -> Property {
        let first = entry.lines[0]
        let location = first.range.location
        let length = (entry.lines.last.map { NSMaxRange($0.range) } ?? NSMaxRange(first.range)) - location
        let range = NSRange(location: location, length: max(0, length))
        let split = splitKey(first.content)
        let key = split?.key ?? ""
        let keyNorm = key.lowercased()

        let (value, comment) = readValue(of: entry, key: split, keyNorm: keyNorm)
        let hasQuotedKey = key.hasPrefix("\"") || key.hasPrefix("'")
        let isEditable = value != .unsupported && !duplicate && !entry.hasGap && !truncated
            && !hasQuotedKey && !singularKeys.contains(keyNorm) && isValidKey(key)
        return Property(id: "\(keyNorm)#\(occurrence)", key: key, keyNorm: keyNorm, value: value, range: range,
                        text: ns.substring(with: range), comment: comment, isEditable: isEditable)
    }

    /// An entry's value, and the comment after it on the key line. What this
    /// parser does not understand comes back as `.unsupported`.
    private static func readValue(
        of entry: RawEntry, key split: (key: String, rest: String)?, keyNorm: String
    ) -> (value: PropertyValue, comment: String?) {
        guard let split else { return (.unsupported, nil) }
        let (valueText, comment) = splitComment(split.rest)
        let trimmed = valueText.trimmingCharacters(in: .whitespaces)
        let continuation = Array(entry.lines.dropFirst())

        // A key followed by indented lines: only a block list is understood.
        if !continuation.isEmpty {
            guard trimmed.isEmpty, let items = blockListItems(continuation) else { return (.unsupported, comment) }
            return (listValue(items, key: keyNorm), comment)
        }
        if trimmed.isEmpty {
            return (listKeys.contains(keyNorm) ? .list([]) : .empty, comment)
        }

        let value = scalarValue(trimmed)
        // `tags: a, b` is a list too, as are the singular spellings (read-only).
        guard listKeys.contains(keyNorm) || singularKeys.contains(keyNorm) else { return (value, comment) }
        switch value {
        case .list(let items): return (listValue(items, key: keyNorm), comment)
        case .unsupported: return (.unsupported, comment)
        default: return (listValue(splitCommas(plainText(trimmed)), key: keyNorm), comment)
        }
    }

    private static func listValue(_ items: [String], key: String) -> PropertyValue {
        .list(key == "tags" || key == "tag" ? items.map(stripHash) : items)
    }

    private static func stripHash(_ item: String) -> String {
        var s = Substring(item)
        while s.hasPrefix("#") { s = s.dropFirst() }
        return String(s)
    }

    private static func splitCommas(_ raw: String) -> [String] {
        raw.split(separator: ",", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// The text of a plain or quoted scalar, without its quotes.
    private static func plainText(_ trimmed: String) -> String {
        parseScalar(trimmed)?.text ?? trimmed
    }

    // MARK: - Scalars

    /// A scalar on the key line: quoted, flow list or plain.
    private static func scalarValue(_ trimmed: String) -> PropertyValue {
        guard let first = trimmed.unicodeScalars.first else { return .empty }
        if unsupportedValueStarts.contains(first) { return .unsupported }
        if first == "[" {
            guard let items = flowListItems(trimmed) else { return .unsupported }
            return .list(items)
        }
        guard let scalar = parseScalar(trimmed) else { return .unsupported }
        if scalar.quoted { return .text(scalar.text) }
        if scalar.text.contains(": ") { return .unsupported }   // a mapping, not a value
        return classifyPlain(scalar.text)
    }

    fileprivate static func classifyPlain(_ s: String) -> PropertyValue {
        let lower = s.lowercased()
        if lower == "true" { return .checkbox(true) }
        if lower == "false" { return .checkbox(false) }
        if s == "~" || lower == "null" { return .empty }
        if isStrictNumber(s) { return .number(s) }
        if isDate(s) { return .date(s) }
        if isDateTime(s) { return .dateTime(s) }
        return .text(s)
    }

    /// A quoted or plain scalar and whether it was quoted; nil when the text
    /// after a closing quote is not empty or a quote never closes.
    private static func parseScalar(_ trimmed: String) -> (text: String, quoted: Bool)? {
        switch trimmed.unicodeScalars.first {
        case nil: return ("", false)
        case "\"": return parseDoubleQuoted(trimmed).map { ($0, true) }
        case "'": return parseSingleQuoted(trimmed).map { ($0, true) }
        default: return (trimmed, false)
        }
    }

    /// The text inside `"..."`, escapes resolved; nil when the closing quote is
    /// missing, is followed by more text, or an escape is not understood.
    private static func parseDoubleQuoted(_ token: String) -> String? {
        let scalars = Array(token.unicodeScalars)
        var out = String.UnicodeScalarView()
        var i = 1   // past the opening quote
        while i < scalars.count {
            let c = scalars[i]
            if c == "\"" {
                return i == scalars.count - 1 ? String(out) : nil
            }
            if c == "\\" {
                guard let (escaped, next) = readEscape(scalars, at: i + 1) else { return nil }
                out.append(escaped)
                i = next
            } else {
                out.append(c)
                i += 1
            }
        }
        return nil
    }

    /// The character a backslash stands for and the index after it. `index` is
    /// just past the backslash.
    private static func readEscape(_ scalars: [Unicode.Scalar], at index: Int) -> (Unicode.Scalar, next: Int)? {
        guard index < scalars.count else { return nil }
        switch scalars[index] {
        case "n": return ("\n", index + 1)
        case "r": return ("\r", index + 1)
        case "t": return ("\t", index + 1)
        case "\"", "\\", "/": return (scalars[index], index + 1)
        case "u":   // \u followed by four hex digits
            guard index + 4 < scalars.count,
                  let code = UInt32(String(String.UnicodeScalarView(scalars[(index + 1)...(index + 4)])), radix: 16),
                  let scalar = Unicode.Scalar(code) else { return nil }
            return (scalar, index + 5)
        default: return nil
        }
    }

    /// The text inside `'...'`, where `''` stands for one quote; nil when the
    /// closing quote is missing or is followed by more text.
    private static func parseSingleQuoted(_ token: String) -> String? {
        let scalars = Array(token.unicodeScalars)
        var out = String.UnicodeScalarView()
        var i = 1   // past the opening quote
        while i < scalars.count {
            let c = scalars[i]
            if c == "'" {
                if i + 1 < scalars.count, scalars[i + 1] == "'" {
                    out.append("'")
                    i += 2
                    continue
                }
                return i == scalars.count - 1 ? String(out) : nil
            }
            out.append(c)
            i += 1
        }
        return nil
    }

    /// `[a, "b, c", d]` on one line.
    private static func flowListItems(_ trimmed: String) -> [String]? {
        guard trimmed.hasPrefix("["), trimmed.hasSuffix("]"), trimmed.count >= 2 else { return nil }
        let inner = Array(trimmed.unicodeScalars.dropFirst().dropLast())
        var items: [String] = []
        var current = String.UnicodeScalarView()
        var quote: Unicode.Scalar?
        var i = 0
        func flush() -> Bool {
            let raw = String(current).trimmingCharacters(in: .whitespaces)
            current = String.UnicodeScalarView()
            if raw.isEmpty { return true }
            guard let scalar = parseScalar(raw) else { return false }
            if !scalar.quoted, scalar.text.contains(": ") || scalar.text.hasPrefix("[") || scalar.text.hasPrefix("{") {
                return false
            }
            items.append(scalar.text)
            return true
        }
        while i < inner.count {
            let c = inner[i]
            if let q = quote {
                current.append(c)
                if q == "\"", c == "\\", i + 1 < inner.count {
                    i += 1
                    current.append(inner[i])
                } else if c == q {
                    quote = nil
                }
            } else if c == "\"" || c == "'" {
                quote = c
                current.append(c)
            } else if c == "," {
                guard flush() else { return nil }
            } else {
                current.append(c)
            }
            i += 1
        }
        guard quote == nil, flush() else { return nil }
        return items
    }

    /// `- item` lines (indented or not), comments and blanks allowed.
    private static func blockListItems(_ lines: [Line]) -> [String]? {
        var items: [String] = []
        for line in lines {
            let trimmed = line.content.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            guard trimmed == "-" || trimmed.hasPrefix("- ") else { return nil }
            let (valueText, _) = splitComment(String(trimmed.dropFirst()))
            let raw = valueText.trimmingCharacters(in: .whitespaces)
            if raw.isEmpty { continue }
            guard let scalar = parseScalar(raw) else { return nil }
            if !scalar.quoted, scalar.text.contains(": ") { return nil }
            items.append(scalar.text)
        }
        return items
    }

    /// Splits `value # comment`: the comment starts at a `#` that follows
    /// whitespace and is outside quotes.
    fileprivate static func splitComment(_ rest: String) -> (value: String, comment: String?) {
        let scalars = Array(rest.unicodeScalars)
        var quote: Unicode.Scalar?
        var i = 0
        while i < scalars.count {
            let c = scalars[i]
            if let q = quote {
                if q == "\"", c == "\\" { i += 1 } else if c == q { quote = nil }
            } else if c == "\"" || c == "'" {
                // A quote only opens a quoted scalar at the start of a value.
                let before = rest.unicodeScalars.prefix(i)
                if before.allSatisfy({ $0 == " " || $0 == "\t" || $0 == "[" || $0 == "," }) { quote = c }
            } else if c == "#", i == 0 || scalars[i - 1] == " " || scalars[i - 1] == "\t" {
                let value = String(String.UnicodeScalarView(scalars[0..<i]))
                let comment = String(String.UnicodeScalarView(scalars[(i + 1)...]))
                    .trimmingCharacters(in: .whitespaces)
                return (value, comment)
            }
            i += 1
        }
        return (rest, nil)
    }

    // MARK: - Typed text

    /// A number only if it writes back identically: no leading zeros, `+`,
    /// exponent or trailing zeros after the point; at most 15 digits. A phone
    /// number or `mrn: 00123` stays text.
    static func isStrictNumber(_ s: String) -> Bool {
        let scalars = Array(s.unicodeScalars)
        let isNegative = scalars.first == "-"
        var index = isNegative ? 1 : 0

        let integerStart = index
        while index < scalars.count, ASCII.isDigit(scalars[index]) { index += 1 }
        let integer = scalars[integerStart..<index]
        guard !integer.isEmpty else { return false }
        if integer.count > 1, integer.first == "0" { return false }                       // 007
        if isNegative, integer.first == "0", index == scalars.count { return false }      // -0

        var fractionCount = 0
        if index < scalars.count {
            guard scalars[index] == "." else { return false }
            index += 1
            let fractionStart = index
            while index < scalars.count, ASCII.isDigit(scalars[index]) { index += 1 }
            let fraction = scalars[fractionStart..<index]
            guard !fraction.isEmpty, fraction.last != "0" else { return false }           // 1. and 1.50
            fractionCount = fraction.count
        }
        return index == scalars.count && integer.count + fractionCount <= 15
    }

    /// `YYYY-MM-DD`, and a day that exists in that month.
    static func isDate(_ s: String) -> Bool {
        let parts = s.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, isDigits(parts[0], count: 4), isDigits(parts[1], count: 2),
              isDigits(parts[2], count: 2),
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              (1...12).contains(month), year >= 1 else { return false }
        return (1...daysIn(month: month, year: year)).contains(day)
    }

    /// `YYYY-MM-DDTHH:mm` or `YYYY-MM-DDTHH:mm:ss`.
    static func isDateTime(_ s: String) -> Bool {
        let halves = s.split(separator: "T", omittingEmptySubsequences: false)
        guard halves.count == 2, isDate(String(halves[0])) else { return false }
        let time = halves[1].split(separator: ":", omittingEmptySubsequences: false)
        guard time.count == 2 || time.count == 3, time.allSatisfy({ isDigits($0, count: 2) }),
              let hour = Int(time[0]), let minute = Int(time[1]),
              (0...23).contains(hour), (0...59).contains(minute) else { return false }
        if time.count == 3 { guard let second = Int(time[2]), (0...59).contains(second) else { return false } }
        return true
    }

    /// Exactly `count` characters, all ASCII digits.
    private static func isDigits(_ part: Substring, count: Int) -> Bool {
        part.count == count && part.unicodeScalars.allSatisfy(ASCII.isDigit)
    }

    private static func daysIn(month: Int, year: Int) -> Int {
        let isLeapYear = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
        return [31, isLeapYear ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][month - 1]
    }

    // MARK: - Writing

    /// Characters that end a line (to `NSString`, so to every reader here) or
    /// cannot sit raw in a value: C0 controls, DEL, NEL, LS and PS.
    private static func isLineOrControl(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value < 0x20 || scalar.value == 0x7F || scalar.value == 0x85
            || scalar.value == 0x2028 || scalar.value == 0x2029
    }

    /// Whether a key can be written as it is. Anything else would need
    /// quoting, which this editor does not do.
    static func isValidKey(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed == key, let first = trimmed.unicodeScalars.first else { return false }
        if plainScalarCannotStartWith.contains(first) { return false }
        if trimmed.contains(":") || trimmed.contains(" #") { return false }
        return !trimmed.unicodeScalars.contains(where: isLineOrControl)
    }

    /// Whether a text value must be quoted to read back as the same text.
    static func needsQuotes(_ s: String) -> Bool {
        if s.isEmpty { return true }
        if s != s.trimmingCharacters(in: .whitespaces) { return true }
        if let first = s.unicodeScalars.first, plainScalarCannotStartWith.contains(first) { return true }
        if s.contains(": ") || s.contains(" #") || s.hasSuffix(":") { return true }
        if s.unicodeScalars.contains(where: isLineOrControl) { return true }
        if ["yes", "no", "on", "off", "y", "n"].contains(s.lowercased()) { return true }
        return classifyPlain(s) != .text(s)
    }

    static func quoted(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if isLineOrControl(scalar) {
                    out += String(format: "\\u%04X", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    static func scalarText(_ s: String) -> String {
        needsQuotes(s) ? quoted(s) : s
    }

    /// The lines (without breaks) that write `key: value`, or nil for a value
    /// this editor does not write.
    static func render(key: String, value: PropertyValue, comment: String?) -> [String]? {
        guard isValidKey(key) else { return nil }
        let suffix = comment.map { $0.isEmpty ? " #" : " # \($0)" } ?? ""
        switch value {
        case .text(let s):
            return ["\(key): \(scalarText(s))\(suffix)"]
        case .number(let n):
            return ["\(key): \(isStrictNumber(n) ? n : quoted(n))\(suffix)"]
        case .checkbox(let b):
            return ["\(key): \(b ? "true" : "false")\(suffix)"]
        case .date(let d):
            return ["\(key): \(isDate(d) ? d : quoted(d))\(suffix)"]
        case .dateTime(let d):
            return ["\(key): \(isDateTime(d) ? d : quoted(d))\(suffix)"]
        case .list(let items):
            if items.isEmpty { return ["\(key): []\(suffix)"] }
            return ["\(key):\(suffix)"] + items.map { "  - \(scalarText($0))" }
        case .empty:
            return ["\(key):\(suffix)"]
        case .unsupported:
            return nil
        }
    }
}

private extension Property {
    func withEditable(_ editable: Bool) -> Property {
        Property(id: id, key: key, keyNorm: keyNorm, value: value, range: range, text: text,
                 comment: comment, isEditable: editable && isEditable)
    }
}
