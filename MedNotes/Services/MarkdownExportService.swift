import Foundation

/// One-time, deliberate export of notes as plaintext Markdown.
///
/// This replaces the retired continuous Vault mirror. The database is
/// authoritative and stays authoritative: this service only reads, writes the
/// chosen directory for the duration of the call, and never keeps a bookmark,
/// watcher or preference. The caller must show the count and kinds of records
/// leaving the app and label the result as plaintext before invoking it.
actor MarkdownExportService {
    struct ExportReport: Sendable, Equatable {
        var notesWritten = 0
        var bytesWritten = 0
        var failures: [String] = []
        /// The task was cancelled before every note was written.
        var wasCancelled = false
    }

    /// Every note, encoded as it will be written, before anything is: the
    /// caller records what is about to leave the app first.
    struct Prepared: Sendable {
        fileprivate let files: [(id: String, text: String)]
        var noteCount: Int { files.count }
        var byteCount: Int { files.reduce(0) { $0 + $1.text.utf8.count } }
    }

    private let db: Database

    init(db: Database) {
        self.db = db
    }

    /// Writes every note to `directory` as `{noteId}.md`. Files are written
    /// atomically. The directory is used only inside this call.
    func export(to directory: URL) async throws -> ExportReport {
        let prepared = try await prepare()
        return try write(prepared, to: directory)
    }

    /// Reads and encodes every note; writes nothing.
    func prepare() async throws -> Prepared {
        let notes = try await db.loadAllNotes()
        return Prepared(files: notes.map { (id: $0.id.uuidString, text: Self.encode(note: $0)) })
    }

    /// Writes `prepared` to `directory` as `{noteId}.md`, each file atomically.
    /// Once the task is cancelled no further file is started, and
    /// `wasCancelled` says so; the files already written stay. `didWrite` is
    /// told after each file; tests use it to cancel part-way.
    func write(_ prepared: Prepared, to directory: URL,
               didWrite: (() -> Void)? = nil) throws -> ExportReport {
        var report = ExportReport()
        guard !Task.isCancelled else {
            report.wasCancelled = true
            return report
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for file in prepared.files {
            guard !Task.isCancelled else {
                report.wasCancelled = true
                break
            }
            do {
                let url = directory.appendingPathComponent(file.id + ".md")
                try file.text.write(to: url, atomically: true, encoding: .utf8)
                report.notesWritten += 1
                report.bytesWritten += file.text.utf8.count
                didWrite?()
            } catch {
                report.failures.append("\(file.id): \(error.localizedDescription)")
            }
        }
        return report
    }

    // MARK: - Encoding (pure)

    static func encode(note: Note) -> String {
        let tags = "[" + note.tags.map { yamlEscape($0) }.joined(separator: ", ") + "]"
        let patients = "[" + note.mentionedPatients.map { yamlEscape($0.uuidString) }.joined(separator: ", ") + "]"
        let frontMatter = """
        ---
        id: \(yamlEscape(note.id.uuidString))
        title: \(yamlEscape(note.title))
        created: \(LenientDate.encodeSQL(note.createdAt))
        updated: \(LenientDate.encodeSQL(note.updatedAt))
        tags: \(tags)
        patients: \(patients)
        pinned: \(note.isPinned ? "true" : "false")
        ---

        """
        return frontMatter + "\n" + note.content
    }

    /// Escapes a string for double-quoted YAML. Keep simple and deterministic.
    static func yamlEscape(_ raw: String) -> String {
        let escaped = raw
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            // A bare CR is a line break to YAML and would split the value
            // across lines in the front matter.
            .replacingOccurrences(of: "\r", with: "\\r")
        return "\"\(escaped)\""
    }

    static func yamlUnescape(_ raw: String) -> String {
        guard raw.count >= 2, raw.hasPrefix("\""), raw.hasSuffix("\"") else { return raw }
        let inner = String(raw.dropFirst().dropLast())
        var out = ""
        var iterating = inner.makeIterator()
        while let ch = iterating.next() {
            if ch == "\\" {
                switch iterating.next() {
                case "n": out.append("\n")
                case "r": out.append("\r")
                case "\"": out.append("\"")
                case "\\": out.append("\\")
                case let other:
                    out.append("\\")
                    if let other { out.append(other) }
                }
            } else {
                out.append(ch)
            }
        }
        return out
    }
}

/// Reads the retired `Vault/` mirror once, at upgrade, so the user can decide
/// what to do with notes that exist only there before the mirror is disabled
/// and deleted.
///
/// Every parsed file is classified against the database:
///   - `databaseOnly`  — a DB note with no vault file
///   - `vaultOnly`     — a vault file whose note is not in the DB
///   - `divergent`     — both exist and their content differs
///   - `identical`     — both exist and match
enum VaultReconciliation {
    enum Outcome: String, Sendable, CaseIterable, Equatable {
        case databaseOnly
        case vaultOnly
        case divergent
        case identical
    }

    struct Item: Sendable, Equatable, Identifiable {
        var id: UUID { noteID }
        var noteID: UUID
        var title: String
        var outcome: Outcome
        var vaultRelativePath: String?
    }

    struct Report: Sendable, Equatable {
        var items: [Item] = []
        var parseFailures: [String] = []
        /// Entries the scan does not read as notes (folders, other files,
        /// links). Deleting the mirror removes them unseen, so they are
        /// counted and named before the user confirms.
        var skipped: [String] = []
        /// Notes the user has already decided about (kept, copied or taken).
        var resolved: Set<UUID> = []

        var databaseOnly: [Item] { items.filter { $0.outcome == .databaseOnly } }
        var vaultOnly: [Item] { items.filter { $0.outcome == .vaultOnly } }
        var divergent: [Item] { items.filter { $0.outcome == .divergent } }
        /// What still needs a decision: notes only in the mirror, and notes
        /// that differ, that the user has not resolved.
        var unresolvedVaultOnly: [Item] { vaultOnly.filter { !resolved.contains($0.noteID) } }
        var unresolvedDivergent: [Item] { divergent.filter { !resolved.contains($0.noteID) } }
        var hasUnresolved: Bool { !unresolvedVaultOnly.isEmpty || !unresolvedDivergent.isEmpty }
    }

    struct VaultNote: Sendable {
        var note: Note
        var relativePath: String
    }

    /// Parses the vault folder without touching the database. Hidden entries
    /// (`.DS_Store`, an Obsidian `.obsidian` folder) are settings, not notes,
    /// and are not reported.
    static func scan(root: URL) -> (notes: [VaultNote], failures: [String], skipped: [String]) {
        var notes: [VaultNote] = []
        var failures: [String] = []
        var skipped: [String] = []
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]) else {
            return ([], [], [])
        }
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let values = try? entry.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard entry.pathExtension == "md",
                  values?.isRegularFile == true, values?.isSymbolicLink != true else {
                skipped.append(entry.lastPathComponent)
                continue
            }
            guard let raw = try? String(contentsOf: entry, encoding: .utf8),
                  let note = MarkdownVaultDecoder.decode(raw) else {
                failures.append(entry.lastPathComponent)
                continue
            }
            notes.append(VaultNote(note: note, relativePath: entry.lastPathComponent))
        }
        return (notes, failures, skipped)
    }

    static func reconcile(vaultNotes: [VaultNote], databaseNotes: [Note]) -> Report {
        var report = Report()
        var databaseByID: [UUID: Note] = [:]
        for note in databaseNotes { databaseByID[note.id] = note }
        var seen = Set<UUID>()

        for entry in vaultNotes {
            seen.insert(entry.note.id)
            guard let existing = databaseByID[entry.note.id] else {
                report.items.append(Item(
                    noteID: entry.note.id, title: entry.note.title,
                    outcome: .vaultOnly, vaultRelativePath: entry.relativePath))
                continue
            }
            let same = existing.title == entry.note.title
                && existing.content == entry.note.content
                && existing.tags == entry.note.tags
                && existing.mentionedPatients == entry.note.mentionedPatients
                && existing.isPinned == entry.note.isPinned
            report.items.append(Item(
                noteID: entry.note.id, title: existing.title,
                outcome: same ? .identical : .divergent,
                vaultRelativePath: entry.relativePath))
        }
        for note in databaseNotes where !seen.contains(note.id) {
            report.items.append(Item(
                noteID: note.id, title: note.title,
                outcome: .databaseOnly, vaultRelativePath: nil))
        }
        report.items.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        return report
    }
}

/// Decoding half of the retired vault format, kept so an existing mirror can
/// be read exactly once.
enum MarkdownVaultDecoder {
    static func decode(_ text: String) -> Note? {
        guard text.hasPrefix("---") else { return nil }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.first == "---" else { return nil }
        lines.removeFirst()
        var fields: [String: String] = [:]
        var closeIndex: Int?
        for (index, line) in lines.enumerated() where line == "---" {
            closeIndex = index
            break
        }
        guard let end = closeIndex else { return nil }
        for line in lines[0..<end] {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            fields[key] = value
        }
        let content = lines[(end + 1)...].joined(separator: "\n")
            .drop(while: { $0.isNewline })
        guard let idString = fields["id"].map(MarkdownExportService.yamlUnescape),
              let id = UUID(uuidString: idString) else { return nil }
        let note = Note(
            id: id,
            title: fields["title"].map(MarkdownExportService.yamlUnescape) ?? "",
            content: String(content),
            createdAt: fields["created"].flatMap { try? LenientDate.decode($0) } ?? Date(),
            updatedAt: fields["updated"].flatMap { try? LenientDate.decode($0) } ?? Date(),
            tags: parseYAMLList(fields["tags"]),
            mentionedPatients: parseYAMLList(fields["patients"]).compactMap(UUID.init(uuidString:)),
            isPinned: fields["pinned"] == "true")
        if note.content.isEmpty && note.title.isEmpty && note.tags.isEmpty { return nil }
        return note
    }

    /// Parses `[ "a", "b" ]` — the exact list shape produced by the encoder.
    static func parseYAMLList(_ raw: String?) -> [String] {
        guard var text = raw?.trimmingCharacters(in: .whitespaces), text.hasPrefix("["), text.hasSuffix("]") else {
            return []
        }
        text = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return [] }
        var items: [String] = []
        var current = ""
        var insideQuotes = false
        var escaped = false
        for ch in text {
            if escaped {
                switch ch {
                case "n": current.append("\n")
                case "r": current.append("\r")
                default: current.append(ch)
                }
                escaped = false
                continue
            }
            switch ch {
            case "\\" where insideQuotes:
                escaped = true
            case "\"" where insideQuotes:
                insideQuotes = false
                items.append(current)
                current = ""
            case "\"":
                insideQuotes = true
                current = ""
            case "," where !insideQuotes:
                let trimmed = current.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { items.append(trimmed) }
                current = ""
            default:
                current.append(ch)
            }
        }
        let trimmed = current.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { items.append(trimmed) }
        // Quoted items were unescaped while scanning; unescaping them again would corrupt them.
        return items.filter { !$0.isEmpty }
    }
}
