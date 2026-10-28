import Combine
import SwiftUI
import UniformTypeIdentifiers

/// Note templates.
extension AppSession {
    func templatesForMenu() async -> [NoteTemplate] {
        guard let store else { return TemplateService.builtIns.map(\.displayed) }
        return (try? await store.templates.allTemplates()) ?? TemplateService.builtIns.map(\.displayed)
    }

    func loadTemplates() async throws -> [NoteTemplate] {
        try await openStore().templates.allTemplates()
    }

    func saveTemplate(_ template: NoteTemplate) async throws {
        try await openStore().templates.save(template)
        templateEpoch += 1
    }

    /// Stores a fresh custom template so the editor has a row to work on;
    /// `discardTemplateIfUntouched` takes it back if nothing is typed.
    func newTemplate() async throws -> NoteTemplate {
        let template = NoteTemplate.newRecord()
        try await openStore().templates.save(template)
        templateEpoch += 1
        return template
    }

    func deleteTemplate(id: String) async throws {
        try await openStore().templates.delete(id: id)
        if defaultNoteTemplateID == id { defaultNoteTemplateID = nil }
        templateEpoch += 1
    }

    func resetTemplate(id: String) async throws -> NoteTemplate {
        let shipped = try await openStore().templates.reset(id: id)
        templateEpoch += 1
        return shipped
    }

    /// Silent by design, like the record editors' discard: an abandoned "+"
    /// leaves no row behind, and a failure to remove one is not worth an alert.
    func discardTemplateIfUntouched(_ template: NoteTemplate) async {
        guard template.isUntouchedNewRecord, let store else { return }
        if (try? await store.templates.delete(id: template.id)) != nil {
            templateEpoch += 1
        }
    }
}
