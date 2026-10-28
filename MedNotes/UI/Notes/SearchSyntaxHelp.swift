import SwiftUI

/// The notes search syntax, as a popover from the search field.
struct SearchSyntaxHelp: View {
    private struct Entry: Identifiable {
        let id: String
        let example: String
        let meaning: LocalizedStringKey
    }

    private static let entries: [Entry] = [
        Entry(id: "phrase", example: "\"chest pain\"", meaning: "An exact phrase"),
        Entry(id: "or", example: "digoxin OR apixaban", meaning: "Either word. OR needs capitals; quote it to search for the word"),
        Entry(id: "not", example: "-warfarin", meaning: "Leave out notes with a word"),
        Entry(id: "group", example: "(a OR b) -c", meaning: "Group terms with brackets"),
        Entry(id: "tag", example: "tag:cardio", meaning: "Notes with a tag, nested tags included"),
        Entry(id: "property", example: "property:status", meaning: "Notes that have a property"),
        Entry(id: "value", example: "[status:active]", meaning: "Notes where a property has a value"),
        Entry(id: "patient", example: "patient:\"Nikos Georgiou\"", meaning: "Notes about a patient"),
        Entry(id: "linked", example: "linked:Plan", meaning: "Notes that link to a note or patient")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Chrome.Space.sm) {
            Text("Search syntax")
                .font(.headline)
            ForEach(Self.entries) { entry in
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.example)
                        .font(.system(.callout, design: .monospaced))
                    Text(entry.meaning)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(Chrome.Space.md)
        .frame(width: 280, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}

/// The button that opens `SearchSyntaxHelp`.
struct SearchSyntaxHelpButton: View {
    @State private var shown = false

    var body: some View {
        Button {
            shown.toggle()
        } label: {
            Image(systemName: "questionmark.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Search syntax")
        .accessibilityLabel("Search syntax")
        .popover(isPresented: $shown, arrowEdge: .bottom) { SearchSyntaxHelp() }
    }
}
