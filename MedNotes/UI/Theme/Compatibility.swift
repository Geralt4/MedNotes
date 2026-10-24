import SwiftUI

// MARK: - Compatibility shims
//
// MedNotes targets macOS 14 (Sonoma). Two pieces of polish are macOS 26 only
// and degrade to no-ops below it, so the app still runs on 14 and 15.

// MARK: Soft top scroll edge effect (macOS 26+)

/// Applies a soft scroll-edge effect at the top of a scrollable view on
/// macOS 26+. On older systems this is a no-op.
struct SoftTopEdgeModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            content
        }
    }
}

extension View {
    /// Soft scroll-edge effect at the top on macOS 26+, no-op below.
    func softTopEdge() -> some View {
        modifier(SoftTopEdgeModifier())
    }

    /// Pins `bar` above a list. On macOS 26+ it is a safe-area *bar*, the
    /// API for controls above scrolling content: the soft top edge then
    /// treats it as a bar and blurs only the rows scrolling under it.
    @ViewBuilder
    func topBar<Bar: View>(@ViewBuilder _ bar: () -> Bar) -> some View {
        if #available(macOS 26.0, *) {
            safeAreaBar(edge: .top, content: bar)
        } else {
            safeAreaInset(edge: .top, content: bar)
        }
    }
}

// MARK: Empty states

/// `ContentUnavailableView` with the app's two ways of saying what is
/// missing: localised wording, or a message that is data (an error string).
struct EmptyStateView: View {
    let title: LocalizedStringKey
    let systemImage: String
    private let description: Text
    var actionTitle: LocalizedStringKey? = nil
    var action: (() -> Void)? = nil

    /// UI wording: the description is a literal, localised through the catalog.
    init(title: LocalizedStringKey, systemImage: String, description: LocalizedStringKey,
         actionTitle: LocalizedStringKey? = nil, action: (() -> Void)? = nil) {
        self.title = title
        self.systemImage = systemImage
        self.description = Text(description)
        self.actionTitle = actionTitle
        self.action = action
    }

    /// Data — an error message from the backend, say — shown as is.
    init(title: LocalizedStringKey, systemImage: String, message: String,
         actionTitle: LocalizedStringKey? = nil, action: (() -> Void)? = nil) {
        self.title = title
        self.systemImage = systemImage
        self.description = Text(verbatim: message)
        self.actionTitle = actionTitle
        self.action = action
    }

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            description
        } actions: {
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .prominentActionButtonStyle()
            }
        }
    }

    /// Search-specific empty state that echoes the query.
    static func search(text: String) -> some View {
        ContentUnavailableView.search(text: text)
    }
}

// MARK: Toolbar spacer (macOS 26+)

/// A toolbar spacer that works on macOS 14. On macOS 26+ it uses the native
/// `ToolbarSpacer`; below it inserts a fixed-width spacer item.
struct ToolbarSpacerCompat: ToolbarContent {
    var body: some ToolbarContent {
        if #available(macOS 26.0, *) {
            ToolbarSpacer(.fixed)
        } else {
            ToolbarItem(placement: .primaryAction) {
                Color.clear.frame(width: 8)
            }
        }
    }
}
