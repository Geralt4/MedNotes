import SwiftUI

struct TagChip: View {
    let text: String
    var onRemove: (() -> Void)? = nil
    /// The quieter form for list rows, where a tag is context rather than
    /// something to act on: smaller, secondary, no outline.
    var compact = false

    var body: some View {
        HStack(spacing: Chrome.Space.xs) {
            Text(verbatim: text)
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(text)")
            }
        }
        .font(compact ? .caption2.weight(.medium) : .caption.weight(.medium))
        .foregroundStyle(compact ? .secondary : .primary)
        .padding(.horizontal, compact ? Chrome.Space.xs + 2 : Chrome.Space.sm)
        .padding(.vertical, compact ? 2 : 3)
        .background(Chrome.chipFill, in: Capsule())
        .overlay(Capsule().strokeBorder(compact ? .clear : Chrome.chipFillStrong))
    }
}

struct StatusPill: View {
    private let text: Text
    var tint: Color = .secondary

    /// UI wording — a literal, localised through the strings catalog.
    init(_ key: LocalizedStringKey, tint: Color = .secondary) {
        self.text = Text(key)
        self.tint = tint
    }

    /// Data, or wording `DisplayCopy` has already localised; shown as is.
    init(text: String, tint: Color = .secondary) {
        self.text = Text(verbatim: text)
        self.tint = tint
    }

    var body: some View {
        text
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, Chrome.Space.sm - 1)
            .padding(.vertical, 2)
            .background(tint.opacity(0.14), in: Capsule())
            .overlay(Capsule().strokeBorder(tint.opacity(0.22), lineWidth: 0.5))
    }
}

struct MonogramAvatar: View {
    let initials: String
    var size: CGFloat = 32

    var body: some View {
        Text(initials)
            .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                LinearGradient(
                    colors: [Color.accentColor.opacity(0.82), Color.accentColor],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                in: Circle()
            )
            .shadow(color: Color.accentColor.opacity(0.28), radius: 2.5, y: 1)
            .accessibilityHidden(true)
    }
}

struct IconBadge: View {
    let systemImage: String
    var tint: Color = .accentColor
    var size: CGFloat = 28

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(.white)
            .symbolRenderingMode(.hierarchical)
            .frame(width: size, height: size)
            .background(
                LinearGradient(
                    colors: [tint.opacity(0.82), tint],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                in: RoundedRectangle(cornerRadius: Chrome.Radius.badge, style: .continuous)
            )
            .shadow(color: tint.opacity(0.26), radius: 2.5, y: 1)
            .accessibilityHidden(true)
    }
}

struct DateBlock: View {
    let date: Date

    var body: some View {
        VStack(spacing: 0) {
            Text(date, format: .dateTime.month(.abbreviated))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Text(date, format: .dateTime.day())
                .font(.title3.weight(.semibold).monospacedDigit())
        }
        .frame(width: 36)
        .accessibilityHidden(true)
    }
}

struct DetailSectionHeader: View {
    let title: LocalizedStringKey
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .symbolRenderingMode(.hierarchical)
            .padding(.top, Chrome.Space.xxs)
    }
}

/// Shown across the top of the main window while the store fails its
/// integrity check (`AppSession.integrityWarning`). Orange, not red: the app
/// keeps working, but the next move should be a backup and a look at
/// Settings › Data. Session-free so it renders offscreen.
struct IntegrityBanner: View {
    /// The check's detail: localised wording, or SQLite's own message.
    let message: String
    let onDismiss: () -> Void

    /// The detail without its own full stop; the sentence supplies one.
    private var detail: String {
        var text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix(".") { text.removeLast() }
        return text
    }

    var body: some View {
        HStack(spacing: Chrome.Space.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text("Integrity check failed: \(detail). Back up now, then see Settings › Data.")
                .fontWeight(.medium)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Chrome.Space.sm)
            SettingsLink {
                Text("Open Settings")
            }
            Button("Dismiss", action: onDismiss)
        }
        .controlSize(.small)
        .font(.caption)
        // Fixed dark-on-orange like the sample-data bar: the warning keeps
        // its colour in both themes.
        .foregroundStyle(.black.opacity(0.85))
        .padding(.horizontal, Chrome.Space.md)
        .padding(.vertical, Chrome.Space.sm - 2)
        .frame(maxWidth: .infinity)
        .background(Color.orange)
        .accessibilityElement(children: .contain)
    }
}

struct ModuleEmptyState: View {
    let title: LocalizedStringKey
    let systemImage: String
    let description: LocalizedStringKey
    let actionTitle: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        EmptyStateView(
            title: title,
            systemImage: systemImage,
            description: description,
            actionTitle: actionTitle,
            action: action
        )
        .detailToolbarAnchor()
    }
}

struct EditorToolbar: ToolbarContent {
    let hasChanges: Bool
    let onRevert: () -> Void
    let onSave: () -> Void
    let onDelete: () -> Void
    /// What the leading action does. Patients archive rather than delete.
    var destructiveLabel: LocalizedStringKey = "Delete"
    var destructiveSymbol: String = "trash"
    var destructiveRole: ButtonRole? = .destructive

    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button(role: destructiveRole, action: onDelete) {
                Image(systemName: destructiveSymbol)
            }
            .help(destructiveLabel)
            .accessibilityLabel(destructiveLabel)
        }
        ToolbarSpacerCompat()
        if hasChanges {
            ToolbarItem(placement: .primaryAction) {
                Button("Revert", action: onRevert)
                    .help("Discard changes")
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Save", action: onSave)
                    .keyboardShortcut("s")
                    .prominentActionButtonStyle()
                    .help("Save changes (⌘S)")
            }
        }
    }
}


/// One line of tag chips showing as many as the row width allows, with a
/// trailing `+n` standing in for the rest.
///
/// Capping by count instead is what clips: three chips fit a wide window and
/// spill out of a 240pt list column, and the chips are capsules that truncate
/// into unreadable stubs rather than eliding.
struct TagChipRow: View {
    let tags: [String]

    var body: some View {
        if !tags.isEmpty {
            // `ViewThatFits` takes candidates literally, not as a ForEach —
            // each width is spelled out, widest first.
            ViewThatFits(in: .horizontal) {
                row(visible: 3)
                row(visible: 2)
                row(visible: 1)
                row(visible: 0)
            }
        }
    }

    /// `visible: 0` still renders the overflow count, so a column too narrow
    /// for even one chip says "+3" rather than dropping the tags silently.
    private func row(visible: Int) -> some View {
        let shown = tags.prefix(visible)
        let hidden = tags.count - shown.count
        return HStack(spacing: Chrome.Space.xs) {
            ForEach(Array(shown), id: \.self) { tag in
                TagChip(text: tag, compact: true)
            }
            if hidden > 0 {
                Text("+\(hidden)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .accessibilityLabel("\(hidden) more tags")
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

/// Search field pinned above a module's list, inside the list column.
///
/// `.searchable` puts the field in the window toolbar, where macOS gives it a
/// fixed width anchored to the window's trailing edge. The list's own toolbar
/// buttons then pack leftward from that edge and land across the split-view
/// divider on anything but a wide window. Here the column owns its search, the
/// way Mail and Notes do, and the toolbar keeps only the action buttons.
struct ListSearchField: View {
    let prompt: LocalizedStringKey
    @Binding var text: String
    /// Bumped by the Find command; every change pulls focus into the field.
    var focusToken: Int = 0

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: Chrome.Space.xs + 2) {
            Image(systemName: "magnifyingglass")
                .font(.callout)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .accessibilityLabel(prompt)

            if !text.isEmpty {
                Button {
                    text = ""
                    isFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, Chrome.Space.sm)
        .padding(.vertical, Chrome.Space.xs + 1)
        .background(Chrome.chipFill, in: RoundedRectangle(cornerRadius: Chrome.Radius.chip))
        .overlay(
            RoundedRectangle(cornerRadius: Chrome.Radius.chip)
                .strokeBorder(
                    isFocused ? Color.accentColor.opacity(0.55) : Chrome.chipFillStrong,
                    lineWidth: isFocused ? 1.5 : 1
                )
        )
        .animation(.easeOut(duration: 0.12), value: isFocused)
        .onChange(of: focusToken) { isFocused = true }
        // Escape clears a query, then hands the keyboard back to the list —
        // the two-step the toolbar field gave us for free.
        .onExitCommand {
            if text.isEmpty {
                isFocused = false
            } else {
                text = ""
            }
        }
    }
}

// MARK: - Editor fields

/// A caption label sitting directly above a control, so a record editor reads
/// as a grid of "label + box" pairs rather than labels floating beside empty
/// space. Fills its row width; put two in an `EditorFieldRow` to split it.
struct EditorField<Content: View>: View {
    let label: LocalizedStringKey
    @ViewBuilder let content: () -> Content

    init(_ label: LocalizedStringKey, @ViewBuilder content: @escaping () -> Content) {
        self.label = label
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Chrome.Space.xs + 2) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Bezeled single-line text input under an `EditorField` label.
///
/// Everything here overrides what a grouped `Form` does to a text field on
/// its own: the automatic style draws no bezel (an empty field is invisible),
/// repeats the label at the row's leading edge, and right-aligns the value.
struct EditorTextField: View {
    let label: LocalizedStringKey
    let prompt: LocalizedStringKey
    @Binding var text: String
    /// Lets the owning editor move the keyboard into this field.
    var focus: FocusState<Bool>.Binding?
    /// Off for identifiers, numbers and addresses, which autocorrect mangles.
    var autocorrects = true
    /// What the field holds, for autofill and the right input behaviour.
    var contentType: NSTextContentType? = nil

    init(_ label: LocalizedStringKey, text: Binding<String>, prompt: LocalizedStringKey? = nil,
         focus: FocusState<Bool>.Binding? = nil, autocorrects: Bool = true,
         contentType: NSTextContentType? = nil) {
        self.label = label
        self.prompt = prompt ?? label
        self._text = text
        self.focus = focus
        self.autocorrects = autocorrects
        self.contentType = contentType
    }

    var body: some View {
        EditorField(label) {
            if let focus {
                field.focused(focus)
            } else {
                field
            }
        }
    }

    private var field: some View {
        TextField(label, text: $text, prompt: Text(prompt))
            .textFieldStyle(.roundedBorder)
            .labelsHidden()
            .multilineTextAlignment(.leading)
            .autocorrectionDisabled(!autocorrects)
            .textContentType(contentType)
    }
}

/// Two editor fields side by side, sharing the row width equally.
struct EditorFieldRow<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(alignment: .top, spacing: Chrome.Space.lg) {
            content()
        }
    }
}

/// Bezeled entry field with an explicit Add button; Return adds as well.
/// The accessory sits between them for an attribute that should be chosen
/// at entry rather than defaulted — an allergy's severity, say.
struct EditorAddRow<Accessory: View>: View {
    let prompt: LocalizedStringKey
    @Binding var text: String
    let action: () -> Void
    @ViewBuilder let accessory: () -> Accessory

    init(prompt: LocalizedStringKey, text: Binding<String>, action: @escaping () -> Void,
         @ViewBuilder accessory: @escaping () -> Accessory) {
        self.prompt = prompt
        self._text = text
        self.action = action
        self.accessory = accessory
    }

    var body: some View {
        HStack(spacing: Chrome.Space.sm) {
            TextField(prompt, text: $text, prompt: Text(prompt))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .multilineTextAlignment(.leading)
                .onSubmit(action)
            accessory()
            Button(action: action) {
                Label("Add", systemImage: "plus")
            }
            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.vertical, Chrome.Space.xxs)
    }
}

extension EditorAddRow where Accessory == EmptyView {
    init(prompt: LocalizedStringKey, text: Binding<String>, action: @escaping () -> Void) {
        self.init(prompt: prompt, text: text, action: action) { EmptyView() }
    }
}

/// An optional date under an `EditorField` label: a "Set …" button while
/// empty, then the picker with a clear control. One control for every
/// date that may legitimately be absent — birth, diagnosis, end of a
/// regimen, insurance expiry, a todo's due date.
struct EditorDateField: View {
    @Binding var date: Date?
    var setTitle: LocalizedStringKey = "Set date"
    var clearTitle: LocalizedStringKey = "Clear date"
    var defaultDate: () -> Date = { Date() }

    var body: some View {
        if let current = date {
            HStack(spacing: Chrome.Space.sm) {
                DatePicker(setTitle, selection: Binding(
                    get: { date ?? current },
                    set: { date = $0 }
                ), displayedComponents: .date)
                .labelsHidden()
                Button {
                    date = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(clearTitle)
                .accessibilityLabel(clearTitle)
            }
        } else {
            Button {
                date = defaultDate()
            } label: {
                Label(setTitle, systemImage: "calendar.badge.plus")
            }
        }
    }
}

/// A status pill that is also a menu: click it to pick another value in
/// place, without disclosing the whole row.
struct StatusPillMenu<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [Value]
    let title: (Value) -> String
    let tint: (Value) -> Color
    var help: LocalizedStringKey = "Change"

    var body: some View {
        Menu {
            ForEach(options, id: \.self) { option in
                Button {
                    selection = option
                } label: {
                    if option == selection {
                        Label(title(option), systemImage: "checkmark")
                    } else {
                        Text(verbatim: title(option))
                    }
                }
            }
        } label: {
            StatusPill(text: title(selection), tint: tint(selection))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(help)
        .accessibilityLabel(help)
        .accessibilityValue(Text(verbatim: title(selection)))
    }
}

/// Multi-line text area drawn as a box, so it reads as an input like the
/// bezeled fields beside it rather than as a blank patch of card.
struct EditorTextArea: View {
    @Binding var text: String
    var minHeight: CGFloat = 120

    var body: some View {
        TextEditor(text: $text)
            .font(.body)
            .frame(minHeight: minHeight)
            .scrollContentBackground(.hidden)
            .background(Chrome.editorFill, in: RoundedRectangle(cornerRadius: Chrome.Radius.card))
            .overlay(
                RoundedRectangle(cornerRadius: Chrome.Radius.card)
                    .strokeBorder(Chrome.chipFillStrong)
            )
    }
}

/// Popup that links a record to a patient. Offers "None", the assignable
/// patients, and a stand-in entry for a linked patient the directory no
/// longer lists, so the selection is never silently reset.
struct LinkedPatientPicker: View {
    @Binding var selection: UUID?
    /// Must already include the current selection when it is archived.
    let options: [Patient]
    /// Whether the directory still knows a patient by id.
    let isKnown: (UUID) -> Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Chrome.Space.xs + 2) {
            Picker("Patient", selection: $selection) {
                Text("None").tag(UUID?.none)
                ForEach(options) { patient in
                    Text(DisplayCopy.patient(patient))
                        .tag(UUID?.some(patient.id))
                }
                if let id = selection, !isKnown(id) {
                    Text("Unknown patient").tag(UUID?.some(id))
                }
            }
            .labelsHidden()

            if let id = selection, !isKnown(id) {
                Text("Linked patient is not in the current list.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }
}

/// Editable tag chips that wrap onto as many lines as they need, with the
/// shared add row beneath. Notes and todos share it, so tags are entered and
/// removed the same way in both.
struct TagEditor: View {
    @Binding var tags: [String]
    var prompt: LocalizedStringKey = "Add a tag"

    @State private var newTag = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Chrome.Space.sm) {
            if !tags.isEmpty {
                FlowLayout {
                    ForEach(tags, id: \.self) { tag in
                        TagChip(text: tag) {
                            tags.removeAll { $0 == tag }
                        }
                    }
                }
            }
            EditorAddRow(prompt: prompt, text: $newTag, action: add)
        }
    }

    private func add() {
        let tag = newTag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tag.isEmpty, !tags.contains(tag) else { return }
        tags.append(tag)
        newTag = ""
    }
}
