import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var session: AppSession

    var body: some View {
        List(selection: $session.selectedModule) {
            Section {
                ForEach(AppModule.allCases) { module in
                    let count = session.sidebarCount(for: module)
                    Label {
                        Text(module.title)
                    } icon: {
                        IconBadge(systemImage: module.icon, tint: Chrome.moduleTint(module))
                    }
                    // Native sidebar badge: it hides itself at zero and picks
                    // up the system's selected-row and vibrancy treatment,
                    // which a hand-placed trailing Text never does.
                    .badge(module == .graph ? 0 : count)
                    .tag(module)
                    .accessibilityLabel(module.title)
                    .accessibilityValue(accessibilityCount(for: module, count: count))
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle(Self.windowTitle)
    }

    /// Carries into the window title, so a seeded window is identifiable from
    /// the Dock and Window menu as well as from the banner. Release builds have
    /// no seeded mode, and no string saying they might.
    private static var windowTitle: String {
        #if DEBUG
        return PreviewSeed.isActive ? "MedNotes — SAMPLE DATA" : "MedNotes"
        #else
        return "MedNotes"
        #endif
    }

    /// The sidebar count means different things per module (total / pending /
    /// upcoming), so the spoken value must too — a zero pending count must not
    /// claim the Todos list is empty when completed todos exist.
    private func accessibilityCount(for module: AppModule, count: Int) -> String {
        switch module {
        case .notes, .patients:
            return count == 0 ? String(localized: "Empty") : "\(count)"
        case .todos:
            return count == 0 ? String(localized: "No pending") : String(localized: "\(count) pending")
        case .calendar:
            return count == 0 ? String(localized: "No upcoming") : String(localized: "\(count) upcoming")
        case .graph:
            return ""
        }
    }
}
