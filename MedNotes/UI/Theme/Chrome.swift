import SwiftUI

extension View {
    func prominentActionButtonStyle() -> some View {
        self.buttonStyle(.borderedProminent)
    }

    /// Caps the view at `Chrome.readableWidth` and centres that column in
    /// the space it is given; narrower than that, it fills it.
    func readableColumn() -> some View {
        frame(maxWidth: Chrome.readableWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
    }
}

enum Chrome {
    static let chipFill = Color.primary.opacity(0.06)
    static let chipFillStrong = Color.primary.opacity(0.10)
    static let editorFill = Color.primary.opacity(0.045)
    /// Widest a column of body text runs before lines get too long to read:
    /// about 75–80 characters at the body size.
    static let readableWidth: CGFloat = 720

    enum Space {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
    }

    enum Radius {
        static let chip: CGFloat = 8
        static let badge: CGFloat = 7
        static let card: CGFloat = 10
    }

    /// Metrics shared by every list row. Notes, patients, todos and events
    /// scroll past each other in the same column, so they keep one rhythm
    /// rather than each picking its own hardcoded spacing.
    enum Row {
        /// Between stacked lines inside a row (title, subline, meta).
        static let contentSpacing: CGFloat = 4
        /// Between items sitting on one line (title and pin, pill and name).
        static let inlineSpacing: CGFloat = 6
        /// Between a leading accessory (avatar, date block) and the text.
        static let leadingSpacing: CGFloat = 10
        static let verticalPadding: CGFloat = 3
    }

    static func priorityColor(_ priority: TodoPriority) -> Color {
        switch priority {
        case .high: return .red
        case .medium: return .orange
        case .low: return .secondary
        }
    }

    static func moduleTint(_ module: AppModule) -> Color {
        switch module {
        case .notes: return Color.accentColor
        case .patients: return Color(nsColor: .systemBlue)
        case .todos: return Color(nsColor: .systemOrange)
        case .calendar: return Color(nsColor: .systemIndigo)
        case .graph: return Color(nsColor: .systemTeal)
        }
    }

    static func eventTint(_ type: EventType) -> Color {
        switch type {
        case .appointment: return Color(nsColor: .systemBlue)
        case .medicationChange: return Color(nsColor: .systemPurple)
        case .labResult: return Color(nsColor: .systemTeal)
        case .surgery: return Color(nsColor: .systemRed)
        case .checkup: return Color(nsColor: .systemGreen)
        case .consultation: return Color.accentColor
        case .vaccine: return Color(nsColor: .systemOrange)
        case .observation: return Color(nsColor: .systemIndigo)
        case .customEvent: return .secondary
        }
    }

    static func eventSymbol(_ type: EventType) -> String {
        switch type {
        case .appointment: return "calendar"
        case .medicationChange: return "pills"
        case .labResult: return "flask"
        case .surgery: return "cross.case"
        case .checkup: return "heart.text.square"
        case .consultation: return "stethoscope"
        case .vaccine: return "syringe"
        case .observation: return "eye"
        case .customEvent: return "star"
        }
    }
}

enum DisplayCopy {
    static func patient(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? String(localized: "Unnamed Patient") : trimmed
    }

    static func patient(_ patient: Patient) -> String {
        Self.patient(patient.displayName)
    }

    static func title(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? String(localized: "Untitled") : trimmed
    }

    /// Initials from a whole display name: first and last word.
    static func initials(ofName name: String) -> String {
        let parts = name.split(separator: " ")
        return initials(first: parts.first.map(String.init) ?? "",
                        last: parts.count > 1 ? String(parts.last!) : "")
    }

    static func initials(first: String, last: String) -> String {
        let f = first.trimmingCharacters(in: .whitespacesAndNewlines).first
        let l = last.trimmingCharacters(in: .whitespacesAndNewlines).first
        switch (f, l) {
        case let (a?, b?): return String([a, b]).uppercased()
        case let (a?, nil): return String(a).uppercased()
        case let (nil, b?): return String(b).uppercased()
        default: return "?"
        }
    }

    static func conditionStatus(_ status: ConditionStatus) -> String {
        switch status {
        case .active: return String(localized: "Active")
        case .chronic: return String(localized: "Chronic")
        case .inactive: return String(localized: "Inactive")
        case .discontinued: return String(localized: "Discontinued")
        case .resolved: return String(localized: "Resolved")
        }
    }

    static func allergySeverity(_ severity: AllergySeverity) -> String {
        switch severity {
        case .mild: return String(localized: "Mild")
        case .moderate: return String(localized: "Moderate")
        case .severe: return String(localized: "Severe")
        case .lifeThreatening: return String(localized: "Life-threatening")
        }
    }

    static func priority(_ priority: TodoPriority) -> String {
        switch priority {
        case .high: return String(localized: "High")
        case .medium: return String(localized: "Medium")
        case .low: return String(localized: "Low")
        }
    }

    static func eventType(_ type: EventType) -> String {
        switch type {
        case .appointment: return String(localized: "Appointment")
        case .medicationChange: return String(localized: "Medication Change")
        case .labResult: return String(localized: "Lab Result")
        case .surgery: return String(localized: "Surgery")
        case .checkup: return String(localized: "Checkup")
        case .consultation: return String(localized: "Consultation")
        case .vaccine: return String(localized: "Vaccine")
        case .observation: return String(localized: "Observation")
        case .customEvent: return String(localized: "Custom Event")
        }
    }

    static func gender(_ gender: Gender) -> String {
        switch gender {
        case .male: return String(localized: "Male")
        case .female: return String(localized: "Female")
        case .other: return String(localized: "Other")
        case .preferNotToSay: return String(localized: "Prefer not to say")
        }
    }

    /// `nil` is "not recorded"; `.unknown` is the record saying it is unknown.
    static func bloodType(_ type: BloodType?) -> String {
        guard let type else { return String(localized: "Not recorded") }
        switch type {
        case .aPositive: return "A+"
        case .aNegative: return "A−"
        case .bPositive: return "B+"
        case .bNegative: return "B−"
        case .abPositive: return "AB+"
        case .abNegative: return "AB−"
        case .oPositive: return "O+"
        case .oNegative: return "O−"
        case .unknown: return String(localized: "Unknown")
        }
    }

    /// Audit actions are stored as snake_case identifiers; shown as words.
    static func auditAction(_ action: String) -> String {
        switch action {
        case "patient_save": return String(localized: "Saved patient")
        case "patient_delete": return String(localized: "Deleted patient")
        case "patient_discard": return String(localized: "Discarded untouched patient")
        case "patient_archive": return String(localized: "Archived patient")
        case "patient_unarchive": return String(localized: "Restored patient")
        case "note_save": return String(localized: "Saved note")
        case "note_delete": return String(localized: "Deleted note")
        case "note_discard": return String(localized: "Discarded untouched note")
        case "todo_save": return String(localized: "Saved todo")
        case "todo_delete": return String(localized: "Deleted todo")
        case "todo_discard": return String(localized: "Discarded untouched todo")
        case "todo_toggle": return String(localized: "Toggled todo")
        case "event_save": return String(localized: "Saved event")
        case "event_delete": return String(localized: "Deleted event")
        case "event_discard": return String(localized: "Discarded untouched event")
        case "backup_create": return String(localized: "Backed up")
        case "backup_restore": return String(localized: "Restored backup")
        case "import_legacy": return String(localized: "Imported legacy data")
        case "vault_reconcile": return String(localized: "Reconciled vault")
        case "vault_mirroring_on": return String(localized: "Vault mirroring on")
        case "vault_mirroring_off": return String(localized: "Vault mirroring off")
        case "calendar_auto_sync_on": return String(localized: "Calendar auto-sync on")
        case "calendar_auto_sync_off": return String(localized: "Calendar auto-sync off")
        case "reminders_auto_sync_on": return String(localized: "Reminders auto-sync on")
        case "reminders_auto_sync_off": return String(localized: "Reminders auto-sync off")
        case "integrity_check": return String(localized: "Checked integrity")
        case "restore_point_delete": return String(localized: "Deleted restore point")
        case "restore_point_prune": return String(localized: "Pruned restore points")
        case "template_save": return String(localized: "Saved template")
        case "template_delete": return String(localized: "Deleted template")
        case "template_reset": return String(localized: "Reset template")
        case "app_lock": return String(localized: "Locked MedNotes")
        case "sync_destination_confirm": return String(localized: "Confirmed sync destination")
        case "markdown_export": return String(localized: "Exported Markdown")
        case "legacy_vault_delete": return String(localized: "Deleted plaintext mirror")
        case "todo_sync_import": return String(localized: "Imported todo from Reminders")
        case "note_pin": return String(localized: "Toggled note pin")
        case "link_relink_failed": return String(localized: "Link update failed")
        case "links_rebuilt": return String(localized: "Rebuilt note links")
        case "indexes_rebuilt": return String(localized: "Rebuilt indexes")
        default: return action.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    static func graphGroup(_ kind: LinkingService.GraphNode.Kind) -> String {
        switch kind {
        case .note: return String(localized: "Notes")
        case .patient: return String(localized: "Patients")
        case .event: return String(localized: "Events")
        }
    }

    static func amkaIssue(_ issue: AMKA.Issue) -> String {
        switch issue {
        case .length(let count):
            return String(localized: "AMKA has \(count) digits; it should have 11.")
        case .nonDigits:
            return String(localized: "AMKA should contain digits only.")
        case .impossibleDate:
            return String(localized: "The first six digits of an AMKA are the birth date (day, month, year); these are not a real date.")
        case .checkDigit:
            return String(localized: "The AMKA check digit does not match; one digit is probably mistyped.")
        }
    }

    /// `SyncDestination.sourceType` is the stored EventKit kind ("local",
    /// "calDAV", …); this is how the wizard and Settings › Sync name it.
    static func syncSourceType(_ type: String) -> String {
        switch type {
        case "local": return String(localized: "On My Mac")
        case "exchange": return "Exchange"
        case "calDAV": return "CalDAV"
        case "mobileMe": return "iCloud"
        case "subscribed": return String(localized: "Subscribed")
        case "birthdays": return String(localized: "Birthdays")
        default: return String(localized: "Other")
        }
    }

    /// Backup and restore-point names the app chose are sealed into the
    /// archive in English; they are shown in the UI language. Any other name
    /// is the user's own.
    static func backupName(_ name: String) -> String {
        switch name {
        case "MedNotes backup": return String(localized: "MedNotes backup")
        case "Pre-encryption backup": return String(localized: "Pre-encryption backup")
        case "Pre-restore snapshot": return String(localized: "Pre-restore snapshot")
        case "Pre-import snapshot": return String(localized: "Pre-import snapshot")
        default: return name
        }
    }

    /// The shipped templates' names, which the store and the trail keep in
    /// English; a name the user gave is shown as it is.
    static func templateName(_ name: String) -> String {
        switch name {
        case "SOAP Note": return String(localized: "SOAP Note")
        case "Admission Note": return String(localized: "Admission Note")
        case "Discharge Summary": return String(localized: "Discharge Summary")
        default: return name
        }
    }

    /// Audit details stay as written (English phrases and `key=value`
    /// tokens, older builds' rows included), so the trail on disk never
    /// changes; they are put into the reader's language here. Text this does
    /// not recognise (an error message, a summary localised when it was
    /// written) is shown as stored.
    static func auditDetails(_ entry: AuditLogEntry) -> String {
        let details = entry.details
        switch details {
        case "":
            return entry.entityId == "settings" ? String(localized: "Settings") : entry.entityId
        case "patient saved": return String(localized: "Patient saved")
        case "note saved": return String(localized: "Note saved")
        case "todo saved": return String(localized: "Todo saved")
        case "event saved": return String(localized: "Event saved")
        case "template saved": return String(localized: "Template saved")
        case "Deleted patient": return String(localized: "Deleted patient")
        case "Archived patient": return String(localized: "Archived patient")
        case "Restored patient": return String(localized: "Restored patient")
        case "Discarded untouched new patient": return String(localized: "Discarded untouched patient")
        case "Deleted the retired plaintext Markdown mirror":
            return String(localized: "The plaintext Markdown mirror was deleted.")
        case "todo imported from the Apple Reminders destination":
            return String(localized: "Todo imported from Apple Reminders")
        case "ok" where entry.action == "integrity_check":
            return String(localized: "No problems found.")
        case "reason=idle": return String(localized: "Locked after inactivity")
        case "reason=screen-lock": return String(localized: "Locked when the screen locked")
        case "reason=display-sleep": return String(localized: "Locked when the display went to sleep")
        case "reason=system-sleep": return String(localized: "Locked when the Mac went to sleep")
        case "reason=user-switch": return String(localized: "Locked on a user switch")
        case "reason=request": return String(localized: "Locked on request")
        case "reason=restore-rollback-failed": return String(localized: "Locked after a restore could not be rolled back")
        default: break
        }
        let words = details.split(separator: " ")
        switch entry.action {
        case "markdown_export":
            // "notes=12 bytes=3456"
            if let token = words.first(where: { $0.hasPrefix("notes=") }),
               let notes = Int(token.dropFirst("notes=".count)) {
                return String(localized: "Exported \(notes) notes as plaintext Markdown.")
            }
        case "links_rebuilt":
            // "notes=40 links=120 unresolved=8 ambiguous=0 earlier=118 unresolvedNow=5"
            func count(_ name: String) -> Int? {
                words.first(where: { $0.hasPrefix(name + "=") }).flatMap { Int($0.dropFirst(name.count + 1)) }
            }
            if let links = count("links"), let unresolved = count("unresolved"),
               let lost = count("unresolvedNow") {
                return String(localized: "\(links) links (\(unresolved) unresolved); \(lost) earlier links no longer resolve")
            }
        case "indexes_rebuilt":
            // "notes=40 links=120 unresolved=8 ambiguous=0 headings=90 tags=30 properties=12 failed=0 passed=1"
            func count(_ name: String) -> Int? {
                words.first(where: { $0.hasPrefix(name + "=") }).flatMap { Int($0.dropFirst(name.count + 1)) }
            }
            if let notes = count("notes"), let links = count("links"), let unresolved = count("unresolved"),
               let headings = count("headings"), let tags = count("tags") {
                return String(localized: "Rebuilt \(notes) notes: \(links) links (\(unresolved) unresolved), \(headings) headings, \(tags) tags.")
            }
        case "restore_point_prune":
            // "Removed 3 older restore point(s)"
            if words.count > 1, let count = Int(words[1]) {
                return String(localized: "Removed \(count) older restore point(s)")
            }
        case "restore_point_delete":
            if let name = quoted(details, after: "Deleted restore point \"") {
                return String(localized: "Deleted restore point “\(backupName(name))”")
            }
        case "template_reset":
            if let name = quoted(details, after: "Reset template \"") {
                return String(localized: "Reset template “\(templateName(name))” to its shipped copy")
            }
        case "sync_destination_confirm":
            // "Confirmed a calDAV destination; appCreated=false"
            if words.count > 2, words[0] == "Confirmed", words[1] == "a" {
                return String(localized: "Confirmed a \(syncSourceType(String(words[2]))) destination")
            }
        default: break
        }
        return details
    }

    /// The text between `prefix` and the next straight quote.
    private static func quoted(_ text: String, after prefix: String) -> String? {
        guard text.hasPrefix(prefix) else { return nil }
        let rest = text.dropFirst(prefix.count)
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }

    // MARK: Note previews

    private static let previewSubstitutions: [(NSRegularExpression, String)] = {
        let patterns: [(String, String)] = [
            (#"!\[[^\]]*\]\([^)]*\)"#, ""),     // images say nothing at caption size
            (#"\[\[([^\[\]]+)\]\]"#, "$1"),     // wiki-links -> their anchor
            (#"\[([^\]]*)\]\([^)]*\)"#, "$1"),  // markdown links -> their label
            (#"`([^`]*)`"#, "$1"),              // inline code
            (#"(\*\*|__|~~|\*)"#, "")           // emphasis markers
        ]
        return patterns.compactMap { pattern, template in
            (try? NSRegularExpression(pattern: pattern)).map { ($0, template) }
        }
    }()

    /// Plain-text preview of a note body. A list row shows two caption-sized
    /// lines, where raw markdown syntax costs more room than it conveys —
    /// a row opening on `---` front-matter or a `#` heading reads as noise.
    static func preview(_ content: String) -> String {
        // Front matter is never previewed (`FrontMatter`: properties between
        // two `---` lines); two rules around prose are just text.
        var text = content
        if let block = FrontMatter.properties(in: content) {
            text = (content as NSString).substring(from: NSMaxRange(block.range))
        }
        let lines = text.components(separatedBy: .newlines)

        var kept: [String] = []
        var insideFence = false

        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                insideFence.toggle()
                continue
            }
            if insideFence || line.isEmpty || isRule(line) { continue }

            let cleaned = plainLine(line)
            if !cleaned.isEmpty { kept.append(cleaned) }
            if kept.count == 4 { break }   // two rendered lines never need more
        }

        return kept.joined(separator: " ")
    }

    /// One line of Markdown as plain text: quote, heading, bullet and task
    /// markers and inline syntax removed. Shared by the preview and the search
    /// snippet.
    static func plainLine(_ raw: String) -> String {
        stripInline(stripLeadingMarkers(raw.trimmingCharacters(in: .whitespaces)))
            .trimmingCharacters(in: .whitespaces)
    }

    /// `---`, `***`, `___`: structure carrying no text.
    private static func isRule(_ line: String) -> Bool {
        line.count >= 3 && line.allSatisfy { $0 == "-" || $0 == "*" || $0 == "_" }
    }

    /// Quote markers, headings, bullets, ordered markers and task boxes.
    private static func stripLeadingMarkers(_ line: String) -> String {
        var text = Substring(line)

        while text.first == ">" {
            text = text.dropFirst().drop(while: { $0 == " " })
        }

        // `#` opens a heading only when a space follows; `#tag` is content.
        let hashes = text.prefix(while: { $0 == "#" })
        if (1...6).contains(hashes.count), text.dropFirst(hashes.count).first == " " {
            text = text.dropFirst(hashes.count).drop(while: { $0 == " " })
        }

        if let bullet = text.first, "-*+".contains(bullet), text.dropFirst().first == " " {
            text = text.dropFirst().drop(while: { $0 == " " })
        } else {
            let digits = text.prefix(while: \.isNumber)
            let afterDigits = text.dropFirst(digits.count)
            if !digits.isEmpty, let mark = afterDigits.first, mark == "." || mark == ")",
               afterDigits.dropFirst().first == " " {
                text = afterDigits.dropFirst().drop(while: { $0 == " " })
            }
        }

        // Task boxes are left behind by the bullet strip above.
        for box in ["[ ] ", "[x] ", "[X] "] where text.hasPrefix(box) {
            text = text.dropFirst(box.count)
            break
        }

        return String(text)
    }

    private static func stripInline(_ line: String) -> String {
        previewSubstitutions.reduce(line) { text, substitution in
            let (regex, template) = substitution
            return regex.stringByReplacingMatches(
                in: text,
                range: NSRange(text.startIndex..., in: text),
                withTemplate: template
            )
        }
    }

    // MARK: Timestamps

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    /// Compact "2h ago" stamp. `Text(_, style: .relative)` renders a bare
    /// "2 minutes" with no direction, and re-ticks every second in every
    /// visible row — too loud for a list that is mostly being scanned.
    ///
    /// `locale` is a test seam and nothing else. The shared formatter keeps the
    /// user's locale: pinning it to make an assertion literal would ship English
    /// stamps to the Greek users this app is written for.
    static func relative(_ date: Date, to reference: Date = Date(),
                         locale: Locale? = nil) -> String {
        guard let locale else {
            return relativeFormatter.localizedString(for: date, relativeTo: reference)
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.locale = locale
        return formatter.localizedString(for: date, relativeTo: reference)
    }
}
