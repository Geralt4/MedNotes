import AppKit
import SwiftUI
import XCTest
@testable import MedNotes

/// ⌘⌫ is the Delete command's key equivalent, and menu key equivalents are
/// matched before the focused view sees the key. `DeleteShortcut` hands the
/// shortcut back to editable text; these check both halves of that split
/// against real AppKit and SwiftUI text views hosted off screen, and that
/// only the main window, while nothing covers it, enables the command.
@MainActor
final class DeleteShortcutTests: XCTestCase {
    private var windows: [NSWindow] = []
    /// The session's preferences: never the host's own, which are the
    /// owner's. One fixed suite, emptied around every test. See `TestDefaults`.
    private static let defaultsName = "MedNotesTests.DeleteShortcut"
    private var defaults: UserDefaults!

    override func setUp() {
        defaults = TestDefaults.suite(Self.defaultsName)
    }

    override func tearDown() {
        windows.forEach { $0.orderOut(nil) }
        windows = []
        TestDefaults.clear(Self.defaultsName)
    }

    // MARK: - Routing

    func testCommandDeleteInEditableTextGoesToTheText() throws {
        let textView = NSTextView()
        XCTAssertIdentical(
            DeleteShortcut.textView(for: Self.commandDelete(), firstResponder: textView), textView)
        XCTAssertIdentical(
            DeleteShortcut.textView(for: try Self.hardwareCommandDelete(), firstResponder: textView), textView)
        // U+0008 itself, the character SwiftUI's `KeyEquivalent.delete` holds.
        XCTAssertIdentical(
            DeleteShortcut.textView(for: Self.key("\u{8}", .command), firstResponder: textView), textView)
    }

    func testEverythingElseDeletesTheRecord() {
        let textView = NSTextView()
        // A click on the menu item: no key press behind it.
        XCTAssertNil(DeleteShortcut.textView(for: nil, firstResponder: textView))
        XCTAssertNil(DeleteShortcut.textView(for: Self.mouseDown(), firstResponder: textView))
        // Another key, ⌫ without ⌘ (a stale event from typing), a key-up.
        XCTAssertNil(DeleteShortcut.textView(for: Self.key("a", .command), firstResponder: textView))
        XCTAssertNil(DeleteShortcut.textView(for: Self.key("\u{7F}", []), firstResponder: textView))
        XCTAssertNil(DeleteShortcut.textView(for: Self.commandDelete(type: .keyUp), firstResponder: textView))
        // A list, nothing focused, or text that cannot be edited.
        XCTAssertNil(DeleteShortcut.textView(for: Self.commandDelete(), firstResponder: NSTableView()))
        XCTAssertNil(DeleteShortcut.textView(for: Self.commandDelete(), firstResponder: nil))
        textView.isEditable = false
        XCTAssertNil(DeleteShortcut.textView(for: Self.commandDelete(), firstResponder: textView))
    }

    // MARK: - Performing

    func testShortcutInNoteBodyDeletesToStartOfLine() throws {
        let text = TextBox("First line\nsecond line")
        let window = host(TextEditor(text: Binding(get: { text.value }, set: { text.value = $0 })))
        let textView = try XCTUnwrap(Self.first(NSTextView.self, in: window.contentView))
        XCTAssertTrue(window.makeFirstResponder(textView))
        // Caret after "second": only what is before it on that line goes.
        textView.setSelectedRange(NSRange(location: ("First line\nsecond" as NSString).length, length: 0))

        var recordDeletes = 0
        DeleteShortcut.perform(for: Self.commandDelete(), in: window) { recordDeletes += 1 }
        settle(window)
        XCTAssertEqual(recordDeletes, 0)
        XCTAssertEqual(textView.string, "First line\n line")
        // The edit reaches the binding, so the draft that gets saved has it.
        XCTAssertEqual(text.value, "First line\n line")

        // Choosing Edit › Delete with the mouse still means the record.
        DeleteShortcut.perform(for: nil, in: window) { recordDeletes += 1 }
        XCTAssertEqual(recordDeletes, 1)
        XCTAssertEqual(textView.string, "First line\n line")
    }

    func testShortcutInTextFieldGoesToItsFieldEditor() throws {
        let title = TextBox("Ward rounds")
        let window = host(TextField("Title", text: Binding(get: { title.value }, set: { title.value = $0 })))
        let field = try XCTUnwrap(Self.first(NSTextField.self, in: window.contentView))
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView, "no field editor")
        // Focusing selects all; a caret mid-word shows it is the line start
        // that the shortcut deletes to, not the selection.
        editor.setSelectedRange(NSRange(location: ("Ward " as NSString).length, length: 0))

        var recordDeletes = 0
        DeleteShortcut.perform(for: Self.commandDelete(), in: window) { recordDeletes += 1 }
        settle(window)
        XCTAssertEqual(recordDeletes, 0)
        XCTAssertEqual(editor.string, "rounds")
        XCTAssertEqual(title.value, "rounds")
    }

    func testShortcutOnAListDeletesTheRecord() {
        let window = host(Color.clear)
        let table = NSTableView()
        window.contentView?.addSubview(table)
        XCTAssertTrue(window.makeFirstResponder(table))

        var recordDeletes = 0
        DeleteShortcut.perform(for: Self.commandDelete(), in: window) { recordDeletes += 1 }
        DeleteShortcut.perform(for: Self.commandDelete(), in: nil) { recordDeletes += 1 }
        XCTAssertEqual(recordDeletes, 2)
    }

    // MARK: - Which window owns the command

    /// Why disabling Edit › Delete outside the main window is enough: a
    /// disabled item does not claim its key equivalent, so ⌘⌫ goes on to the
    /// focused list or text field. Both ways AppKit disables an item.
    func testADisabledDeleteItemLeavesTheKeyToTheFocusedView() throws {
        let target = MenuTarget()
        let menu = NSMenu()
        // SwiftUI's `KeyEquivalent.delete`, as the Commands button has it.
        let item = menu.addItem(withTitle: "Delete", action: #selector(MenuTarget.fire(_:)), keyEquivalent: "\u{8}")
        item.keyEquivalentModifierMask = .command
        item.target = target
        let press = try Self.hardwareCommandDelete()

        target.isEnabled = false
        XCTAssertFalse(menu.performKeyEquivalent(with: press), "a validated-off item claimed ⌘⌫")
        menu.autoenablesItems = false
        item.isEnabled = false
        XCTAssertFalse(menu.performKeyEquivalent(with: press), "a disabled item claimed ⌘⌫")
        XCTAssertEqual(target.fired, 0)

        item.isEnabled = true
        XCTAssertTrue(menu.performKeyEquivalent(with: press))
        XCTAssertEqual(target.fired, 1)
    }

    /// `MedNotesCommands` enables Delete only while the key window publishes
    /// a command. The main window withdraws it while it cannot ask, and
    /// Settings and Activity never publish one.
    func testMainWindowPublishesTheCommandOnlyWhileItCanAsk() async throws {
        let root = try DataRoot.temporary()
        defer { try? FileManager.default.removeItem(at: root.rootURL) }
        let session = AppSession.testSession(dataRoot: root, defaults: defaults)
        try await waitUntil("the session is ready") { session.isReady || session.initError != nil }
        XCTAssertNil(session.initError)
        session.selectedModule = .notes

        let seen = CommandBox()
        let offscreen = OffscreenHost()
        defer { offscreen.tearDown() }
        _ = offscreen.host(
            ZStack { ContentView(); DeleteCommandProbe(seen: seen) }.environmentObject(session),
            width: 1000, height: 600)
        // The test host is usually inactive, and a window that appears then
        // stays covered until the app becomes active. This one stands in for
        // the key window.
        session.appDidBecomeActive()
        try await waitUntil("the probe has read the value") { seen.updates > 0 }
        XCTAssertNil(seen.command, "published with nothing selected")

        await session.newNote()
        try await waitUntil("the command is published") { seen.command != nil }
        session.showSwitcher = true
        try await waitUntil("the switcher withdraws it") { seen.command == nil }
        session.showSwitcher = false
        try await waitUntil("closing the switcher publishes it again") { seen.command != nil }
        let command = try XCTUnwrap(seen.command)
        offscreen.tearDown()

        // A click on the menu item: it asks about the selected record.
        command.perform(for: nil, in: nil)
        XCTAssertTrue(session.confirmDelete)
    }

    func testPublishedCommandStillHandsTheShortcutToText() throws {
        let title = TextBox("Ward rounds")
        let window = host(TextField("Title", text: Binding(get: { title.value }, set: { title.value = $0 })))
        let field = try XCTUnwrap(Self.first(NSTextField.self, in: window.contentView))
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView, "no field editor")
        editor.setSelectedRange(NSRange(location: ("Ward " as NSString).length, length: 0))

        var recordDeletes = 0
        let command = DeleteCommand { recordDeletes += 1 }
        command.perform(for: Self.commandDelete(), in: window)
        settle(window)
        XCTAssertEqual(recordDeletes, 0)
        XCTAssertEqual(title.value, "rounds")
        command.perform(for: nil, in: window)
        XCTAssertEqual(recordDeletes, 1)
    }

    // MARK: - Helpers

    /// Reads the value the way `MedNotesCommands` does. A focused scene value
    /// is visible to every view in the window, whatever has focus.
    private struct DeleteCommandProbe: View {
        @FocusedValue(\.deleteCommand) private var command
        let seen: CommandBox

        var body: some View {
            Color.clear
                .allowsHitTesting(false)
                .onChange(of: command != nil, initial: true) { _, _ in
                    seen.command = command
                    seen.updates += 1
                }
        }
    }

    private final class CommandBox {
        var command: DeleteCommand?
        var updates = 0
    }

    private final class MenuTarget: NSObject, NSMenuItemValidation {
        var isEnabled = true
        var fired = 0
        @objc func fire(_ sender: Any?) { fired += 1 }
        func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { isEnabled }
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 5,
                           _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("timed out waiting until \(what)")
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private final class TextBox {
        var value: String
        init(_ value: String) { self.value = value }
    }

    private func host<V: View>(_ view: V) -> NSWindow {
        let hosting = NSHostingView(rootView: view.frame(width: 400, height: 200))
        hosting.frame = NSRect(x: 0, y: 0, width: 400, height: 200)
        let window = NSWindow(
            contentRect: NSRect(x: -20000, y: -20000, width: 400, height: 200),
            // Borderless: AppKit moves a titled window at x -20000 onto a screen.
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFrontRegardless()
        windows.append(window)
        XCTAssertFalse(NSScreen.screens.contains { $0.frame.intersects(window.frame) },
                       "the test window must stay off every screen")
        settle(window)
        return window
    }

    private func settle(_ window: NSWindow) {
        for _ in 0..<3 {
            window.contentView?.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
    }

    private static func first<T: NSView>(_ type: T.Type, in view: NSView?) -> T? {
        guard let view else { return nil }
        if let match = view as? T { return match }
        for subview in view.subviews {
            if let found = first(type, in: subview) { return found }
        }
        return nil
    }

    /// ⌘⌫ built the way the window server delivers it (virtual key 51):
    /// this is the event AppKit matches to the menu's U+0008 key equivalent.
    private static func hardwareCommandDelete() throws -> NSEvent {
        let press = try XCTUnwrap(CGEvent(
            keyboardEventSource: CGEventSource(stateID: .privateState), virtualKey: 51, keyDown: true))
        press.flags = .maskCommand
        return try XCTUnwrap(NSEvent(cgEvent: press))
    }

    private static func commandDelete(type: NSEvent.EventType = .keyDown) -> NSEvent {
        key("\u{7F}", .command, type: type)
    }

    private static func key(
        _ characters: String, _ modifiers: NSEvent.ModifierFlags,
        type: NSEvent.EventType = .keyDown) -> NSEvent {
        NSEvent.keyEvent(
            with: type, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: 0, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false,
            keyCode: characters == "\u{7F}" ? 51 : 0)!
    }

    private static func mouseDown() -> NSEvent {
        NSEvent.mouseEvent(
            with: .leftMouseDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }
}
