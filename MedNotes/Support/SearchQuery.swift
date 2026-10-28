import Foundation

/// What the notes search box says, as a tree. Pure and Foundation-only; the
/// parser never throws, because the text is parsed while it is being typed
/// (`tag:`, `"unclosed`, `(a OR`).
///
/// Syntax (Obsidian's, trimmed to what the notes list supports):
/// - words are ANDed; `OR` (upper case) joins alternatives; `( )` groups;
/// - `-term`, `-tag:x`, `-(a OR b)` exclude; a `-` inside a word is part of it;
/// - `"exact phrase"`;
/// - `tag:x` (hierarchical, a leading `#` is fine), `property:key`,
///   `property:key:value` and `[key]` / `[key:value]`, `patient:name`,
///   `linked:title` (a `[[ ]]` around it is fine);
/// - any other `name:value` is plain text.
///
/// Every word, phrase and patient name reaches the full-text index only as
/// letters and digits (`matchString`), never as raw user text, so no input
/// can produce a query FTS5 rejects.
struct SearchQuery: Equatable, Sendable {
    indirect enum Node: Equatable, Sendable {
        case and([Node])
        case or([Node])
        case not(Node)
        /// One token, matched as a prefix.
        case word(String)
        /// Tokens in order. `prefix` marks the last one as a prefix (a bare
        /// `C3-C4` still being typed); a closed `"quoted phrase"` is exact.
        case phrase([String], prefix: Bool)
        /// `WikiLinkParser.normalizedKey` of the tag, without the `#`.
        case tag(String)
        /// Both normalized; `value` nil means "has the property".
        case property(key: String, value: String?)
        case patient([String])
        /// Normalized title or name.
        case linked(String)
    }

    /// nil when the text holds nothing searchable (empty, `???`, `tag:`).
    let root: Node?

    static let maxLength = 2_000
    static let maxTokens = 200
    static let maxDepth = 32

    static func parse(_ raw: String) -> SearchQuery {
        var lexer = Lexer(Array(raw.prefix(maxLength)))
        var parser = Parser(tokens: lexer.run())
        return SearchQuery(root: parser.parse())
    }

    /// The words and phrases that count towards a match, left out under a
    /// negation: what a snippet should highlight.
    var highlightTerms: [String] {
        var out: [String] = []
        func walk(_ node: Node, negated: Bool) {
            switch node {
            case .and(let items), .or(let items):
                items.forEach { walk($0, negated: negated) }
            case .not(let inner):
                walk(inner, negated: !negated)
            case .word(let token):
                if !negated { out.append(token) }
            case .phrase(let tokens, _):
                if !negated { out.append(contentsOf: tokens) }
            case .tag, .property, .patient, .linked:
                break
            }
        }
        if let root { walk(root, negated: false) }
        return out
    }

    /// Whether answering needs the tag index.
    var usesTags: Bool { contains { if case .tag = $0 { return true } else { return false } } }

    func contains(_ test: (Node) -> Bool) -> Bool {
        func walk(_ node: Node) -> Bool {
            if test(node) { return true }
            switch node {
            case .and(let items), .or(let items): return items.contains(where: walk)
            case .not(let inner): return walk(inner)
            default: return false
            }
        }
        return root.map(walk) ?? false
    }

    /// The text for an FTS5 `MATCH`: quoted letters and digits only.
    /// nil when there are no tokens.
    static func matchString(tokens: [String], prefix: Bool) -> String? {
        let clean = tokens.flatMap { Schema.foldedTokens($0) }
        guard !clean.isEmpty else { return nil }
        return "\"\(clean.joined(separator: " "))\"" + (prefix ? "*" : "")
    }

    // MARK: - Lexer

    private enum Token: Equatable {
        case open, close, or, minus
        /// nil is a term with nothing to search (`???`, `tag:`); it still
        /// takes a `-` in front of it.
        case leaf(Node?)
    }

    private struct Lexer {
        let chars: [Character]
        var i = 0

        init(_ chars: [Character]) { self.chars = chars }

        mutating func run() -> [Token] {
            var out: [Token] = []
            while i < chars.count, out.count < SearchQuery.maxTokens {
                let c = chars[i]
                if c.isWhitespace { i += 1; continue }
                switch c {
                case "(": out.append(.open); i += 1
                case ")": out.append(.close); i += 1
                case "-":
                    // Only at the start of a term, and only with something after it.
                    if i + 1 < chars.count, !chars[i + 1].isWhitespace {
                        out.append(.minus)
                    }
                    i += 1
                case "\"":
                    out.append(.leaf(quoted()))
                case "[":
                    // `[[Title]]` pasted from a note is a link to that title;
                    // `[key:value]` is a property.
                    if i + 1 < chars.count, chars[i + 1] == "[" {
                        out.append(.leaf(Self.linked(operand(stopAtColon: false).0)))
                    } else {
                        out.append(.leaf(bracketProperty()))
                    }
                default:
                    out.append(word())
                }
            }
            return out
        }

        /// A closed quote is an exact phrase, an unclosed one (still being
        /// typed) matches by prefix.
        private mutating func quoted() -> Node? {
            let (text, closed) = readQuoted()
            return Self.phrase(Schema.splitTokens(text), prefix: !closed)
        }

        /// Consumes `"…"`; the closing quote is optional.
        private mutating func readQuoted() -> (String, closed: Bool) {
            i += 1   // opening quote
            var text = ""
            while i < chars.count {
                if chars[i] == "\"" { i += 1; return (text, true) }
                text.append(chars[i]); i += 1
            }
            return (text, false)
        }

        private mutating func bracketProperty() -> Node? {
            i += 1   // [
            var text = ""
            while i < chars.count, chars[i] != "]" { text.append(chars[i]); i += 1 }
            if i < chars.count { i += 1 }
            let parts = text.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard let key = parts.first else { return nil }
            return Self.property(key: String(key), value: parts.count > 1 ? String(parts[1]) : nil)
        }

        private mutating func word() -> Token {
            // `name:` for a known operator.
            var j = i
            while j < chars.count, chars[j].isLetter { j += 1 }
            if j < chars.count, chars[j] == ":", j > i {
                let name = String(chars[i..<j]).lowercased()
                if ["tag", "property", "patient", "linked"].contains(name) {
                    i = j + 1
                    return .leaf(operatorLeaf(name))
                }
            }
            let text = readBare(stopAtColon: false)
            if text == "OR" { return .or }
            return .leaf(Self.bare(text))
        }

        private mutating func operatorLeaf(_ name: String) -> Node? {
            switch name {
            case "property":
                let (key, _) = operand(stopAtColon: true)
                var value: String?
                if i < chars.count, chars[i] == ":" {
                    i += 1
                    value = operand(stopAtColon: false).0
                }
                return Self.property(key: key, value: value)
            case "tag":
                return Self.tag(operand(stopAtColon: false).0)
            case "patient":
                let tokens = Schema.splitTokens(operand(stopAtColon: false).0)
                return tokens.isEmpty ? nil : .patient(tokens)
            default:
                return Self.linked(operand(stopAtColon: false).0)
            }
        }

        /// A quoted or bare value right after an operator name.
        private mutating func operand(stopAtColon: Bool) -> (String, Bool) {
            if i < chars.count, chars[i] == "\"" {
                let (text, closed) = readQuoted()
                return (text, closed)
            }
            // `[[Title with spaces]]` is one value.
            if i + 1 < chars.count, chars[i] == "[", chars[i + 1] == "[" {
                var text = "[["
                i += 2
                while i < chars.count {
                    if chars[i] == "]", i + 1 < chars.count, chars[i + 1] == "]" {
                        text += "]]"; i += 2
                        break
                    }
                    text.append(chars[i]); i += 1
                }
                return (text, true)
            }
            return (readBare(stopAtColon: stopAtColon), true)
        }

        private mutating func readBare(stopAtColon: Bool) -> String {
            var text = ""
            while i < chars.count {
                let c = chars[i]
                if c.isWhitespace || c == "(" || c == ")" || (stopAtColon && c == ":") { break }
                text.append(c); i += 1
            }
            return text
        }

        // MARK: Leaves

        static func bare(_ text: String) -> Node? {
            let tokens = Schema.splitTokens(text)
            switch tokens.count {
            case 0: return nil
            case 1: return .word(tokens[0])
            default: return .phrase(tokens, prefix: true)
            }
        }

        static func phrase(_ tokens: [String], prefix: Bool) -> Node? {
            tokens.isEmpty ? nil : .phrase(tokens, prefix: prefix)
        }

        static func tag(_ raw: String) -> Node? {
            var text = Substring(raw.trimmingCharacters(in: .whitespacesAndNewlines))
            while text.hasPrefix("#") { text = text.dropFirst() }
            let key = WikiLinkParser.normalizedKey(String(text))
            return key.isEmpty ? nil : .tag(key)
        }

        static func property(key: String, value: String?) -> Node? {
            let keyNorm = WikiLinkParser.normalizedKey(key)
            guard !keyNorm.isEmpty else { return nil }
            let valueNorm = value.map(WikiLinkParser.normalizedKey).flatMap { $0.isEmpty ? nil : $0 }
            return .property(key: keyNorm, value: valueNorm)
        }

        static func linked(_ raw: String) -> Node? {
            var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.hasPrefix("[[") { text.removeFirst(2) }
            if text.hasSuffix("]]") { text.removeLast(2) }
            // A pasted `[[Title|alias]]`: the alias is only how it was shown.
            if let bar = text.firstIndex(of: "|") { text = String(text[..<bar]) }
            let key = WikiLinkParser.normalizedKey(text)
            return key.isEmpty ? nil : .linked(key)
        }
    }

    // MARK: - Parser

    private struct Parser {
        let tokens: [Token]
        var position = 0
        var depth = 0

        init(tokens: [Token]) { self.tokens = tokens }

        private var peek: Token? { position < tokens.count ? tokens[position] : nil }

        mutating func parse() -> Node? {
            var parts: [Node] = []
            while position < tokens.count {
                if let node = parseOr() { parts.append(node) }
                if peek == .close { position += 1 }   // a stray ")"
            }
            return Self.combineAnd(parts)
        }

        private mutating func parseOr() -> Node? {
            var branches: [Node] = []
            if let first = parseAnd() { branches.append(first) }
            while peek == .or {
                position += 1
                if let next = parseAnd() { branches.append(next) }
            }
            return branches.count > 1 ? .or(branches) : branches.first
        }

        private mutating func parseAnd() -> Node? {
            var items: [Node] = []
            while let token = peek, token != .or, token != .close {
                if let node = parseUnary() { items.append(node) }
            }
            return Self.combineAnd(items)
        }

        private mutating func parseUnary() -> Node? {
            guard let token = peek else { return nil }
            switch token {
            case .minus:
                position += 1
                return parseUnary().map { .not($0) }
            case .open:
                position += 1
                guard depth < SearchQuery.maxDepth else { return nil }   // too deep: ignore the bracket
                depth += 1
                let node = parseOr()
                depth -= 1
                if peek == .close { position += 1 }
                return node
            case .leaf(let node):
                position += 1
                return node
            case .or, .close:
                return nil   // belongs to the caller
            }
        }

        private static func combineAnd(_ items: [Node]) -> Node? {
            items.count > 1 ? .and(items) : items.first
        }
    }
}
