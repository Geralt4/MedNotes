import AppKit
import SwiftUI

/// Offscreen row renderer for reviewing the list-row polish without any TCC
/// grant. `screencapture` needs Screen Recording and System Events needs
/// Accessibility; both are the user's to give, and neither is needed here.
///
/// Scope is deliberate. `NoteRowView` and `PatientRowView` are driven purely by
/// their model, so they render standalone. `TodoRowView` and `EventRowView`
/// declare `@EnvironmentObject var session: AppSession`, and `AppSession.init`
/// starts a bootstrap that resolves `DataRoot.applicationSupport()` — in this
/// unsandboxed host that is the *real* store path, outside the app container and
/// past every guard in the harness. So this tool never constructs an
/// `AppSession`, and those two rows are reviewed in the live app instead.
@main
enum RenderRows {

    /// The app's accent lives in an asset catalog this host does not compile,
    /// so `.tint` would fall back to system blue and misrepresent the pin glyph.
    /// Values copied from `Assets.xcassets/AccentColor.colorset`.
    static let accentLight = Color(.sRGB, red: 0.051, green: 0.478, blue: 0.447)
    static let accentDark = Color(.sRGB, red: 0.239, green: 0.812, blue: 0.761)

    /// `ViewThatFits` picks the *widest* candidate that fits, so an unconstrained
    /// render would show three chips every time and the `+n` path would never
    /// execute. These are the column widths the real split view spans.
    static let widths: [CGFloat] = [220, 320, 480]

    @MainActor
    static func main() {
        let outputDirectory = URL(fileURLWithPath: CommandLine.arguments.count > 1
            ? CommandLine.arguments[1]
            : FileManager.default.currentDirectoryPath, isDirectory: true)
        try? FileManager.default.createDirectory(
            at: outputDirectory, withIntermediateDirectories: true)

        let anchor = SampleData.anchor(for: Date())
        let patients = SampleData.makePatients(anchor: anchor)
        // Mirrors `Database.loadAllNotes` (`ORDER BY is_pinned DESC, updated_at
        // DESC`) so the sheet reads like the real list. This reproduces that
        // order, it does not test it — the ordering itself is a live-app check.
        let notes = SampleData.makeNotes(anchor: anchor, patients: patients)
            .sorted {
                $0.isPinned == $1.isPinned
                    ? $0.updatedAt > $1.updatedAt
                    : $0.isPinned && !$1.isPinned
            }

        var written = 0
        for scheme in [ColorScheme.light, .dark] {
            for width in widths {
                written += emit(
                    rows: notes, kind: "notes", width: width, scheme: scheme,
                    into: outputDirectory) { NoteRowView(note: $0) }
                written += emit(
                    rows: patients, kind: "patients", width: width, scheme: scheme,
                    into: outputDirectory) { PatientRowView(patient: $0) }
            }
        }

        print("✅ wrote \(written) PNG(s) to \(outputDirectory.path)")
        print("   Rows covered: NoteRowView, PatientRowView.")
        print("   Todo and Event rows need the live app — they read AppSession.")
        print("   Caveat: this host compiles no asset catalog, so `Color.accentColor`")
        print("   (the patient monogram) falls back to system blue. Anything using")
        print("   `.tint` — the pin glyph — is faithful. Judge accent colour live.")
    }

    @MainActor
    private static func emit<Model: Identifiable, Row: View>(
        rows: [Model], kind: String, width: CGFloat, scheme: ColorScheme,
        into directory: URL, @ViewBuilder row: @escaping (Model) -> Row
    ) -> Int {
        let isDark = scheme == .dark
        let content = VStack(alignment: .leading, spacing: 0) {
            ForEach(rows) { model in
                row(model)
                    .padding(.horizontal, Chrome.Space.md)
                    .padding(.vertical, Chrome.Space.xs)
                Divider().opacity(0.5)
            }
        }
        .frame(width: width, alignment: .leading)
        .padding(.vertical, Chrome.Space.sm)
        .background(isDark ? Color(white: 0.12) : Color(white: 0.98))
        .environment(\.colorScheme, scheme)
        .tint(isDark ? accentDark : accentLight)

        let renderer = ImageRenderer(content: content)
        renderer.scale = 2

        let name = "\(kind)-\(Int(width))-\(isDark ? "dark" : "light").png"
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            print("⚠️  could not render \(name)")
            return 0
        }
        do {
            try png.write(to: directory.appendingPathComponent(name))
            return 1
        } catch {
            print("⚠️  could not write \(name): \(error.localizedDescription)")
            return 0
        }
    }
}
