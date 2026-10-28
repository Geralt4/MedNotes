import SwiftUI

/// The two Apple bridges as the UI names them: wording, the privacy pane
/// that grants their access, and the one place that opens it.
enum SyncBridge {
    case calendar
    case reminders

    /// Anchor of the System Settings › Privacy & Security pane to open when
    /// access was refused.
    var privacyPane: String {
        switch self {
        case .calendar: return "Privacy_Calendars"
        case .reminders: return "Privacy_Reminders"
        }
    }

    func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(privacyPane)") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    /// The pill menu's status line.
    func menuStatus(_ access: SyncBridgeAccess) -> LocalizedStringKey {
        switch (self, access) {
        case (.calendar, .granted): return "Apple Calendar: connected"
        case (.calendar, .denied): return "Apple Calendar: permission denied"
        case (.calendar, .notRequested): return "Apple Calendar: not connected"
        case (.reminders, .granted): return "Apple Reminders: connected"
        case (.reminders, .denied): return "Apple Reminders: permission denied"
        case (.reminders, .notRequested): return "Apple Reminders: not connected"
        }
    }

    /// The pill's tooltip, with the last pass appended once connected.
    func help(_ access: SyncBridgeAccess, summary: String?) -> String {
        let tail = summary.map { " — \($0)" } ?? ""
        switch (self, access) {
        case (.calendar, .granted): return String(localized: "Apple Calendar connected") + tail
        case (.calendar, .denied): return String(localized: "Calendar permission denied")
        case (.calendar, .notRequested): return String(localized: "Not connected to Apple Calendar yet")
        case (.reminders, .granted): return String(localized: "Apple Reminders connected") + tail
        case (.reminders, .denied): return String(localized: "Reminders permission denied")
        case (.reminders, .notRequested): return String(localized: "Not connected to Apple Reminders yet")
        }
    }
}

extension SyncBridgeAccess {
    /// The Sync tab's status text.
    var title: LocalizedStringKey {
        switch self {
        case .granted: return "Connected"
        case .denied: return "Permission denied"
        case .notRequested: return "Not connected"
        }
    }

    /// One colour for the pill dot and the Sync tab.
    var tint: Color {
        switch self {
        case .granted: return .green
        case .denied: return .red
        case .notRequested: return .orange
        }
    }
}

/// Toolbar pill + menu for a bridge, in the Calendar and Todos modules. The
/// pill reflects the access state; the menu exposes connect/request and a
/// manual sync pass. Settings › Sync explains the same state at length.
struct SyncPillMenu<Service: SyncBridgeService>: View {
    let bridge: SyncBridge
    @ObservedObject var service: Service
    let summary: String?
    let onSync: () -> Void

    var body: some View {
        Menu {
            Button("Sync Now", action: onSync)
            Divider()
            Text(bridge.menuStatus(service.state))
            if service.state == .granted, let summary {
                Text(verbatim: summary)
            }
            if service.state == .denied {
                Button("Open System Settings") {
                    bridge.openSystemSettings()
                }
            }
        } label: {
            HStack(spacing: 4) {
                Circle()
                    .fill(service.state.tint)
                    .frame(width: 7, height: 7)
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.callout)
            }
        }
        .menuStyle(.button)
        // Hidden for the same reason as the filter's: the disclosure chevron
        // is ~12pt of cluster width, and the cluster overhanging the detail
        // pane is what pushes the leading item onto the split divider. What
        // this is drops out of the tooltip and the menu itself.
        .menuIndicator(.hidden)
        .fixedSize()
        .help(bridge.help(service.state, summary: summary))
    }
}
