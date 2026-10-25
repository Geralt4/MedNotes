import SwiftUI

/// Settings › General: which module the window opens on, and the current
/// security posture. The continuous Markdown mirror is retired; the one-time
/// "Export Markdown Vault…" operation lives in the File menu and Data pane.
struct GeneralSettingsPane: View {
    @Binding var launchModule: LaunchModule
    /// True while the store is encrypted and unlocked. The pane only reports
    /// the state; locking is an app-lifecycle action.
    let isEncrypted: Bool
    /// Locking is mandatory after five minutes; the note states the policy.
    let idleMinutes: Int

    /// A grouped form fills whatever height it is given rather than hugging
    /// its rows, so each pane names its own and the Settings window takes it.
    /// Sized for the Greek strings, which run longer than the English:
    /// measured in the live Greek window, the content needs 402 pt.
    static let height: CGFloat = 415

    var body: some View {
        Form {
            Section {
                Picker("At launch, open", selection: $launchModule) {
                    Text("Where I left off").tag(LaunchModule.lastUsed)
                    Divider()
                    ForEach(AppModule.allCases) { module in
                        Text(module.title).tag(LaunchModule.fixed(module))
                    }
                }
                .accessibilityIdentifier(SettingsIdentifiers.launchPicker)
            } header: {
                DetailSectionHeader(title: "Launch", systemImage: "macwindow")
            } footer: {
                SettingsNote("MedNotes opens on this module. “Where I left off” returns to whichever module was showing when it last quit.")
            }

            Section {
                // Values as Text, so they are localised: `value:` takes a
                // String and shows it verbatim, inflection markup included.
                LabeledContent("Store") {
                    Text(isEncrypted ? "Encrypted" : "Plaintext")
                }
                .accessibilityIdentifier(SettingsIdentifiers.storeState)
                LabeledContent("Locks after") {
                    Text("^[\(idleMinutes) minutes](inflect: true) without activity")
                }
                .accessibilityIdentifier(SettingsIdentifiers.lockInterval)
            } header: {
                DetailSectionHeader(title: "Security", systemImage: "lock.shield")
            } footer: {
                VStack(alignment: .leading, spacing: Chrome.Space.sm) {
                    SettingsNote("The database, attachments and restore points are encrypted with a key held in the macOS Keychain, which requires Touch ID or your account password. MedNotes locks when the screen locks or sleeps, when you switch users, after \(idleMinutes) minutes without activity, and on request.")
                    SettingsNote("Data still leaves the app in three deliberate ways: records you send to Calendar or Reminders, a Markdown export you run yourself, and an attachment you open in another app. Each one is confirmed before it happens.")
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: Self.height)
    }
}

/// The explanatory paragraph under a settings card, as its section's footer:
/// footnote size, secondary, wrapping, so the controls above stay the focus.
/// Every pane has several, and a grouped form's default row text does not
/// wrap on its own.
struct SettingsNote: View {
    private let text: Text

    /// UI wording — a literal, localised through the strings catalog.
    init(_ key: LocalizedStringKey) {
        text = Text(key)
    }

    /// Data — an error message, a path — shown as is.
    init(verbatim value: String) {
        text = Text(verbatim: value)
    }

    var body: some View {
        text
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
