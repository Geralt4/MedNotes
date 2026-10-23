import SwiftUI

/// File › Import Legacy Data…: a dry run into a scratch store first, its
/// report on screen, and only then the real import — after a restore point.
struct ImportFlowSheet: View {
    @EnvironmentObject private var session: AppSession
    let flow: AppSession.ImportFlow

    @State private var report: ImportReport?
    @State private var isWorking = false
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Chrome.Space.lg) {
            Label("Import Legacy Data", systemImage: "square.and.arrow.down.on.square")
                .font(.title3.weight(.semibold))
            Text(verbatim: flow.folderURL.path)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
            Text("The folder is read first into a scratch copy, so the report below is exactly what the import would do. Nothing is written to your records until you choose Import, and a restore point is kept before that.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let report {
                reportView(report)
            }
            if isWorking {
                ProgressView()
                    .controlSize(.small)
            }
            if let failure {
                Text(verbatim: failure)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel") { session.dismissImportFlow() }
                    .keyboardShortcut(.cancelAction)
                if report == nil {
                    Button("Check Folder") { dryRun() }
                        .keyboardShortcut(.defaultAction)
                        .prominentActionButtonStyle()
                        .disabled(isWorking)
                } else {
                    Button("Import") { run() }
                        .keyboardShortcut(.defaultAction)
                        .prominentActionButtonStyle()
                        .disabled(isWorking || (report?.totalImported ?? 0) == 0)
                }
            }
        }
        .padding(Chrome.Space.xl)
        .frame(width: 520)
        .controlSize(.large)
        .onAppear { dryRun() }
    }

    private func reportView(_ report: ImportReport) -> some View {
        VStack(alignment: .leading, spacing: Chrome.Space.sm) {
            Text(verbatim: Self.summary(of: report))
                .font(.headline)
            if report.filesSkipped > 0 {
                Text("\(report.filesSkipped) files skipped")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if !report.warnings.isEmpty {
                DisclosureGroup {
                    ScrollView {
                        VStack(alignment: .leading, spacing: Chrome.Space.xs) {
                            ForEach(Array(report.warnings.prefix(200).enumerated()), id: \.offset) { _, warning in
                                Text(verbatim: warning)
                                    .font(.caption)
                                    .textSelection(.enabled)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 160)
                } label: {
                    Text("\(report.warnings.count) warnings")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }
            if !report.errors.isEmpty {
                ForEach(Array(report.errors.prefix(10).enumerated()), id: \.offset) { _, error in
                    Text(verbatim: error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
            if report.totalImported == 0 {
                if report.errors.isEmpty {
                    Text("Nothing new to import: every record in the folder is already in MedNotes.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Nothing was imported. See the errors above.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(Chrome.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Chrome.editorFill, in: RoundedRectangle(cornerRadius: Chrome.Radius.card))
    }

    private func dryRun() {
        guard !isWorking else { return }
        isWorking = true
        failure = nil
        Task {
            do {
                report = try await session.dryRunImport(from: flow.folderURL)
            } catch {
                failure = error.localizedDescription
            }
            isWorking = false
        }
    }

    private func run() {
        isWorking = true
        failure = nil
        Task {
            do {
                try await session.performImport(from: flow.folderURL)
            } catch {
                failure = error.localizedDescription
            }
            isWorking = false
        }
    }

    static func summary(of report: ImportReport) -> String {
        let parts = [
            (report.patientsImported, String(localized: "patients")),
            (report.notesImported, String(localized: "notes")),
            (report.todosImported, String(localized: "todos")),
            (report.eventsImported, String(localized: "events"))
        ]
        return parts.map { "\($0.0) \($0.1)" }.joined(separator: " · ")
    }
}
