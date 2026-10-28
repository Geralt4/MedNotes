import SwiftUI

/// The note's right-hand panel, like Obsidian's right sidebar: its properties,
/// its outline and its links. `note` is the draft being edited, so every
/// section follows what is typed.
struct NoteInspector: View {
    let note: Note?
    /// Changes one property of the note with this id; the last argument is the
    /// property's lines as the panel read them (see `NoteBodyEditor.editProperty`).
    let applyProperty: (UUID, FrontMatterEditor.Operation, String?) -> Void
    /// Puts the caret at a UTF-16 offset of the body.
    let reveal: (Int) -> Void

    @State private var propertiesExpanded = true
    @State private var outlineExpanded = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let note {
                    NotePropertiesSection(note: note, expanded: $propertiesExpanded, apply: applyProperty)
                    Divider()
                    NoteOutlineSection(note: note, expanded: $outlineExpanded, reveal: reveal)
                    Divider()
                    NoteGraphSection(noteID: note.id)
                    Divider()
                }
                NoteLinksSection()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A titled, collapsible block of the inspector.
struct InspectorSection<Content: View>: View {
    let title: LocalizedStringKey
    let systemImage: String
    var count: Int?
    @Binding var expanded: Bool
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Chrome.Space.xs) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption)
                    Image(systemName: systemImage)
                        .font(.caption)
                    Text(title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let count, count > 0 {
                        Text("\(count)")
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded { content }
        }
        .padding(.horizontal, Chrome.Space.md)
        .padding(.vertical, Chrome.Space.sm)
    }
}

/// Outgoing links, links that lead nowhere, backlinks and unlinked mentions
/// of the open note.
struct NoteLinksSection: View {
    @EnvironmentObject private var session: AppSession
    @State private var expanded = true

    var body: some View {
        let resolvedLinks = session.linksOut.filter { $0.kind == .note || $0.kind == .patient }
        let openLinks = session.linksOut.filter { $0.kind == .unresolved || $0.kind == .ambiguous }
        let hasLinks = !session.linksOut.isEmpty || !session.backlinks.isEmpty
        InspectorSection(
            title: "Linked mentions", systemImage: "link",
            count: session.linksOut.count + session.backlinks.count, expanded: $expanded
        ) {
            if !hasLinks && session.unlinkedMentions.isEmpty {
                Text("Type [[ to link this note to another note or a patient.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            // Each entry is a distinct destination or link text, so its id is
            // stable; the store resolves labels from raw names, so an unnamed
            // patient reads " " and a titleless note "", and the list's
            // fallbacks (and trimming) belong here.
            ForEach(resolvedLinks) { link in
                Button {
                    guard let id = link.targetID else { return }
                    Task {
                        if link.kind == .patient {
                            await session.jumpToPatient(id)
                        } else {
                            await session.jumpToNote(id)
                        }
                    }
                } label: {
                    row(icon: link.warning == nil ? (link.kind == .patient ? "arrow.up.right" : "link")
                                                  : "exclamationmark.triangle",
                        tint: link.warning == nil ? .secondary : .orange,
                        label: link.kind == .patient
                            ? DisplayCopy.patient(link.label)
                            : DisplayCopy.title(link.label))
                }
                .buttonStyle(.plain)
                .help(warningHelp(link.warning))
            }
            ForEach(openLinks) { link in
                openLinkRow(link)
            }
            ForEach(session.backlinks, id: \.noteId) { backlink in
                Button {
                    Task { await session.jumpToNote(backlink.noteId) }
                } label: {
                    row(icon: "arrow.down.left",
                        tint: Color.accentColor,
                        label: backlink.title.isEmpty ? String(localized: "(untitled)") : backlink.title)
                }
                .buttonStyle(.plain)
            }
            if !session.unlinkedMentions.isEmpty {
                Text("Unlinked mentions")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2)
                ForEach(session.unlinkedMentions, id: \.noteId) { mention in
                    Button {
                        Task { await session.jumpToNote(mention.noteId) }
                    } label: {
                        row(icon: "text.magnifyingglass",
                            tint: .secondary,
                            label: mention.title.isEmpty ? String(localized: "(untitled)") : mention.title)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        // The scan reads every note's text, so it runs only while the section
        // is open, a moment after the note settles (arrowing through the list
        // cancels it), and again when a backlink appears.
        .task(id: "\(expanded)|\(session.selectedNoteId?.uuidString ?? "")|\(session.backlinks.count)") {
            guard expanded, let id = session.selectedNoteId else { return }
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            await session.refreshUnlinkedMentions(noteId: id)
        }
    }

    private func warningHelp(_ warning: LinkingService.OutgoingLink.Warning?) -> Text {
        switch warning {
        case .missingHeading: return Text("The heading this link names is not in that note.")
        case .missingBlock: return Text("The block this link names is not in that note.")
        case nil: return Text("")
        }
    }

    /// A link that leads nowhere yet: clicking it creates the note, unless it
    /// names a file or several notes share the title.
    @ViewBuilder
    private func openLinkRow(_ link: LinkingService.OutgoingLink) -> some View {
        let ambiguous = link.kind == .ambiguous
        let caption = ambiguous
            ? String(localized: "Several notes have this title")
            : link.canCreateNote ? String(localized: "No note has this title yet") : String(localized: "Not a note")
        let content = HStack(spacing: 6) {
            Image(systemName: ambiguous ? "exclamationmark.triangle" : link.canCreateNote ? "plus.circle" : "doc")
                .font(.caption)
                .foregroundStyle(ambiguous ? Color.orange : Color.secondary)
            Text(link.target)
                .font(.caption)
                .lineLimit(1)
            Text(caption)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Spacer()
        }
        if link.canCreateNote {
            Button {
                Task { await session.createNoteFromLink(link.target) }
            } label: {
                content.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(Text("Create note from this link"))
        } else {
            content
        }
    }

    private func row(icon: String, tint: Color, label: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(tint)
            Text(label)
                .font(.caption)
                .lineLimit(1)
            Spacer()
        }
    }
}

// MARK: - Outline

/// The note's headings, read from the text as it is typed.
struct NoteOutlineSection: View {
    let note: Note
    @Binding var expanded: Bool
    let reveal: (Int) -> Void
    @State private var headings: [NoteMetadata.Heading] = []
    @State private var shownFor: UUID?

    var body: some View {
        InspectorSection(title: "Outline", systemImage: "list.bullet.indent",
                         count: headings.count, expanded: $expanded) {
            if headings.isEmpty {
                Text("No headings yet.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            let shallowest = headings.map(\.level).min() ?? 1
            ForEach(Array(headings.enumerated()), id: \.offset) { _, heading in
                Button {
                    reveal(heading.offset)
                } label: {
                    Text(heading.text)
                        .font(.caption)
                        .lineLimit(1)
                        .padding(.leading, CGFloat(heading.level - shallowest) * 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        // Read a moment after typing settles, for the note as it is now.
        .task(id: note.content) {
            // Another note's headings never linger while this one is read.
            if shownFor != note.id { headings = []; shownFor = note.id }
            else if !headings.isEmpty { try? await Task.sleep(nanoseconds: 150_000_000) }
            guard !Task.isCancelled else { return }
            headings = NoteMetadata.scan(note.content).headings
        }
    }
}

// MARK: - Properties

/// The front matter's properties as typed fields. Edits are written into the
/// note's text (`NoteBodyEditor.editProperty`); this view never keeps a copy.
struct NotePropertiesSection: View {
    @EnvironmentObject private var session: AppSession
    let note: Note
    @Binding var expanded: Bool
    let apply: (UUID, FrontMatterEditor.Operation, String?) -> Void
    @State private var known: [PropertyKeyUsage] = []
    @State private var adding = false

    var body: some View {
        let parsed = FrontMatterYAML.parse(note.content)
        InspectorSection(title: "Properties", systemImage: "list.bullet.rectangle",
                         count: parsed?.properties.count, expanded: $expanded) {
            if let parsed {
                ForEach(parsed.properties) { property in
                    // New identity whenever its own lines change, so a field
                    // never holds a value the text has moved on from.
                    PropertyRowView(noteID: note.id, property: property, apply: apply)
                        .id("\(note.id.uuidString)|\(property.id)|\(property.text)")
                }
                if parsed.truncated {
                    Text("Too many properties to edit here.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            } else {
                Text("No properties yet.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            addControls(existing: parsed?.properties.map(\.keyNorm) ?? [], editable: !(parsed?.truncated ?? false))
        }
        .task(id: note.id) {
            known = (try? await session.store?.notes.propertyKeys()) ?? []
        }
    }

    @ViewBuilder
    private func addControls(existing: [String], editable: Bool) -> some View {
        if editable {
            if adding {
                AddPropertyForm(existing: existing, onAdd: { key, value in
                    adding = false
                    apply(note.id, .set(key: key, value: value), nil)
                }, onCancel: { adding = false })
            } else {
                Menu {
                    ForEach(known.filter { !existing.contains($0.key.lowercased()) }, id: \.key) { usage in
                        Button {
                            apply(note.id, .set(key: usage.key, value: PropertyKindChoice(kind: usage.kind).defaultValue), nil)
                        } label: {
                            Text(verbatim: "\(usage.key) · \(PropertyKindChoice(kind: usage.kind).title)")
                        }
                    }
                    Divider()
                    Button("New property…") { adding = true }
                } label: {
                    Label("Add property", systemImage: "plus")
                        .font(.caption)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
    }
}

/// What kind of value a new property starts with.
enum PropertyKindChoice: String, CaseIterable, Identifiable {
    case text, number, checkbox, date, datetime, list

    var id: String { rawValue }

    init(kind: String) {
        self = Self(rawValue: kind) ?? .text
    }

    var title: String {
        switch self {
        case .text: return String(localized: "Text")
        case .number: return String(localized: "Number")
        case .checkbox: return String(localized: "Checkbox")
        case .date: return String(localized: "Date")
        case .datetime: return String(localized: "Date and time")
        case .list: return String(localized: "List")
        }
    }

    var defaultValue: PropertyValue {
        switch self {
        case .text: return .empty
        case .number: return .number("0")
        case .checkbox: return .checkbox(false)
        case .date: return .date(PropertyDates.string(from: Date(), time: false))
        case .datetime: return .dateTime(PropertyDates.string(from: Date(), time: true))
        case .list: return .list([])
        }
    }
}

/// Dates as front matter writes them: Gregorian, no locale, no zone.
enum PropertyDates {
    private static func formatter(time: Bool) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = time ? "yyyy-MM-dd'T'HH:mm" : "yyyy-MM-dd"
        return formatter
    }

    static func string(from date: Date, time: Bool) -> String {
        formatter(time: time).string(from: date)
    }

    static func date(from text: String, time: Bool) -> Date? {
        formatter(time: time).date(from: text)
    }
}

private struct AddPropertyForm: View {
    let existing: [String]
    let onAdd: (String, PropertyValue) -> Void
    let onCancel: () -> Void
    @State private var name = ""
    @State private var kind = PropertyKindChoice.text
    @State private var rejected = false

    var body: some View {
        VStack(alignment: .leading, spacing: Chrome.Space.xs) {
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .font(.caption)
                .onSubmit(add)
            Picker("Type", selection: $kind) {
                ForEach(PropertyKindChoice.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.menu)
            .font(.caption)
            if rejected {
                Text("That name can't be used.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            HStack {
                Button("Add", action: add)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Cancel", action: onCancel)
            }
            .font(.caption)
        }
    }

    private func add() {
        let key = name.trimmingCharacters(in: .whitespaces)
        guard FrontMatterYAML.isValidKey(key), !existing.contains(key.lowercased()) else {
            rejected = true
            return
        }
        onAdd(key, kind.defaultValue)
    }
}

/// One property: its name, a field of the right kind, and a way to remove it.
/// The note id and the property's lines are fixed when the row is made, so a
/// commit that arrives after the user has moved on is recognised and dropped.
private struct PropertyRowView: View {
    let noteID: UUID
    let property: Property
    let apply: (UUID, FrontMatterEditor.Operation, String?) -> Void
    @State private var text: String
    @State private var date: Date
    @FocusState private var focused: Bool

    init(noteID: UUID, property: Property,
         apply: @escaping (UUID, FrontMatterEditor.Operation, String?) -> Void) {
        self.noteID = noteID
        self.property = property
        self.apply = apply
        switch property.value {
        case .text(let s), .number(let s): _text = State(initialValue: s)
        default: _text = State(initialValue: "")
        }
        switch property.value {
        case .date(let s): _date = State(initialValue: PropertyDates.date(from: s, time: false) ?? Date())
        case .dateTime(let s): _date = State(initialValue: PropertyDates.date(from: s, time: true) ?? Date())
        default: _date = State(initialValue: Date())
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Chrome.Space.sm) {
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: property.key)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if property.keyNorm == "title" {
                    Text("Not the note's title")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: 84, alignment: .leading)
            control
            Spacer(minLength: 0)
            if property.isEditable {
                Button {
                    apply(noteID, .remove(key: property.key), property.text)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Remove property")
                .accessibilityLabel("Remove property")
            }
        }
    }

    @ViewBuilder
    private var control: some View {
        switch property.value {
        case .text, .number, .empty:
            TextField("", text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.caption)
                .disabled(!property.isEditable)
                .focused($focused)
                .onSubmit(commitText)
                .onChange(of: focused) { _, isFocused in if !isFocused { commitText() } }
        case .checkbox(let on):
            Toggle("", isOn: Binding(get: { on }, set: { set(.checkbox($0)) }))
                .labelsHidden()
                .disabled(!property.isEditable)
        case .date:
            DatePicker("", selection: $date, displayedComponents: .date)
                .labelsHidden()
                .disabled(!property.isEditable)
                .onChange(of: date) { _, new in set(.date(PropertyDates.string(from: new, time: false))) }
        case .dateTime:
            DatePicker("", selection: $date, displayedComponents: [.date, .hourAndMinute])
                .labelsHidden()
                .disabled(!property.isEditable)
                .onChange(of: date) { _, new in set(.dateTime(PropertyDates.string(from: new, time: true))) }
        case .list(let items):
            TagEditor(tags: Binding(get: { items }, set: { set(.list($0)) }), collapsesField: true)
                .disabled(!property.isEditable)
        case .unsupported:
            Text("Complex value; edit it in the text.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func set(_ value: PropertyValue) {
        guard property.isEditable else { return }
        apply(noteID, .set(key: property.key, value: value), property.text)
    }

    private func commitText() {
        if let value = PropertyCommit.value(for: property.value, text: text) { set(value) }
    }
}

/// Where a property edit lands when it does not go through the text view.
/// Pure, so the rule that an edit belongs to one note can be tested.
enum PropertyEditRouting {
    /// Whether an edit made for `noteID` may still be applied to `draft`:
    /// only if that note is still the one open.
    static func accepts(noteID: UUID, draft: Note?) -> Bool {
        draft?.id == noteID
    }

    /// The draft with the edit made on its text, for the case of no text view
    /// (Preview). Nil when the note is no longer the open one or the edit
    /// cannot be made safely.
    static func draftAfter(
        _ operation: FrontMatterEditor.Operation, expecting: String?, noteID: UUID, draft: Note?
    ) -> Note? {
        guard var note = draft, accepts(noteID: noteID, draft: draft),
              let edit = FrontMatterEditor.edit(operation, in: note.content, expecting: expecting) else { return nil }
        note.content = FrontMatterEditor.apply(edit, to: note.content)
        return note
    }
}

/// What committing a text field writes. Pure, so it can be tested without a
/// window.
enum PropertyCommit {
    /// The value to write when a field showing `current` is committed with
    /// `text`, or nil when nothing changed or the value is not a text field's.
    static func value(for current: PropertyValue, text: String) -> PropertyValue? {
        switch current {
        case .text(let old):
            return text == old ? nil : .text(text)
        case .number(let old):
            guard text != old else { return nil }
            // Only a number that writes back identically stays a number.
            return FrontMatterYAML.isStrictNumber(text) ? .number(text) : .text(text)
        case .empty:
            return text.isEmpty ? nil : .text(text)
        default:
            return nil
        }
    }
}
