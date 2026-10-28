import Foundation

/// Which part of a note an embed or a link target points at: the section a
/// heading opens, or the block a `^id` ends. Pure and Foundation-only.
///
/// Headings are the ones `NoteMetadata` reads (the index resolves `#heading`
/// with the same rule), so a section here is a section there.
enum MarkdownSections {
    /// The text from a heading's line to the line before the next heading of the
    /// same or a higher level (or the end of the note), by heading text.
    /// `path` is `["Plan"]` for `[[Note#Plan]]` and `["Plan", "Doses"]` for
    /// `[[Note#Plan#Doses]]`, where "Doses" must sit under a "Plan".
    static func headingSection(path: [String], in text: String) -> NSRange? {
        let keys = path.map(WikiLinkParser.normalizedKey).filter { !$0.isEmpty }
        guard let wanted = keys.last else { return nil }
        let length = (text as NSString).length
        let headings = NoteMetadata.scan(text).headings
        for (index, heading) in headings.enumerated() where heading.key == wanted {
            guard ancestorsMatch(Array(keys.dropLast()), headings: headings, before: index) else { continue }
            var end = length
            for next in headings[(index + 1)...] where next.level <= heading.level {
                end = next.offset
                break
            }
            return NSRange(location: heading.offset, length: max(0, end - heading.offset))
        }
        return nil
    }

    /// Each earlier key is the nearest heading above with a lower level than
    /// the one after it.
    private static func ancestorsMatch(_ keys: [String], headings: [NoteMetadata.Heading], before index: Int) -> Bool {
        var level = headings[index].level
        var cursor = index - 1
        for key in keys.reversed() {
            var found = false
            while cursor >= 0 {
                let candidate = headings[cursor]
                cursor -= 1
                if candidate.level < level, candidate.key == key {
                    level = candidate.level
                    found = true
                    break
                }
            }
            if !found { return false }
        }
        return true
    }

    /// The block a `^id` ends: the list item, paragraph or heading that carries
    /// it. A list item counts with its nested items.
    static func blockExtent(id: String, in document: MarkdownDocument) -> NSRange? {
        func search(_ blocks: [MarkdownBlock]) -> NSRange? {
            for block in blocks {
                switch block.kind {
                case .list(let list):
                    for item in list.items {
                        if item.blockID == id { return item.range }
                        if let found = search(item.blocks) { return found }
                    }
                case .quote(let children):
                    if let found = search(children) { return found }
                case .callout(let callout):
                    if let found = search(callout.children) { return found }
                default:
                    break
                }
                if block.blockID == id { return block.range }
            }
            return nil
        }
        return search(document.blocks)
    }
}
