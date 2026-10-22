import SwiftUI

/// The privacy curtain for what the main window's curtain cannot reach: the
/// Activity and Settings windows, and the sheets over the main window, which
/// AppKit draws above anything in it.
///
/// It covers while the store is locked or the app is inactive. The migration
/// and recovery screens run only in the main window; no record is open then.
/// A lock also dismisses the main window's sheets, so over a sheet this is
/// only ever the inactive-app curtain.
private struct PrivacyCover: ViewModifier {
    @ObservedObject var session: AppSession

    private var isCovered: Bool {
        session.isLocked || session.isObscured
    }

    func body(content: Content) -> some View {
        // Hidden from accessibility too, not only from sight.
        content.accessibilityHidden(isCovered).overlay {
            if isCovered {
                ZStack {
                    Rectangle()
                        .fill(.regularMaterial)
                        .ignoresSafeArea()
                    VStack(spacing: Chrome.Space.md) {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 28, weight: .regular))
                            .foregroundStyle(.secondary)
                        Text("MedNotes is locked")
                            .font(.title3.weight(.semibold))
                        Button("Unlock") {
                            Task { await session.unlock() }
                        }
                        .keyboardShortcut(.defaultAction)
                        .prominentActionButtonStyle()
                    }
                    .padding(Chrome.Space.xl)
                }
                .transition(.opacity)
            }
        }
        // The session keeps keyboard focus out of this window while covered.
        .background(WindowReader { session.coverWindow($0) })
        // Activation itself is the session's (`observeAppActivation`), so this
        // covers with the main window closed too. A window restored by a
        // launch in the background never sees a resign-active; like the main
        // window, it takes the curtain's first state from here.
        .onAppear {
            session.windowDidAppear(appIsActive: NSApp.isActive)
        }
        // Working in these windows postpones the idle lock, as in the main one.
        .onContinuousHover { _ in session.noteInteraction() }
    }
}

extension View {
    /// Covers this window or sheet while the store is locked or the app is
    /// inactive; see `PrivacyCover`.
    func privacyCover(_ session: AppSession) -> some View {
        modifier(PrivacyCover(session: session))
    }
}
