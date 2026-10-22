import AppKit
import SwiftUI
import XCTest

/// Hosts a SwiftUI view off screen the way `scripts/render_editors.swift`
/// does, and walks the real `NSView` tree underneath it. SwiftUI backs its
/// macOS text fields, pop-up buttons and switches with AppKit views, so the
/// subview tree is enough to check structure — and, unlike the accessibility
/// tree, it has no cycles. Never walk the accessibility tree in-process: it
/// cycles and hangs the whole test run.
@MainActor
final class OffscreenHost {
    private var windows: [NSWindow] = []

    func host<V: View>(_ view: V, width: CGFloat = 744, height: CGFloat = 960) -> NSHostingView<AnyView> {
        // Top-aligned: a view with a height of its own (the Settings panes)
        // sits where the window would put it, not centred in the host.
        let root = AnyView(
            view.frame(width: width, height: height, alignment: .top)
                .background(Color(nsColor: .windowBackgroundColor)))
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(
            contentRect: NSRect(x: -20000, y: -20000, width: width, height: height),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFrontRegardless()
        windows.append(window)
        // Let SwiftUI and the table-backed Form settle before inspecting.
        for _ in 0..<3 {
            hosting.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        }
        return hosting
    }

    /// Hosts a view as a window's whole content, with no frame or background
    /// of our own, so whatever the view leaves undrawn stays transparent in
    /// `cornerAlphas`. In the test host the window then shrinks to a view that
    /// does not fill it (a real `WindowGroup` window keeps its size), so only
    /// a view that fills its window keeps the size it was given.
    func hostAsWindowContent<V: View>(_ view: V, width: CGFloat, height: CGFloat) -> NSHostingView<AnyView> {
        let hosting = NSHostingView(rootView: AnyView(view))
        let window = NSWindow(
            contentRect: NSRect(x: -20000, y: -20000, width: width, height: height),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFrontRegardless()
        windows.append(window)
        for _ in 0..<3 {
            hosting.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        }
        return hosting
    }

    /// Hosts `view` in a window that keys can be typed into: `NSApp.sendEvent`
    /// routes a key to it and on to its first responder, as AppKit routes
    /// typing. Made key, it still leaves the test host inactive.
    /// Throws, having sent no key down, unless a key up reaches it first: a key
    /// down with nowhere to go makes the host beep on the owner's Mac, and a
    /// key up never beeps.
    func hostForTyping<V: View>(_ view: V, width: CGFloat = 1280, height: CGFloat = 820) throws -> TypingWindow {
        let size = NSRect(x: 0, y: 0, width: width, height: height)
        let hosting = NSHostingView(rootView: AnyView(view.frame(width: width, height: height)))
        hosting.frame = size
        let window = TypingWindow(contentRect: size.offsetBy(dx: -20000, dy: -20000),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.contentView = hosting
        guard !window.overlapsAScreen else { throw TypingWindow.Unsafe.onScreen }
        window.orderFrontRegardless()
        windows.append(window)
        guard window.screen == nil, !window.overlapsAScreen else {
            window.orderOut(nil)
            throw TypingWindow.Unsafe.onScreen
        }
        for _ in 0..<3 {
            hosting.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        }
        window.makeKey()
        try window.probeKeyRouting()
        return window
    }

    func tearDown() {
        windows.forEach { $0.orderOut(nil) }
        windows = []
    }

    // MARK: - Structure

    /// Placeholders of every text field in the view tree.
    static func placeholders(under root: NSView) -> Set<String> {
        var found = Set<String>()
        walk(root) { view in
            if let field = view as? NSTextField {
                let placeholder = field.placeholderString
                    ?? field.placeholderAttributedString?.string ?? ""
                if !placeholder.isEmpty { found.insert(placeholder) }
            }
        }
        return found
    }

    /// The text every text field shows — a form's value column, in effect.
    static func fieldValues(under root: NSView) -> [String] {
        var found: [String] = []
        walk(root) { view in
            if let field = view as? NSTextField, !field.stringValue.isEmpty {
                found.append(field.stringValue)
            }
        }
        return found
    }

    /// The text of every text view — a `TextEditor`'s body, in a form.
    static func textViewContents(under root: NSView) -> [String] {
        var found: [String] = []
        walk(root) { view in
            if let textView = view as? NSTextView, !textView.string.isEmpty {
                found.append(textView.string)
            }
        }
        return found
    }

    /// What each pop-up button currently shows.
    static func popUpTitles(under root: NSView) -> [String] {
        var found: [String] = []
        walk(root) { view in
            if let popUp = view as? NSPopUpButton {
                found.append(popUp.titleOfSelectedItem ?? popUp.title)
            }
        }
        return found
    }

    /// Whether each switch-style toggle is on. Read from the control, not the
    /// bitmap: an offscreen capture draws the knob in its resting position
    /// whatever the state, because the on-state is a layer animation
    /// `cacheDisplay` never sees.
    static func switchStates(under root: NSView) -> [Bool] {
        var states: [Bool] = []
        walk(root) { view in
            if let toggle = view as? NSSwitch {
                states.append(toggle.state == .on)
            }
        }
        return states
    }

    /// True when the drawn bitmap is more than the flat window background.
    static func hasInk(_ view: NSView) -> Bool {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: rep)
        var colors = Set<UInt32>()
        let step = 6
        var y = 0
        while y < rep.pixelsHigh {
            var x = 0
            while x < rep.pixelsWide {
                if let color = rep.colorAt(x: x, y: y) {
                    let key = UInt32(color.redComponent * 255) << 16
                        | UInt32(color.greenComponent * 255) << 8
                        | UInt32(color.blueComponent * 255)
                    colors.insert(key)
                    if colors.count > 24 { return true }
                }
                x += step
            }
            y += step
        }
        return colors.count > 24
    }

    /// Alpha of the drawn bitmap 4 px in from each corner (top left, top
    /// right, bottom left, bottom right). Under `hostAsWindowContent` a corner
    /// nothing covers reads 0.
    static func cornerAlphas(_ view: NSView) -> [CGFloat] {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return [] }
        view.cacheDisplay(in: view.bounds, to: rep)
        let right = rep.pixelsWide - 5, bottom = rep.pixelsHigh - 5
        return [(4, 4), (right, 4), (4, bottom), (right, bottom)].map { point in
            rep.colorAt(x: point.0, y: point.1)?.alphaComponent ?? 0
        }
    }

    /// The drawn colour at `point`, in points from the view's top left.
    static func color(at point: CGPoint, in view: NSView) -> NSColor? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds),
              view.bounds.width > 0 else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        return rep.colorAt(x: Int(point.x * scale), y: Int(point.y * scale))?.usingColorSpace(.sRGB)
    }

    /// Pre-order, first subview first, so values come back in reading order.
    private static func walk(_ root: NSView, _ visit: (NSView) -> Void) {
        var pending: [NSView] = [root]
        var visited = 0
        while let view = pending.popLast(), visited < 20_000 {
            visited += 1
            visit(view)
            pending.append(contentsOf: view.subviews.reversed())
        }
    }
}

/// A borderless off-screen window that can be key; see
/// `OffscreenHost.hostForTyping`. Not titled: AppKit moved a titled window at
/// x -20000 onto the external display, where it showed for about a second.
@MainActor
final class TypingWindow: NSWindow {
    enum Unsafe: Error { case onScreen, keysGoElsewhere }

    /// The type of every event AppKit sent this window.
    private(set) var received: [NSEvent.EventType] = []

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    /// Stays where it was put, off every screen.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    override func sendEvent(_ event: NSEvent) {
        received.append(event.type)
        super.sendEvent(event)
    }

    var overlapsAScreen: Bool { NSScreen.screens.contains { $0.frame.intersects(frame) } }

    /// Delivers a key the way `NSApp.run` does: posted, dequeued, sent. While
    /// it is handled `NSApp.currentEvent` is that key, as in the app, and the
    /// session reads it to tell typing from dictation. `NSApp.sendEvent` alone
    /// leaves the previous event current.
    ///
    /// Key status can move between keys, say to another of the host's windows
    /// the owner clicked, and a key down that lands there beeps. A key up
    /// never does, so one goes first to prove where keys go now.
    func deliver(_ type: NSEvent.EventType, _ characters: String, isARepeat: Bool = false) throws {
        if type == .keyDown { try probeKeyRouting() }
        try send(type, characters, isARepeat: isARepeat)
    }

    /// Throws unless a key up sent now reaches this window.
    func probeKeyRouting() throws {
        let before = received.count
        try send(.keyUp, "")
        guard received.count > before, received.last == .keyUp else { throw Unsafe.keysGoElsewhere }
    }

    private func send(_ type: NSEvent.EventType, _ characters: String, isARepeat: Bool = false) throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: isARepeat, keyCode: 40))
        NSApp.postEvent(event, atStart: true)
        let next = try XCTUnwrap(NSApp.nextEvent(matching: [.keyDown, .keyUp], until: Date(timeIntervalSinceNow: 1),
                                                  inMode: .default, dequeue: true))
        NSApp.sendEvent(next)
    }

    /// A key pressed and released.
    func type(_ characters: String) throws {
        try deliver(.keyDown, characters)
        try deliver(.keyUp, characters)
    }
}
