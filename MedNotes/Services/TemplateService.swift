import Foundation

enum TemplateKind: String, LenientEnum, CaseIterable, Hashable {
    case soap = "soap"
    case admission = "admission"
    case discharge = "discharge"
    case custom = "custom"
    static let fallback: TemplateKind = .custom
}

struct NoteTemplate: Identifiable, Hashable, Sendable {
    /// Stable string id so re-seeding never duplicates and user edits persist.
    let id: String
    var name: String
    let kind: TemplateKind
    var content: String

    /// Substitutes {{date}}, {{time}}, {{patient}} at apply time.
    func rendered(patientName: String?) -> String {
        let now = Date()
        let dateText = now.formatted(date: .abbreviated, time: .omitted)
        let timeText = now.formatted(date: .omitted, time: .shortened)
        return content
            .replacingOccurrences(of: "{{date}}", with: dateText)
            .replacingOccurrences(of: "{{time}}", with: timeText)
            .replacingOccurrences(of: "{{patient}}", with: patientName ?? "—")
    }
}

extension NoteTemplate {
    /// Custom templates carry this prefix; the built-ins are `tpl-soap` and
    /// company, which is how the two are told apart everywhere.
    static let customIDPrefix = "tpl-custom-"

    /// What "+" in Settings › Templates stores before the user types, the
    /// way the record creators do (`Models/NewRecord.swift`), so there is
    /// something to edit in place and nothing left behind if it is abandoned.
    static func newRecord() -> NoteTemplate {
        NoteTemplate(id: customIDPrefix + UUID().uuidString.lowercased(),
                     name: String(localized: "New Template"), kind: .custom, content: "")
    }

    /// Still the template "+" made, or typed into and cleared again: a name
    /// the user never changed (or emptied) over no content.
    var isUntouchedNewRecord: Bool {
        guard kind == .custom, content.isEmpty else { return false }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == NoteTemplate.newRecord().name
    }

    /// A custom copy of this template, named after it. Names are not
    /// unique, so a second copy is allowed and reads the same.
    func duplicate() -> NoteTemplate {
        NoteTemplate(id: NoteTemplate.newRecord().id,
                     name: String(localized: "\(name) copy"),
                     kind: .custom, content: content)
    }

    /// The copy that ships with the app, for a built-in id.
    var shippedCopy: NoteTemplate? {
        TemplateService.builtIns.first { $0.id == id }
    }

    var isBuiltIn: Bool { shippedCopy != nil }

    /// A built-in the user has changed; the shipped copy is what Reset restores.
    /// The shipped copy in the user's language counts as unchanged too.
    var isEditedBuiltIn: Bool {
        guard let shippedCopy else { return false }
        return shippedCopy != self && shippedCopy.displayed != self
    }

    /// A built-in still exactly as shipped, in the user's language. The store
    /// keeps the English shipped copy (seeded once, and what Reset writes
    /// back), so the translation happens here, keyed by that English text; an
    /// edited built-in, or a custom template, is shown as written.
    var displayed: NoteTemplate {
        guard let shippedCopy, self == shippedCopy else { return self }
        var copy = self
        copy.name = String(localized: String.LocalizationValue(name))
        copy.content = String(localized: String.LocalizationValue(content))
        return copy
    }
}

enum TemplateError: LocalizedError {
    case builtInCannotBeDeleted(String)
    case notBuiltIn(String)

    var errorDescription: String? {
        switch self {
        case .builtInCannotBeDeleted:
            return "Built-in templates cannot be deleted; reset one to its shipped copy instead."
        case .notBuiltIn:
            return "Only a built-in template has a shipped copy to reset to."
        }
    }
}

actor TemplateService {
    private let db: Database
    private let audit: AuditService

    init(db: Database, audit: AuditService) {
        self.db = db
        self.audit = audit
    }

    /// Shipped clinical templates. Seeded into `note_templates` by the schema
    /// v2 migration with INSERT OR IGNORE, so edits made through the app are
    /// preserved while fresh databases start complete.
    nonisolated static let builtIns: [NoteTemplate] = [
        NoteTemplate(
            id: "tpl-soap",
            name: "SOAP Note",
            kind: .soap,
            content: """
            # SOAP — {{patient}}
            _{{date}}_

            ## Subjective
            -

            ## Objective
            -

            ## Assessment
            -

            ## Plan
            -
            """),
        NoteTemplate(
            id: "tpl-admission",
            name: "Admission Note",
            kind: .admission,
            content: """
            # Admission — {{patient}}
            _{{date}}_

            ## Presenting complaint
            - 

            ## History of present illness


            ## Past medical history / medications / allergies


            ## Examination findings


            ## Investigations


            ## Working diagnosis


            ## Initial management plan

            """),
        NoteTemplate(
            id: "tpl-discharge",
            name: "Discharge Summary",
            kind: .discharge,
            content: """
            # Discharge Summary — {{patient}}
            _{{date}}_

            ## Admission diagnosis


            ## Hospital course


            ## Discharge medications


            ## Follow-up
            - [ ] Appointment: [[ ]]

            ## Instructions to patient

            """),
    ]

    nonisolated static let builtInIDs = Set(builtIns.map(\.id))

    /// The built-ins in shipped order — each replaced by its stored row, which
    /// is where an edit made in Settings lives — then custom templates by
    /// name. One order for the note editor's menu and the Settings list.
    func allTemplates() async throws -> [NoteTemplate] {
        let stored = try await db.customTemplates()
        let storedByID = Dictionary(stored.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let builtIns = Self.builtIns.map { (storedByID[$0.id] ?? $0).displayed }
        let customs = stored
            .filter { !Self.builtInIDs.contains($0.id) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return builtIns + customs
    }

    func save(_ template: NoteTemplate) async throws {
        try await db.saveTemplate(template)
        try await audit.log(
            action: "template_save", entityType: "note_template", entityId: template.id,
            details: "template saved")
    }

    /// Custom templates only: a built-in is reset, never removed, so the
    /// note editor's menu always offers the clinical set.
    func delete(id: String) async throws {
        guard !Self.builtInIDs.contains(id) else { throw TemplateError.builtInCannotBeDeleted(id) }
        try await db.deleteTemplate(id: id)
        try await audit.log(action: "template_delete", entityType: "note_template", entityId: id)
    }

    /// Puts a built-in's shipped copy back over the stored row and returns it.
    func reset(id: String) async throws -> NoteTemplate {
        guard let shipped = Self.builtIns.first(where: { $0.id == id }) else {
            throw TemplateError.notBuiltIn(id)
        }
        try await db.saveTemplate(shipped)
        try await audit.log(
            action: "template_reset", entityType: "note_template", entityId: id,
            details: "Reset template \"\(shipped.name)\" to its shipped copy")
        return shipped.displayed
    }
}
