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
        var out: [Line] = []
        var location = inner.location
        let end = NSMaxRange(inner)
        while location < end {
            var lineEnd = 0, contentsEnd = 0
            ns.getLineStart(nil, end: &lineEnd, contentsEnd: &contentsEnd,
                            for: NSRange(location: location, length: 0))
            let stop = min(lineEnd, end)
            let contents = max(location, min(contentsEnd, end))
            out.append(Line(
                range: NSRange(location: location, length: stop - location),
                content: ns.substring(with: NSRange(location: location, length: contents - location))))
            if lineEnd <= location { break }
            location = lineEnd
        }
        return out
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
        let verbatim = ns.substring(with: range)
        let split = splitKey(first.content)
        let key = split?.key ?? ""
        let keyNorm = key.lowercased()
        let id = "\(keyNorm)#\(occurrence)"

        func property(_ value: PropertyValue, comment: String? = nil, supported: Bool = true) -> Property {
            let quotedKey = key.hasPrefix("\"") || key.hasPrefix("'")
            let editable = supported && !duplicate && !entry.hasGap && !truncated && !quotedKey
                && !singularKeys.contains(keyNorm) && isValidKey(key)
            return Property(id: id, key: key, keyNorm: keyNorm, value: value, range: range,
                            text: verbatim, comment: comment, isEditable: editable)
        }

        guard let split else { return property(.unsupported, supported: false) }
        let (valueText, comment) = splitComment(split.rest)
        let trimmed = valueText.trimmingCharacters(in: .whitespaces)
        let continuation = Array(entry.lines.dropFirst())

        // A key followed by indented lines: only a block list is understood.
        if !continuation.isEmpty {
            guard trimmed.isEmpty, let items = blockListItems(continuation) else {
                return property(.unsupported, comment: comment, supported: false)
            }
            return property(listValue(items, key: keyNorm), comment: comment)
        }

        if trimmed.isEmpty {
            return property(listKeys.contains(keyNorm) ? .list([]) : .empty, comment: comment)
        }
        guard let value = scalarValue(trimmed) else {
            return property(.unsupported, comment: comment, supported: false)
        }
        if listKeys.contains(keyNorm) || singularKeys.contains(keyNorm) {
            switch value {
            case .list(let items): return property(listValue(items, key: keyNorm), comment: comment)
            case .unsupported: return property(value, comment: comment, supported: false)
            default:
                let raw = plainText(trimmed)
                return property(listValue(splitCommas(raw), key: keyNorm), comment: comment)
            }
        }
        return property(value, comment: comment, supported: value != .unsupported)
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
    private static func scalarValue(_ trimmed: String) -> PropertyValue? {
        guard let first = trimmed.unicodeScalars.first else { return .empty }
        if "|>&*!{%@`".unicodeScalars.contains(first) { return .unsupported }
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
        guard let first = trimmed.unicodeScalars.first else { return ("", false) }
        let scalars = Array(trimmed.unicodeScalars)
        if first == "\"" {
            var out = String.UnicodeScalarView()
            var i = 1
            while i < scalars.count {
                let c = scalars[i]
                if c == "\"" {
                    return i == scalars.count - 1 ? (String(out), true) : nil
                }
                if c == "\\" {
                    i += 1
                    guard i < scalars.count else { return nil }
                    switch scalars[i] {
                    case "n": out.append("\n")
                    case "r": out.append("\r")
                    case "t": out.append("\t")
                    case "\"": out.append("\"")
                    case "\\": out.append("\\")
                    case "/": out.append("/")
                    case "u":
                        guard i + 4 < scalars.count,
                              let code = UInt32(String(String.UnicodeScalarView(scalars[(i + 1)...(i + 4)])), radix: 16),
                              let scalar = Unicode.Scalar(code) else { return nil }
                        out.append(scalar)
                        i += 4
                    default: return nil
                    }
                } else {
                    out.append(c)
                }
                i += 1
            }
            return nil
        }
        if first == "'" {
            var out = String.UnicodeScalarView()
            var i = 1
            while i < scalars.count {
                let c = scalars[i]
                if c == "'" {
                    if i + 1 < scalars.count, scalars[i + 1] == "'" {
                        out.append("'")
                        i += 2
                        continue
                    }
                    return i == scalars.count - 1 ? (String(out), true) : nil
                }
                out.append(c)
                i += 1
            }
            return nil
        }
        return (trimmed, false)
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
        var chars = Array(s.unicodeScalars)
        guard !chars.isEmpty else { return false }
        if chars[0] == "-" { chars.removeFirst() }
        guard !chars.isEmpty else { return false }
        var intPart: [Unicode.Scalar] = []
        var index = 0
        while index < chars.count, chars[index].value >= 0x30, chars[index].value <= 0x39 {
            intPart.append(chars[index])
            index += 1
        }
        guard !intPart.isEmpty else { return false }
        if intPart.count > 1, intPart[0] == "0" { return false }
        if s.hasPrefix("-"), intPart == ["0"], index == chars.count { return false }   // "-0"
        var fraction: [Unicode.Scalar] = []
        if index < chars.count {
            guard chars[index] == ".", index + 1 < chars.count else { return false }
            index += 1
            while index < chars.count, chars[index].value >= 0x30, chars[index].value <= 0x39 {
                fraction.append(chars[index])
                index += 1
            }
            guard !fraction.isEmpty, fraction.last != "0" else { return false }
        }
        return index == chars.count && intPart.count + fraction.count <= 15
    }

    static func isDate(_ s: String) -> Bool {
        let parts = s.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.unicodeScalars.allSatisfy { $0.value >= 0x30 && $0.value <= 0x39 } }),
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              (1...12).contains(m), y >= 1 else { return false }
        let leap = (y % 4 == 0 && y % 100 != 0) || y % 400 == 0
        let days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][m - 1]
        return (1...days).contains(d)
    }

    static func isDateTime(_ s: String) -> Bool {
        let halves = s.split(separator: "T", omittingEmptySubsequences: false)
        guard halves.count == 2, isDate(String(halves[0])) else { return false }
        let time = halves[1].split(separator: ":", omittingEmptySubsequences: false)
        guard time.count == 2 || time.count == 3,
              time.allSatisfy({ $0.count == 2 && $0.unicodeScalars.allSatisfy { $0.value >= 0x30 && $0.value <= 0x39 } }),
              let h = Int(time[0]), let mi = Int(time[1]), (0...23).contains(h), (0...59).contains(mi)
        else { return false }
        if time.count == 3 { guard let sec = Int(time[2]), (0...59).contains(sec) else { return false } }
        return true
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
        if "-?:,[]{}#&*!|>'\"%@`".unicodeScalars.contains(first) { return false }
        if trimmed.contains(":") || trimmed.contains(" #") { return false }
        return !trimmed.unicodeScalars.contains(where: isLineOrControl)
    }

    /// Whether a text value must be quoted to read back as the same text.
    static func needsQuotes(_ s: String) -> Bool {
        if s.isEmpty { return true }
        if s != s.trimmingCharacters(in: .whitespaces) { return true }
        if let first = s.unicodeScalars.first, "-?:,[]{}#&*!|>'\"%@`".unicodeScalars.contains(first) { return true }
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

// MARK: - Editor

/// Changes one property of a note's front matter and nothing else: the edit
/// is a single splice (`range` replaced by `replacement`), so every other
/// byte of the note is untouched, line endings included.
enum FrontMatterEditor {
    struct Edit: Equatable, Sendable {
        /// In the text the edit was computed from, UTF-16 units.
        let range: NSRange
        let replacement: String
    }

    enum Operation: Equatable, Sendable {
        /// Changes an existing property, or adds it when there is none.
        case set(key: String, value: PropertyValue)
        case remove(key: String)
    }

    /// The splice for `operation`, or nil when it cannot be made safely: the
    /// property is not editable (unsupported, duplicate, quoted key), the key
    /// or value cannot be written, or `expecting` is given and the property's
    /// lines are no longer exactly that text.
    static func edit(_ operation: Operation, in text: String, expecting: String? = nil) -> Edit? {
        let ns = text as NSString
        let parsed = FrontMatterYAML.parse(ns)
        switch operation {
        case .remove(let key):
            guard let parsed, !parsed.truncated, let property = parsed.property(forKey: key),
                  property.isEditable, matches(property, expecting) else { return nil }
            return Edit(range: property.range, replacement: "")

        case .set(let key, let value):
            if let parsed {
                guard !parsed.truncated else { return nil }
                if let property = parsed.property(forKey: key) {
                    guard property.isEditable, matches(property, expecting),
                          let lines = FrontMatterYAML.render(key: key, value: value, comment: property.comment)
                    else { return nil }
                    return Edit(range: property.range, replacement: terminated(lines, parsed.block.lineEnding))
                }
                // `Status` beside an existing `status` would make both duplicates,
                // and so both read-only.
                guard expecting == nil, !parsed.properties.contains(where: { $0.keyNorm == key.lowercased() }),
                      let lines = FrontMatterYAML.render(key: key, value: value, comment: nil) else { return nil }
                return Edit(
                    range: NSRange(location: parsed.block.closeLine.location, length: 0),
                    replacement: terminated(lines, parsed.block.lineEnding))
            }
            // No properties block: write one at the top, after a byte-order mark.
            // Unless there is one this reader cannot follow: a second block above
            // it would turn the real one into body text.
            guard expecting == nil, !hasUnreadableBlock(in: ns),
                  let lines = FrontMatterYAML.render(key: key, value: value, comment: nil) else { return nil }
            let ending = lineEnding(of: ns)
            let at = ns.length > 0 && ns.character(at: 0) == 0xFEFF ? 1 : 0
            return Edit(
                range: NSRange(location: at, length: 0),
                replacement: "---" + ending + terminated(lines, ending) + "---" + ending)
        }
    }

    /// A pair of `---` lines at the top that holds a `key:` line and still did not
    /// read as properties: YAML this editor cannot follow (a quoted value that
    /// runs over several lines from column 0, a line separator inside a value),
    /// so it cannot say where a property would go. Prose between two rules with no
    /// `key:` line is ordinary text, not this.
    static func hasUnreadableBlock(in text: String) -> Bool {
        hasUnreadableBlock(in: text as NSString)
    }

    static func hasUnreadableBlock(in ns: NSString) -> Bool {
        guard FrontMatterYAML.parse(ns) == nil, let block = FrontMatter.block(in: ns) else { return false }
        return ns.range(
            of: #"(?m)^[^\s#-][^:\n\r]*:([ \t]|$)"#, options: .regularExpression,
            range: block.innerRange).location != NSNotFound
    }

    static func apply(_ edit: Edit, to text: String) -> String {
        let ns = text as NSString
        guard edit.range.location >= 0, NSMaxRange(edit.range) <= ns.length else { return text }
        return ns.replacingCharacters(in: edit.range, with: edit.replacement)
    }

    // MARK: - Private

    private static func matches(_ property: Property, _ expecting: String?) -> Bool {
        expecting == nil || property.text == expecting
    }

    private static func terminated(_ lines: [String], _ ending: String) -> String {
        lines.map { $0 + ending }.joined()
    }

    /// The first line break in the text, or LF.
    private static func lineEnding(of ns: NSString) -> String {
        guard ns.length > 0 else { return "\n" }
        var lineEnd = 0, contentsEnd = 0
        let start = ns.character(at: 0) == 0xFEFF ? 1 : 0
        guard start < ns.length else { return "\n" }
        ns.getLineStart(nil, end: &lineEnd, contentsEnd: &contentsEnd,
                        for: NSRange(location: start, length: 0))
        return lineEnd > contentsEnd
            ? ns.substring(with: NSRange(location: contentsEnd, length: lineEnd - contentsEnd))
            : "\n"
    }
}
