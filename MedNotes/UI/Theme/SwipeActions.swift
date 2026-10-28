import SwiftUI
import AppKit

// MARK: - Swipe to delete
//
// SwiftUI ships `.swipeActions`, but on macOS the modifier is inert: the
// AppKit list backing never wires it up, so a two-finger swipe across a row
// does nothing at all. (Probed on macOS 26 — a List whose only difference was
// the modifier rendered no action under a synthesized trackpad swipe, while
// the same synthetic gesture scrolled a control view, so the null result was
// the modifier and not the harness.) Mail, Notes and Reminders get the
// affordance from AppKit's `NSTableViewRowAction`, which a SwiftUI `List`
// gives no way to reach. So the gesture is rebuilt here, on top of the scroll
// events the trackpad already sends.
//
// A swipe repaints at the refresh rate of the display, which leaves about
// 8 ms per event on a 120 Hz panel. Two things in the obvious implementation
// spend most of that on nothing, and both are avoided below:
//
//   * Revealing the action by animating its `frame` width makes every event a
//     layout pass, and a layout pass inside a `List` row invites the list to
//     re-measure. The action is drawn at a fixed size and moved with
//     `offset` instead, which is draw-time only.
//   * An `@Published` translation invalidates every row observing the
//     controller, so a swipe on one row re-evaluates all of them. Rows hand
//     the controller a setter for their own reveal instead, and only the row
//     that moved is touched.
//
// Measured together on a 40-row list: 4.22 ms mean / 6.10 ms p90 per event
// before, 0.54 ms mean / 0.99 ms p90 after, and 22 row bodies per event down
// to 1.

/// One list's swipe state: the row under the pointer, the row that is open,
/// and how far the in-flight gesture has travelled.
///
/// One controller per list, which is what keeps a single row open at a time —
/// swiping a second row closes the first, the way Mail does.
///
/// `ObservableObject` only so a view can own one with `@StateObject`; nothing
/// here is `@Published`, on purpose. See the note above.
///
/// Deliberately not `@MainActor`: local event monitors are delivered on the
/// main thread anyway, and the annotation would only make the monitor closure
/// unable to call in.
final class SwipeRevealController: ObservableObject {
    /// Width the action settles to when a swipe is released past `openDistance`.
    static let actionWidth: CGFloat = 76

    /// Released past this, the swipe deletes outright instead of settling open.
    ///
    /// Measured against the row rather than fixed, because "full swipe" means
    /// sweeping the action across the row — at which point the row is entirely
    /// red and the outcome is legible before the fingers lift. Real swipes on
    /// this trackpad run 110 to 400 points, so any fixed number either put the
    /// delete out of reach or swallowed the button reveal.
    private var commitDistance: CGFloat { max(150, rowWidth * 0.7) }

    /// Width of a row, reported by the rows themselves. The default stands in
    /// until the first one lays out.
    var rowWidth: CGFloat = 260

    /// How far ahead the release velocity is projected when deciding whether
    /// a swipe was a flick to delete or a drag to open. This is what separates
    /// the two: a flick commits from half the distance a slow drag needs.
    private static let velocityProjection: CGFloat = 0.07
    /// Released past this, the row settles open rather than springing back.
    private static let openDistance: CGFloat = 34
    /// How far one axis must lead the other before the gesture commits to it.
    ///
    /// A lead, not an absolute distance. This trackpad delivers around 38
    /// points per event, so any threshold measured against travel alone is
    /// settled by the first event of the swipe — and a swipe that opened with
    /// a little downward drift locked to vertical and threw the remaining
    /// several hundred points of horizontal travel away. That was a coin flip
    /// on every attempt.
    private static let axisSlop: CGFloat = 6
    /// How the reveal springs when it is not tracking the fingers directly.
    private static let settleAnimation = Animation.spring(response: 0.28, dampingFraction: 0.86)

    /// The open (or mid-swipe) row, and its translation — 0 at rest, negative
    /// to the left.
    private(set) var activeId: UUID?
    private(set) var translation: CGFloat = 0

    /// What a committed swipe does. Set by the list, because every row in a
    /// list deletes the same way — by id.
    var onCommit: ((UUID) -> Void)?

    /// Row under the pointer. A scroll event carries a window location, not a
    /// row, and hover is how SwiftUI answers "which row is that?" without
    /// converting between its own flipped space and AppKit's.
    private var hoveredId: UUID?
    /// True while the pointer sits on a revealed action, so the click that
    /// presses Delete is not also read as the click that dismisses it.
    private var pointerOnAction = false

    private struct Sink {
        let token: Int
        let apply: (CGFloat) -> Void
    }
    private var sinks: [UUID: Sink] = [:]
    private var nextToken = 0

    private var monitor: Any?
    private var axis: Axis?
    private var travelX: CGFloat = 0
    private var travelY: CGFloat = 0
    private var gestureId: UUID?
    private var gestureBase: CGFloat = 0
    /// A horizontal gesture is driving a row and has not been released yet.
    private var awaitingRelease = false
    private var releaseBackstop: DispatchWorkItem?
    /// Quiet time after the last movement that counts as a release, for the
    /// gestures that report neither an `.ended` phase nor a coast. Without it
    /// such a swipe leaves the row stranded part-open until the next one.
    private static let releaseTimeout: TimeInterval = 0.15
    private var lastEventTime: TimeInterval = 0
    /// Points per second, negative to the left, smoothed so that one jittery
    /// frame cannot be the thing that decides a delete.
    private var velocity: CGFloat = 0

    /// True only while a horizontal gesture is actually driving a row. A
    /// sideways swipe over empty list space owns nothing, and its events go
    /// through untouched rather than being quietly eaten.
    private var ownsGesture: Bool { axis == .horizontal && gestureId != nil }

    deinit {
        // `onDisappear` is the normal path, but it is not guaranteed to run.
        // Only the monitor is torn down here.
        if let monitor { NSEvent.removeMonitor(monitor) }
        releaseBackstop?.cancel()
    }

    // MARK: Row-facing

    /// Registers a row's reveal setter and hands back a token to unbind with.
    func bind(_ id: UUID, apply: @escaping (CGFloat) -> Void) -> Int {
        nextToken += 1
        sinks[id] = Sink(token: nextToken, apply: apply)
        // A row scrolled back into view while its own swipe is still open
        // needs the current value; every other row is already at rest.
        let current = revealed(for: id)
        if current != 0 { apply(current) }
        return nextToken
    }

    /// Token-checked, because a list recycling rows can report the old one
    /// gone only after the new one has already bound the same id.
    func unbind(_ id: UUID, token: Int) {
        guard sinks[id]?.token == token else { return }
        sinks[id] = nil
        // A row removed under the pointer gets no hover exit.
        if hoveredId == id { hoveredId = nil }
    }

    func revealed(for id: UUID) -> CGFloat {
        activeId == id ? -translation : 0
    }

    func hover(_ id: UUID, isInside: Bool) {
        if isInside {
            hoveredId = id
        } else if hoveredId == id {
            hoveredId = nil
        }
    }

    func hoverAction(_ isInside: Bool) {
        pointerOnAction = isInside
    }

    func commit(_ id: UUID) {
        close()
        onCommit?(id)
    }

    func close() {
        pointerOnAction = false
        guard activeId != nil else { return }
        withAnimation(Self.settleAnimation) {
            move(to: nil, translation: 0)
        }
    }

    /// The single place `activeId`/`translation` change, so the row leaving and
    /// the row arriving are both told exactly once.
    private func move(to newId: UUID?, translation newValue: CGFloat) {
        if let old = activeId, old != newId { sinks[old]?.apply(0) }
        activeId = newId
        translation = newValue
        if let newId { sinks[newId]?.apply(-newValue) }
    }

    // MARK: Event monitoring

    func startMonitoring() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.scrollWheel, .leftMouseDown]
        ) { [weak self] event in
            self?.handle(event) ?? event
        }
    }

    func stopMonitoring() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        releaseBackstop?.cancel()
        releaseBackstop = nil
        awaitingRelease = false
        move(to: nil, translation: 0)
        hoveredId = nil
        pointerOnAction = false
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .leftMouseDown:
            // A click on the revealed Delete belongs to the button. Anything
            // else puts the row back. The event still goes through, so that
            // click also selects the row it landed on — an open row is not a
            // mode you have to click your way out of first.
            if !pointerOnAction { close() }
            return event
        case .scrollWheel:
            return handleScroll(event)
        default:
            return event
        }
    }

    private func handleScroll(_ event: NSEvent) -> NSEvent? {
        SwipeDiagnostics.event(phase: event.phase.rawValue,
                               momentum: event.momentumPhase.rawValue,
                               dx: event.scrollingDeltaX, dy: event.scrollingDeltaY)
        // Momentum keeps arriving after the fingers lift. The row has already
        // settled by then, so a horizontal gesture eats its own coast rather
        // than letting the list drift on the vertical component of it.
        guard event.momentumPhase.isEmpty else {
            guard ownsGesture else { return event }
            // The coast starting *is* the release. macOS does not reliably
            // send a `.ended` phase before momentum: on this trackpad most
            // gestures go straight from `.changed` into the coast, and a swipe
            // that waited for `.ended` never settled at all — no delete, no
            // reveal, nothing. That was the "swipe two or three times and
            // hope" bug, and it hid behind a threshold that was never the
            // problem.
            settleIfNeeded()
            if event.momentumPhase.contains(.ended)
                || event.momentumPhase.contains(.cancelled) {
                axis = nil
            }
            return nil
        }

        if event.phase.contains(.began) {
            // Backstop: a gesture that saw neither `.ended` nor a coast still
            // has to let go of the row before the next one starts.
            settleIfNeeded()
            beginGesture(at: event.timestamp)
            return event
        }

        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            lastEventTime = event.timestamp
            guard ownsGesture else {
                axis = nil
                return event
            }
            settleIfNeeded()
            // `axis` stays horizontal so any momentum is swallowed above.
            return nil
        }

        guard event.phase.contains(.changed) else {
            // A plain mouse wheel sends no phases, and cannot swipe. Nothing
            // to track, so it scrolls.
            return event
        }

        // A gesture arrives as a dense burst. A gap this long means the last
        // one finished without its `.ended` reaching us — a dropped event, or
        // a monitor installed mid-swipe. Start clean rather than staying
        // locked to an axis nobody is swiping along any more.
        if event.timestamp - lastEventTime > 0.25 {
            beginGesture(at: event.timestamp)
        }
        let dt = event.timestamp - lastEventTime
        if dt > 0 {
            velocity = velocity * 0.6 + (event.scrollingDeltaX / dt) * 0.4
        }
        lastEventTime = event.timestamp

        travelX += event.scrollingDeltaX
        travelY += event.scrollingDeltaY

        if axis == nil {
            // Whichever axis is leading, not whichever crossed a fixed
            // distance first. See `axisSlop`.
            let lead = abs(travelX) - abs(travelY)
            if lead > Self.axisSlop {
                axis = .horizontal
                // Read the row now rather than at `.began`: by the time the
                // swipe has committed to an axis, hover has certainly caught
                // up with the pointer.
                gestureId = hoveredId
                // Swiping a row that is already open carries on from where it
                // sits, instead of snapping shut for the first 76 points.
                gestureBase = (hoveredId != nil && hoveredId == activeId) ? translation : 0
                awaitingRelease = gestureId != nil
                SwipeDiagnostics.axisLocked(horizontal: true, travelX: travelX,
                                            travelY: travelY, row: gestureId != nil)
            } else if -lead > Self.axisSlop {
                axis = .vertical
                SwipeDiagnostics.axisLocked(horizontal: false, travelX: travelX,
                                            travelY: travelY, row: hoveredId != nil)
                // Scrolling the list away from an open row closes it.
                close()
            }
        }

        guard ownsGesture, let id = gestureId else { return event }

        // No animation while the fingers are down: the reveal is the gesture,
        // not a response to it.
        move(to: id, translation: curve(gestureBase + travelX))
        // A pause may have let the backstop settle this gesture; this movement needs its own release.
        awaitingRelease = true
        armReleaseBackstop()
        return nil
    }

    private func beginGesture(at time: TimeInterval) {
        SwipeDiagnostics.began()
        releaseBackstop?.cancel()
        releaseBackstop = nil
        axis = nil
        travelX = 0
        travelY = 0
        gestureId = nil
        gestureBase = 0
        awaitingRelease = false
        velocity = 0
        lastEventTime = time
    }

    private func settleIfNeeded() {
        releaseBackstop?.cancel()
        releaseBackstop = nil
        guard awaitingRelease else { return }
        awaitingRelease = false
        settle()
    }

    /// Rearmed on every movement event, so it only fires once the fingers have
    /// actually stopped feeding the gesture.
    private func armReleaseBackstop() {
        releaseBackstop?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.settleIfNeeded() }
        releaseBackstop = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.releaseTimeout, execute: work)
    }

    private func settle() {
        guard let id = activeId else { return }
        // Where the swipe was going, not where it stopped. A quick flick and a
        // slow drag can end at the same point and mean different things.
        let projected = translation + velocity * Self.velocityProjection
        if projected <= -commitDistance {
            SwipeDiagnostics.settled(outcome: "DELETE", translation: translation,
                                     travelX: travelX, velocity: velocity)
            commit(id)
        } else if translation <= -Self.openDistance {
            SwipeDiagnostics.settled(outcome: "open", translation: translation,
                                     travelX: travelX, velocity: velocity)
            withAnimation(Self.settleAnimation) {
                move(to: id, translation: -Self.actionWidth)
            }
        } else {
            SwipeDiagnostics.settled(outcome: "sprang back", translation: translation,
                                     travelX: travelX, velocity: velocity)
            close()
        }
    }

    /// There are no leading actions, so a rightward swipe goes nowhere. Past
    /// the commit line the action runs *ahead* of the fingers and sweeps
    /// across the row, so crossing the point of no return reads as reaching
    /// the end rather than as the swipe stalling against resistance.
    private func curve(_ x: CGFloat) -> CGFloat {
        guard x < 0 else { return 0 }
        guard x < -commitDistance else { return x }
        return -commitDistance + (x + commitDistance) * 2.2
    }
}

// MARK: - Row

/// A list row with a Delete action that a two-finger swipe to the left
/// uncovers along its trailing edge.
struct SwipeToDeleteRow<Content: View>: View {
    @Environment(\.swipeController) private var swipe

    /// Driven by the controller through `bind`, so a swipe repaints this row
    /// alone rather than every row sharing the controller.
    @State private var revealed: CGFloat = 0
    @State private var token = 0

    /// Wider than any sidebar column, so a deep swipe never runs out of red.
    /// Fixed, because the reveal is a translation and not a resize — and only
    /// its rounded leading corners are ever on screen, the trailing pair
    /// sitting far off the edge of the row.
    private static var panelWidth: CGFloat { 600 }

    let id: UUID
    /// Spoken by VoiceOver and shown as the action's tooltip — "Delete note"
    /// rather than a bare "Delete", since the row is the only context.
    let label: LocalizedStringKey
    /// The panel's glyph, colour and word; patients archive rather than delete.
    let symbol: String
    let tint: Color
    let word: LocalizedStringKey
    let content: Content

    private var isOpen: Bool {
        abs(revealed - SwipeRevealController.actionWidth) < 0.5
    }

    var body: some View {
        content
            // Claim the full row width before the action is anchored to it. A
            // row whose content happens not to stretch would otherwise pin the
            // action to the end of its text rather than the edge of the list.
            .frame(maxWidth: .infinity, alignment: .leading)
            // The row holds still and the action slides in over its trailing
            // edge, the way Mail does. Translating the row instead — the iOS
            // behaviour — would drag the title off the leading edge of a
            // sidebar this narrow, and the title is the part worth keeping.
            .overlay(alignment: .trailing) {
                // The panel is 600pt wide so a deep swipe never runs out of
                // red, which puts its own trailing corners far off the row —
                // they can never round. This container is the row's width, so
                // clipping to a rounded rectangle here is what gives the
                // action a trailing edge to match its leading one. Without it
                // the action reads as a shape sliced off at the divider.
                Color.clear
                    .overlay(alignment: .trailing) {
                        panel
                            .frame(width: Self.panelWidth)
                            .offset(x: max(0, Self.panelWidth - revealed))
                    }
                    .clipShape(RoundedRectangle(cornerRadius: Chrome.Radius.badge,
                                                style: .continuous))
                    // A hair of inset, so the action sits inside the list's
                    // rhythm instead of butting into the rows either side.
                    .padding(.vertical, 1)
                    // Purely paint: the strip that takes the click is the
                    // separate, unclipped target below.
                    .allowsHitTesting(false)
            }
            .clipped()
            .overlay(alignment: .trailing) {
                // Only clickable once the row has settled open, which keeps
                // this geometry changing twice a gesture rather than every
                // frame — and means a closed row has nothing invisible parked
                // over its trailing edge waiting to swallow a click.
                if isOpen {
                    Button { swipe?.commit(id) } label: {
                        Color.clear.contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .frame(width: SwipeRevealController.actionWidth)
                    .onHover { swipe?.hoverAction($0) }
                    .help(label)
                    // The row already carries this as an accessibility action.
                    .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
            // The commit distance is measured against the row, so the row is
            // what reports it. Only fires when the column is resized.
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { swipe?.rowWidth = proxy.size.width }
                        .onChange(of: proxy.size.width) { _, width in swipe?.rowWidth = width }
                }
            )
            .onHover { swipe?.hover(id, isInside: $0) }
            .accessibilityAction(named: Text(label)) { swipe?.commit(id) }
            .onAppear { token = swipe?.bind(id) { revealed = $0 } ?? 0 }
            .onDisappear { swipe?.unbind(id, token: token) }
    }

    private var panel: some View {
        RoundedRectangle(cornerRadius: Chrome.Radius.badge, style: .continuous)
            .fill(tint)
            // The label goes in an overlay so it can never drive the panel's
            // height. A freshly made todo is one line tall — a stack sized to
            // its own content stood taller than the row and was cut off at
            // both ends, glyph shaved off the top and word off the bottom.
            .overlay(alignment: .leading) {
                ViewThatFits(in: .vertical) {
                    VStack(spacing: Chrome.Space.xxs) {
                        glyph
                        Text(word).font(.caption2.weight(.semibold))
                    }
                    .padding(.vertical, Chrome.Space.xxs)
                    // A row too short for the word keeps the glyph, which is
                    // the half that still reads at this size.
                    glyph
                }
                .foregroundStyle(.white)
                // Pinned to the panel's leading end, the part a swipe uncovers
                // first. A deeper swipe carries it left with the panel, the
                // way a full swipe expands on iOS.
                .frame(width: SwipeRevealController.actionWidth)
            }
    }

    private var glyph: some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .semibold))
    }
}

// MARK: - Attaching

extension View {
    /// Reveals a Delete action when this row is swiped to the left.
    ///
    /// Apply *before* `.tag(_:)`, so the tag stays the outermost trait and
    /// list selection still finds it. `symbol`, `tint` and `word` restyle the
    /// panel for a row whose swipe archives instead.
    func swipeToDelete(id: UUID, label: LocalizedStringKey,
                       symbol: String = "trash.fill",
                       tint: Color = Color(nsColor: .systemRed),
                       word: LocalizedStringKey = "Delete") -> some View {
        SwipeToDeleteRow(id: id, label: label, symbol: symbol, tint: tint, word: word, content: self)
    }

    /// Hosts a list's swipe controller: the scroll monitor that drives the
    /// gesture, and what a committed swipe deletes.
    func swipeToDeleteContainer(
        _ controller: SwipeRevealController,
        onDelete: @escaping (UUID) -> Void
    ) -> some View {
        modifier(SwipeToDeleteContainer(controller: controller, onDelete: onDelete))
    }
}

private struct SwipeToDeleteContainer: ViewModifier {
    let controller: SwipeRevealController
    let onDelete: (UUID) -> Void

    func body(content: Content) -> some View {
        content
            // Plain environment rather than `environmentObject`: rows must not
            // subscribe to the controller, or every one of them repaints on
            // every event of a swipe.
            .environment(\.swipeController, controller)
            .onAppear {
                controller.onCommit = onDelete
                controller.startMonitoring()
            }
            .onDisappear {
                controller.stopMonitoring()
                // The closure captures the owning view, which holds this
                // controller: left set, neither is ever released. `onAppear`
                // sets it again.
                controller.onCommit = nil
            }
    }
}

private struct SwipeControllerKey: EnvironmentKey {
    static let defaultValue: SwipeRevealController? = nil
}

extension EnvironmentValues {
    var swipeController: SwipeRevealController? {
        get { self[SwipeControllerKey.self] }
        set { self[SwipeControllerKey.self] = newValue }
    }
}
