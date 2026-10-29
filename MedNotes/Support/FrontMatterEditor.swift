import Foundation

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
            guard expecting == nil,
                  let lines = FrontMatterYAML.render(key: key, value: value, comment: nil) else { return nil }
            let ending = lineEnding(of: ns)
            let at = ns.length > 0 && ns.character(at: 0) == 0xFEFF ? 1 : 0
            return Edit(
                range: NSRange(location: at, length: 0),
                replacement: "---" + ending + terminated(lines, ending) + "---" + ending)
        }
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
        let start = ns.length > 0 && ns.character(at: 0) == 0xFEFF ? 1 : 0
        var lines = ns.lines(from: start)
        guard let first = lines.next(), first.hasBreak else { return "\n" }
        return ns.substring(with: NSRange(location: first.contentsEnd, length: first.end - first.contentsEnd))
    }
}
