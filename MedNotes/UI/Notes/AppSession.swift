import Combine
import SwiftUI
import UniformTypeIdentifiers


@MainActor
final class AppSession: ObservableObject {
    enum LinkedDeletionError: LocalizedError {
        case reminders, calendar

        var errorDescription: String? {
            switch self {
            case .reminders: return String(localized: "Reconnect Apple Reminders before deleting this linked todo.")
            case .calendar: return String(localized: "Reconnect Apple Calendar before deleting this linked event.")
            }
        }
    }
    @Published private(set) var isReady = false
    @Published private(set) var initError: String?
    /// Remembered on every change, so “Where I left off” has something to
    /// return to. Assignments in `init` do not run the observer, which is
    /// what keeps a launch from overwriting the value it is reading.
    @Published var selectedModule: AppModule = .patients {
        didSet { defaults.set(selectedModule.rawValue, forKey: Self.lastModuleDefaultsKey) }
    }

    /// Bumped by the Find command. The list column's search field focuses
    /// itself on every change, which is what `.searchable` used to give us
    /// before the field moved out of the toolbar.
    @Published private(set) var searchFocusToken = 0

    func focusSearch() { searchFocusToken += 1 }

    @Published var notes: [Note] = []
    @Published var selectedNoteId: UUID?
    @Published var noteEpoch = 0
    /// The matched line of each listed note while a search is active.
    @Published var noteSnippets: [UUID: SearchSnippet] = [:]
    /// Every tag with the notes it covers, for the Tags menu.
    @Published var noteTags: [TagCount] = []
    /// The tag (its key) the notes list is narrowed to, together with the
    /// search text; nil lists every note.
    @Published var noteTagFilter: String? {
        didSet {
            guard noteTagFilter != oldValue else { return }
            Task { await reload() }
        }
    }
    @Published var searchText = "" {
        didSet { scheduleSearch() }
    }
    @Published var errorMessage: String?

    @Published var patients: [Patient] = []
    @Published var patientDirectory: [Patient] = []
    @Published var selectedPatientId: UUID?
    @Published var patientEpoch = 0
    /// Active patients by default; the archived list is where restore and
    /// permanent deletion live. Switching lists drops the selection, since the
    /// selected record is by definition not in the other list.
    @Published var patientFilter: PatientFilter = .active {
        didSet {
            guard patientFilter != oldValue else { return }
            selectedPatientId = nil
            Task { await reloadPatients() }
        }
    }
    @Published var patientSearchText = "" {
        didSet { schedulePatientSearch() }
    }

    var assignablePatients: [Patient] {
        patientDirectory.filter { !$0.isArchived }
    }

    /// Patients shown in assignment pickers. Always includes the currently
    /// linked patient so SwiftUI does not reset a selection that is archived
    /// or missing from the active list.
    func assignmentPatients(including selectedId: UUID?) -> [Patient] {
        var list = assignablePatients
        if let selectedId,
           !list.contains(where: { $0.id == selectedId }),
           let extra = patientDirectory.first(where: { $0.id == selectedId }) {
            list.append(extra)
        }
        return list
    }

    @Published var todos: [TodoItem] = []
    @Published var selectedTodoId: UUID?
    @Published var todoSearchText = "" {
        didSet { scheduleTodoSearch() }
    }
    @Published var todoFilter: TodoFilter = .all {
        didSet {
            guard todoFilter != oldValue else { return }
            Task { await reloadTodos() }
        }
    }
    @Published var todoEpoch = 0
    @Published var todoPoolCount = 0

    @Published var events: [CalendarEvent] = []
    @Published var selectedEventId: UUID?
    @Published var eventSearchText = "" {
        didSet { scheduleEventSearch() }
    }
    @Published var eventFilter: EventFilter = .upcoming {
        didSet {
            guard eventFilter != oldValue else { return }
            Task { await reloadEvents() }
        }
    }
    @Published var eventEpoch = 0
    @Published var eventPoolCount = 0

    @Published var sidebarNoteCount = 0
    @Published var sidebarPatientCount = 0
    @Published var sidebarPendingTodoCount = 0
    @Published var sidebarUpcomingEventCount = 0
    @Published var confirmDelete = false

    // MARK: Quick switcher (⌘O)

    struct SwitcherHit: Identifiable, Hashable {
        enum Kind: String {
            case note
            case patient
            case event
            case todo
        }
        let id: UUID
        let kind: Kind
        let title: String
        let subtitle: String
    }

    @Published var showSwitcher = false {
        didSet { if showSwitcher { switcherText = "" } }
    }
    @Published var switcherText = "" {
        didSet {
            scheduleSwitcherSearch()
        }
    }
    @Published var switcherResults: [SwitcherHit] = []

    // MARK: Wiki-links & graph

    @Published var linksOut: [LinkingService.OutgoingLink] = []
    @Published var unlinkedMentions: [(noteId: UUID, title: String)] = []
    @Published var backlinks: [(noteId: UUID, title: String)] = []
    @Published var graphData = LinkingService.GraphData()
    /// The graph's settings panel. They live in the encrypted store, since a
    /// filter or group is often a patient's name; they are read when the store
    /// opens and dropped when it locks.
    @Published var graphSettings = GraphSettings() {
        didSet {
            guard graphSettings != oldValue else { return }
            scheduleGraphSettingsSave(Self.globalGraphKey)
            graphSettingsChanged(from: oldValue)
        }
    }
    /// The graph the settings leave: what the canvas draws and the list in
    /// the middle column names, worked out once here for both.
    @Published var filteredGraph = FilteredGraph()
    /// Whether the graph's settings panel is open (no patient data in it).
    @Published var graphPanelShown: Bool {
        didSet { defaults.set(graphPanelShown, forKey: Self.graphPanelDefaultsKey) }
    }
    static let graphPanelDefaultsKey = "graphPanelShown"
    var graphMatching: Set<String>?
    var graphGroupMatches: [UUID: Set<String>] = [:]
    var graphQueryTask: Task<Void, Never>?
    /// The same, for the open note's local graph.
    @Published var localGraphSettings = GraphSettings() {
        didSet { if localGraphSettings != oldValue { scheduleGraphSettingsSave(Self.localGraphKey) } }
    }
    static let globalGraphKey = "graph.global"
    static let localGraphKey = "graph.local"
    var graphSettingsLoaded = false
    var graphSaveTasks: [String: Task<Void, Never>] = [:]

    // MARK: Apple Calendar bridge

    let appleCalendar = AppleCalendarService()
    @Published var lastCalendarSyncSummary: String?

    // MARK: Apple Reminders bridge

    let appleReminders = AppleRemindersService()
    @Published var lastRemindersSyncSummary: String?

    /// Snapshot of what the module-scoped delete confirmation will delete.
    /// Captured when the dialog is requested so a module or selection change
    /// while the dialog is up cannot redirect the deletion.
    ///
    /// Lifecycle: set by `requestDelete()`, consumed and cleared by
    /// `deleteInCurrentModule()`'s defer. Cancelling the dialog leaves the
    /// snapshot in place; it is harmless because every presentation path
    /// re-snapshots before raising the dialog again.
    struct PendingDeletion {
        let module: AppModule
        let id: UUID
        /// Patients archive unless they are already archived; everything
        /// else is deleted for good.
        let isPermanent: Bool
    }
    @Published var pendingDeletion: PendingDeletion?

    private(set) var store: AppStore?
    var searchTask: Task<Void, Never>?
    var patientSearchTask: Task<Void, Never>?
    var todoSearchTask: Task<Void, Never>?
    var eventSearchTask: Task<Void, Never>?
    var switcherTask: Task<Void, Never>?
    /// Supersedes a lookup still in flight when the query changes again.
    var switcherGeneration = 0
    var calendarObserverTask: Task<Void, Never>?
    var remindersObserverTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    var notesReloadGeneration = 0
    var patientsReloadGeneration = 0
    var todosReloadGeneration = 0
    var eventsReloadGeneration = 0

    // MARK: - Settings (ADR 0001)

    /// Where preferences live. Injected so a test session never reads or
    /// writes the host's real defaults.
    let defaults: UserDefaults

    static let launchModuleDefaultsKey = "launchModule"
    static let lastModuleDefaultsKey = "lastModule"
    static let calendarAutoSyncDefaultsKey = "calendarAutoSync"
    static let remindersAutoSyncDefaultsKey = "remindersAutoSync"
    static let defaultNoteTemplateDefaultsKey = "defaultNoteTemplate"
    static let noteInspectorDefaultsKey = "noteInspectorShown"

    /// Whether the note's right-hand inspector (links, outline, properties) is
    /// open. Kept in the preferences the session was given; open by default.
    @Published var noteInspectorShown: Bool {
        didSet { defaults.set(noteInspectorShown, forKey: Self.noteInspectorDefaultsKey) }
    }

    /// Which module the window opens on; the Settings picker binds to it.
    @Published var launchModule: LaunchModule {
        didSet { defaults.set(launchModule.storageValue, forKey: Self.launchModuleDefaultsKey) }
    }

    /// Whether a granted bridge moves data on its own — pushes on every
    /// save, pulls on every change EventKit reports. On by default, which is
    /// how the bridges have always behaved; off, only Sync Now moves data.
    /// Deletes are not gated: a synced row deleted here loses its Apple copy
    /// at once either way, or the next pass would bring it back as new.
    @Published var calendarAutoSyncEnabled: Bool
    @Published var remindersAutoSyncEnabled: Bool

    /// Settings › Templates › "New notes start from": the template a new
    /// note is seeded with, or nil for a blank one. Deleting that template
    /// clears it.
    @Published var defaultNoteTemplateID: String? {
        didSet {
            if let defaultNoteTemplateID {
                defaults.set(defaultNoteTemplateID, forKey: Self.defaultNoteTemplateDefaultsKey)
            } else {
                defaults.removeObject(forKey: Self.defaultNoteTemplateDefaultsKey)
            }
        }
    }

    /// What `newNote()` seeded into each note still considered new, so a
    /// templated note left untouched is discarded like a blank one.
    var seededNoteContent: [UUID: String] = [:]

    /// The record editors on screen, by the token each registered with, and
    /// how to read each one's draft. `closeStore` reads them all before it
    /// detaches the store; see `OpenEditorDraft`.
    var openEditors: [UUID: () -> OpenEditorDraft?] = [:]

    /// The open store's layout, once `bootstrap` has resolved it.
    private(set) var dataRoot: DataRoot?

    // MARK: - Device keys, lock state and migration

    private(set) var coordinator: SecureStoreCoordinator?

    /// True while the store is intentionally obscured or torn down.
    @Published private(set) var isLocked = false {
        didSet {
            recordsCoverDidChange()
            if isLocked { focusParking.dropEdits() }
        }
    }
    @Published private(set) var isMigrating = false
    @Published private(set) var migrationReport: StoreMigrator.MigrationReport?
    @Published private(set) var needsRecovery = false
    private var idleTimer: Timer?
    /// When someone last used MedNotes, for the idle lock. Readable so a test
    /// can see what an input did. Not `@Published`: it changes on every key,
    /// click and scroll, and must redraw nothing.
    private(set) var lastInteraction = Date()

    /// When someone last pressed a key, clicked, scrolled, moved the pointer
    /// over a window or came back to MedNotes: input only a person at the Mac
    /// makes. Text that arrives with no key counts only for a while after it
    /// (`dictationAllowance`).
    private var lastPhysicalInput = Date()

    /// How long text that arrives with no key, such as dictation, keeps
    /// counting after the last physical input. A microphone left on keeps
    /// transcribing whoever talks nearby, and macOS keeps dictating as long as
    /// someone does, so dictation alone keeps the store open for at most this
    /// long; the idle lock follows five minutes later. Anyone dictating at
    /// the Mac touches it well within this.
    static let dictationAllowance: TimeInterval = 15 * 60

    /// The time input is stamped with. Tests move it on instead of waiting.
    var clock: @MainActor () -> Date = { Date() }

    /// Whether MedNotes is the active app; input counts only then. AppKit
    /// still hands an inactive MedNotes the scrolls and first clicks over its
    /// windows, and its text views still report changes, while the user works
    /// in another app with the curtain up. Tests set it through
    /// `observeUserInput`: the test host is never active.
    private var isAppActive: @MainActor () -> Bool = { NSApp.isActive }

    /// Someone used MedNotes' windows: the pointer moved over one
    /// (`onContinuousHover` in ContentView and `privacyCover`), or
    /// `observeUserInput` saw a key, click or scroll. Ignored while another
    /// app is active.
    func noteInteraction() {
        guard isAppActive() else { return }
        restartIdleClock()
    }

    /// Starts the idle minutes over, active or not: the store was just opened
    /// for the user (`loadStore`), or they came back to MedNotes
    /// (`observeAppActivation`). Gated like input, an unlock with the app in
    /// the background would lock again at the next check.
    private func restartIdleClock() {
        let now = clock()
        lastInteraction = now
        lastPhysicalInput = now
    }

    /// How often the idle timer checks. Tests shorten it to see the timer
    /// itself fire.
    var idleCheckInterval: TimeInterval = 30

    private func startIdleMonitor() {
        idleTimer?.invalidate()
        let timer = Timer(timeInterval: idleCheckInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.lockIfIdle() }
        }
        // Common modes: the check also runs while a menu is tracked or a
        // file panel is up (`choose(_:)`).
        RunLoop.main.add(timer, forMode: .common)
        idleTimer = timer
    }

    /// The idle timer's check, apart from the timer so a test can ask about a
    /// moment five minutes on instead of waiting for it. `now` defaults to
    /// `clock()`.
    func lockIfIdle(now: Date? = nil) async {
        let now = now ?? clock()
        guard !isLocked,
              now.timeIntervalSince(lastInteraction) >= SecureStoreCoordinator.idleInterval else { return }
        await lockNow(reason: "idle")
    }

    /// What `observeUserInput` counts from AppKit's event stream: every key
    /// press, and every click and scroll in MedNotes' windows, sheets and
    /// alerts. Pointer movement is hover's.
    private static let userInputEvents: NSEvent.EventTypeMask =
        [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]

    private var inputObservers: [AnyCancellable] = []

    /// Counts typing, clicks, scrolling and dictation toward the idle lock.
    /// Only pointer movement used to count, so a doctor typing or dictating a
    /// long note without touching the mouse was locked out mid-sentence.
    ///
    /// Two sources, because neither sees everything:
    /// - A local event monitor sees each key, click and scroll inside
    ///   `NSApplication.sendEvent`, before any window, text view or input
    ///   method, and passes every event on unchanged. Local monitors run in no
    ///   fixed order (it changes from launch to launch), so one that returns
    ///   nil can hide an event from this one; `SwipeRevealController`
    ///   swallows only the middle of a row swipe, never its start or a click.
    /// - Dictation inserts text with no key event, and only the text view's
    ///   change notification sees it; so do the emoji picker, a paste chosen
    ///   from the menu and VoiceOver setting text. Only the focused text view
    ///   counts, not the field editor behind every text field: SwiftUI posts
    ///   from a field editor when the model changes under the field being
    ///   edited, as the calendar sync does when it reloads the open event, and
    ///   nobody typed that. A `TextEditor` posts nothing when its text is set
    ///   from code, a template or a reload.
    ///
    /// Input that can go on with nobody there is limited. A held key repeats
    /// for as long as it is held (a book, an elbow, a cat), so only its press
    /// counts, and the text its repeats type does not either. Dictated text
    /// counts only within `dictationAllowance` of the last physical input.
    ///
    /// All of it counts only while MedNotes is active (`noteInteraction`).
    /// The app's own session observes from `init` until it quits, locked or
    /// not: a lock only stops the idle check. Tests pass their own
    /// `isAppActive` and stop observing at teardown, because the monitor sees
    /// every event in the test host.
    func observeUserInput(isAppActive: @escaping @MainActor () -> Bool = { NSApp.isActive }) {
        self.isAppActive = isAppActive
        // Runs on the main thread for every key, click and scroll: it only
        // compares and stores a date.
        let monitor = NSEvent.addLocalMonitorForEvents(matching: Self.userInputEvents) { [weak self] event in
            self?.noteInput(event)
            return event
        }
        inputObservers = [
            AnyCancellable { if let monitor { NSEvent.removeMonitor(monitor) } },
            NotificationCenter.default.publisher(for: NSText.didChangeNotification)
                .sink { [weak self] in self?.noteTextInput($0.object) },
        ]
    }

    /// Removes the monitor and the observer, leaving `isAppActive` as it was
    /// so a test can tell a removed monitor from a closed gate. Only tests
    /// call it.
    func stopObservingUserInput() {
        inputObservers = []
    }

    private func noteInput(_ event: NSEvent) {
        if event.type == .keyDown, event.isARepeat { return }
        noteInteraction()
    }

    private func noteTextInput(_ object: Any?) {
        let now = clock()
        guard let textView = object as? NSTextView,
              !textView.isFieldEditor,
              textView.window?.firstResponder === textView,
              // Typed text, a held key's included, is the monitor's to count.
              NSApp.currentEvent?.type != .keyDown,
              isAppActive(),
              now.timeIntervalSince(lastPhysicalInput) < Self.dictationAllowance
        else { return }
        // Restarts the idle minutes but not the allowance: only a person
        // touching the Mac does that.
        lastInteraction = now
    }

    /// The system events that lock the store rather than only cover it: the
    /// user has stepped away from this Mac, or another account is taking it
    /// over. Switching apps or hiding MedNotes only raises the curtain
    /// (`appDidResignActive`), and five idle minutes lock it as well.
    struct SystemLockEvent {
        let name: Notification.Name
        /// Recorded as `reason=` on the audit trail's `app_lock` entry.
        let reason: String
        /// Posted on `DistributedNotificationCenter`. The others are posted
        /// only on `NSWorkspace.shared.notificationCenter`; observed on
        /// `NotificationCenter.default` they never arrive.
        let isDistributed: Bool

        static let all = [
            // Lock Screen (⌃⌘Q), or a screen saver or display sleep once the
            // login password is required. Not an NSWorkspace notification.
            SystemLockEvent(name: Notification.Name("com.apple.screenIsLocked"),
                            reason: "screen-lock", isDistributed: true),
            // Also when the password is not required, or only after a delay.
            SystemLockEvent(name: NSWorkspace.screensDidSleepNotification,
                            reason: "display-sleep", isDistributed: false),
            SystemLockEvent(name: NSWorkspace.willSleepNotification,
                            reason: "system-sleep", isDistributed: false),
            // Fast user switching away from this account.
            SystemLockEvent(name: NSWorkspace.sessionDidResignActiveNotification,
                            reason: "user-switch", isDistributed: false),
        ]
    }

    private var systemLockObservers: [AnyCancellable] = []

    /// Locks on every `SystemLockEvent`. The session observes rather than a
    /// window, so the store also locks while the main window is closed.
    /// Tests pass private centers or names of their own: posting a real event
    /// inside the test host would lock the host app's own session too.
    func observeSystemLockEvents(
        _ events: [SystemLockEvent] = SystemLockEvent.all,
        workspace: NotificationCenter = NSWorkspace.shared.notificationCenter,
        distributed: NotificationCenter = DistributedNotificationCenter.default()
    ) {
        systemLockObservers = events.map { event in
            let lock: @Sendable () -> Void = { [weak self] in
                Task { @MainActor in await self?.lockNow(reason: event.reason) }
            }
            if event.isDistributed, let distributed = distributed as? DistributedNotificationCenter {
                return ImmediateDistributedObserver.observe(event.name, on: distributed, handler: lock)
            }
            return (event.isDistributed ? distributed : workspace)
                .publisher(for: event.name)
                .sink { _ in lock() }
        }
    }

    /// Observes a distributed notification even while MedNotes is inactive.
    /// AppKit suspends distributed delivery whenever the app is not active,
    /// and an observer without `.deliverImmediately` (the block API, and so
    /// Combine's publisher) is then held until the app is active again: a
    /// screen locked while MedNotes was in the background would lock the
    /// store only once the user came back to it.
    private final class ImmediateDistributedObserver: NSObject {
        private let handler: @Sendable () -> Void

        static func observe(_ name: Notification.Name, on center: DistributedNotificationCenter,
                            handler: @escaping @Sendable () -> Void) -> AnyCancellable {
            let observer = ImmediateDistributedObserver(handler: handler)
            center.addObserver(observer, selector: #selector(receive(_:)), name: name, object: nil,
                               suspensionBehavior: .deliverImmediately)
            return AnyCancellable { center.removeObserver(observer) }
        }

        private init(handler: @escaping @Sendable () -> Void) {
            self.handler = handler
        }

        @objc private func receive(_ notification: Notification) {
            handler()
        }
    }

    /// True while the privacy curtain covers the window.
    @Published private(set) var isObscured = false { didSet { recordsCoverDidChange() } }

    /// Locked, migrating, missing its key or obscured: no record may show.
    var showsPrivacyCurtain: Bool {
        isLocked || isMigrating || needsRecovery || isObscured
    }

    private let focusParking = FocusParking()
    private var recordsWereCovered = false

    /// Parks keyboard focus while the curtain hides records, locked or in the
    /// background, and gives it back as it lifts. It runs as the flag changes,
    /// before SwiftUI redraws, so the hidden views never hold focus under the
    /// curtain; see `FocusParking`. Migration and recovery load no records,
    /// and their passphrase fields sit in the curtain itself.
    private func recordsCoverDidChange() {
        let isCovered = isLocked || isObscured
        guard isCovered != recordsWereCovered else { return }
        recordsWereCovered = isCovered
        if isCovered {
            focusParking.park()
        } else {
            focusParking.restore()
        }
    }

    /// A window that shows the curtain or a cover, for `FocusParking`.
    func coverWindow(_ window: NSWindow?) {
        if let window { focusParking.cover(window) }
    }

    /// Obscures the window while inactive so no record is visible in a
    /// screenshot, Mission Control or the app switcher. The store itself is
    /// not torn down here: a quick ⌘-Tab must not lock it. Synchronous, like
    /// `appDidBecomeActive()`, so the two apply in the order AppKit delivers
    /// them and a late resign can never re-raise the curtain on an active app.
    func appDidResignActive() {
        isObscured = true
    }

    func appDidBecomeActive() {
        obscureWhenReady = false
        isObscured = false
        // The user may have granted or revoked access in System Settings while
        // the app was inactive; the pill and Settings › Sync should agree with
        // the privacy pane as soon as they are visible again.
        appleCalendar.refreshAccessState()
        appleReminders.refreshAccessState()
    }

    private var activationObservers: [AnyCancellable] = []

    /// Raises and lowers the curtain as the app resigns and regains active,
    /// and starts the idle minutes over on coming back. The session
    /// observes rather than a window, like `observeSystemLockEvents`: with the
    /// main window closed, Window › Activity (the audit trail) and Settings
    /// must still be covered when the user switches away. Both handlers run
    /// synchronously as AppKit posts on the main thread, so they apply in
    /// the order it delivers them.
    func observeAppActivation(_ center: NotificationCenter = .default) {
        activationObservers = [
            center.publisher(for: NSApplication.didResignActiveNotification)
                .sink { [weak self] _ in self?.appDidResignActive() },
            center.publisher(for: NSApplication.didBecomeActiveNotification)
                .sink { [weak self] _ in
                    self?.restartIdleClock()
                    self?.appDidBecomeActive()
                },
        ]
    }

    /// A window appeared while the app was inactive, and it has not been
    /// active since: the curtain goes up the moment records would first show.
    private var obscureWhenReady = false

    /// Called by the main window, and by every window and sheet with a
    /// `privacyCover`, when it appears. `isObscured` is otherwise raised only
    /// by a resign-active, which an app launched in the background (`open -g`,
    /// a hidden login item, a click elsewhere during startup) never receives
    /// until it has been active once.
    ///
    /// Before the store is ready the window shows no record, so the curtain is
    /// only armed then: raising it at once would flash it over the startup
    /// spinner on every ordinary launch, which appears a moment before the app
    /// becomes active. `isObscured` itself never starts out true — a
    /// become-active delivered before anything observed it would leave it stuck.
    func windowDidAppear(appIsActive: Bool) {
        guard !appIsActive else { return }
        if isReady {
            isObscured = true
        } else {
            obscureWhenReady = true
        }
    }

    /// True while `unlock()` is between authenticating and publishing the
    /// reopened store, so a second press of Unlock cannot open another one.
    private var isUnlocking = false
    /// A lock requested while `unlock()` was reloading. `isLocked` is still
    /// true then, so `lockNow` cannot tear the new store down itself; the
    /// unlock does it instead of publishing the unlocked state.
    private var pendingLockReason: String?
    /// Every lock request, counted before `lockNow` decides what to do with
    /// it. A path that opens a store across long awaits (launch, the
    /// encryption migration, key recovery) compares it with the count it
    /// started from: a lock that arrived in between wins, and the store it
    /// opened is closed again instead of published behind a locked curtain.
    private(set) var lockRequests = 0

    /// Re-authenticates and reopens the store after a lock.
    ///
    /// The curtain also covers an open store while the app is inactive; its
    /// Unlock button then only lifts the curtain, without authenticating or
    /// opening a second connection. A real unlock leaves `isObscured` to the
    /// activation handlers: if the user switched away while the records were
    /// reloading, the curtain must stay up until the app is active again.
    ///
    /// A lock that arrives while the records reload (the screen locked right
    /// after Touch ID, say) wins: the reopened store is closed again and the
    /// session stays locked.
    func unlock() async {
        guard isLocked else {
            isObscured = false
            return
        }
        guard !isUnlocking, let coordinator, let dataRoot else { return }
        isUnlocking = true
        pendingLockReason = nil
        // Not a `defer`: the pending-lock path below clears it before its own
        // `await`, and a deferred reset would then run after an Unlock pressed
        // during that close had set it again for its own attempt.
        do {
            _ = try coordinator.authenticate()
            let store = try AppStore(
                dataRoot: dataRoot,
                databaseKey: coordinator.requireDatabaseKey(),
                attachmentKey: coordinator.requireAttachmentKey(),
                restorePointKey: coordinator.requireRestoreKey())
            if let previous = self.store {
                await previous.close()
            }
            await loadStore(store)
            // A failed earlier attempt (a cancelled Touch ID prompt) left its
            // message here; this one authenticated, so it no longer applies
            // even if a pending lock closes the store again.
            initError = nil
            isUnlocking = false
            if let reason = pendingLockReason {
                pendingLockReason = nil
                await closeStore(reason: reason)
                return
            }
            SecurityLog.record(.appUnlock)
            // Restarts what `lockNow` stopped (the idle timer, the EventKit
            // observers), and starts what a launch that never opened the
            // store — a cancelled Touch ID prompt — did not.
            await finishOpening()
        } catch {
            // Everything that throws runs before the first `await`, so no
            // lock can be pending here.
            isUnlocking = false
            // Authentication may have installed keys before the store failed
            // to open; a session that stays locked must not keep them.
            coordinator.lock()
            initError = error.localizedDescription
            // The key item is gone, not merely unreadable: no retry can
            // succeed, so the curtain offers recovery instead of Unlock.
            if case SecureStoreError.missingKeyForExistingStore = error {
                isLocked = false
                needsRecovery = true
            }
        }
    }

    /// Writes the mandatory pre-migration backup from the still-plaintext
    /// store, then restores it completely into a throwaway encrypted store to
    /// prove it can be used, before the wizard is allowed to stage anything.
    func migrationBackup(to url: URL, passphrase: String) async throws {
        guard let dataRoot else { return }
        let plaintext = try Database(path: dataRoot.databaseURL.path, deriveLinks: false)
        let backup = BackupService(
            db: plaintext,
            fileStore: nil,
            restorePointsRoot: dataRoot.restorePointsURL,
            legacyFilesRoot: dataRoot.filesURL)
        do {
            _ = try await backup.createEncryptedBackup(
                name: "Pre-encryption backup", to: url, passphrase: passphrase)
            let manifest = try await BackupService.verifyFullRestore(of: url, passphrase: passphrase)
            await plaintext.close()
            notice = String(localized: "Verified backup: \(BackupFlowSheet.summary(of: manifest))")
        } catch {
            await plaintext.close()
            throw error
        }
    }

    /// Locks the store: cancels tasks, clears displayed records, closes the
    /// database, removes plaintext temporaries and wipes key buffers.
    ///
    /// During an unlock the session is still locked but the reopened store is
    /// already reloading behind the curtain; the lock is then handed to
    /// `unlock()`, which closes that store instead of uncovering it.
    func lockNow(reason: String) async {
        lockRequests &+= 1
        if isUnlocking {
            // The first event is the one that locked the session.
            pendingLockReason = pendingLockReason ?? reason
            return
        }
        guard !isLocked else { return }
        isLocked = true
        await closeStore(reason: reason)
    }

    /// Locks the store because the user asked: MedNotes › Lock MedNotes, ⌃⌘L.
    /// The same path as the idle timer and the system events, so the request
    /// is audited like any other lock reason.
    func lockOnRequest() async {
        guard canUseStore else { return }
        await lockNow(reason: "request")
    }

    /// The teardown behind `lockNow`, for a session that is already locked.
    ///
    /// Everything the session exposes is torn down before the first `await`:
    /// an Unlock pressed while the old connection is still closing then opens
    /// a fresh store that this lock can no longer clear or unkey.
    private func closeStore(reason: String) async {
        // Read the open editors before anything unmounts them; their drafts
        // are written below, into the store that is closing.
        let drafts = openEditors.values.compactMap { $0() }.map(preparedForSave)
        // The file panel is app-modal and drawn above the curtain and the
        // sheets, and a backup or export writes outside the container: both
        // stop here. The code waiting on them finds the store gone.
        panels.cancelRunning()
        outgoing.values.forEach { $0() }
        dismissRecordUI()
        // After `dismissRecordUI`: emptying a search field schedules a search.
        searchTask?.cancel()
        patientSearchTask?.cancel()
        todoSearchTask?.cancel()
        eventSearchTask?.cancel()
        switcherTask?.cancel()
        calendarObserverTask?.cancel()
        remindersObserverTask?.cancel()
        // A lock stops the restore-point upgrade between records: it holds
        // the restore key, which the lock is about to wipe.
        restorePointUpgradeTask?.cancel()
        restorePointUpgradeTask = nil
        let closing = store
        store = nil
        clearDisplayedRecords()
        coordinator?.lock()
        EncryptedFileStore.purgeOrphanedTemporaries(in: externalCopiesURL)
        // The swipe log is the app's, in the container's temporary directory,
        // which the test host shares: a test session's lock leaves it alone.
        if injectedDataRoot == nil {
            SwipeDiagnostics.purge()
        }
        if let closing {
            let flush = Task { await self.saveDrafts(drafts, into: closing) }
            draftFlush = flush
            await flush.value
            try? await closing.audit.log(
                action: "app_lock", entityType: "session", entityId: "lock", details: "reason=\(reason)")
            await closing.close()
        }
        // A read that was already running on the old store can land while the
        // connection closes. Clear again unless an Unlock has since reopened.
        if isLocked, store == nil {
            clearDisplayedRecords()
        }
        SecurityLog.record(.appLock)
    }

    /// Empties every published record list and invalidates the reloads in
    /// flight, whose generation checks then drop their late results.
    private func clearDisplayedRecords() {
        notesReloadGeneration += 1
        patientsReloadGeneration += 1
        todosReloadGeneration += 1
        eventsReloadGeneration += 1
        notes = []
        patients = []
        patientDirectory = []
        todos = []
        events = []
        backlinks = []
        linksOut = []
        unlinkedMentions = []
        graphData = LinkingService.GraphData()
        // The settings may name a patient; the saved copy stays in the store.
        // A change made in the last moments before the lock is not saved.
        graphSettingsLoaded = false
        graphSaveTasks.values.forEach { $0.cancel() }
        graphSaveTasks = [:]
        graphQueryTask?.cancel()
        graphMatching = nil
        graphGroupMatches = [:]
        graphSettings = GraphSettings()
        localGraphSettings = GraphSettings()
        filteredGraph = FilteredGraph()
    }

    /// The records that were open when the store locked, as ids only, so
    /// unlocking returns to them without keeping anything they say in memory.
    private struct SelectionAtLock {
        var note: UUID?
        var patient: UUID?
        var todo: UUID?
        var event: UUID?
    }

    private var selectionAtLock: SelectionAtLock?

    /// Takes down everything other than the record lists that shows or edits
    /// a record: the selections that keep the editors mounted, the sheets,
    /// alerts and confirmation over the window, the quick switcher, and the
    /// search fields, whose text is often a patient's name. Sheets and alerts
    /// sit above the curtain, so dismissing them is the only way to hide them.
    private func dismissRecordUI() {
        // A lock handed over by an unlock still in flight finds nothing
        // selected; the ids saved by the first lock stay.
        if selectionAtLock == nil {
            selectionAtLock = SelectionAtLock(
                note: selectedNoteId, patient: selectedPatientId,
                todo: selectedTodoId, event: selectedEventId)
        }
        selectedNoteId = nil
        selectedPatientId = nil
        selectedTodoId = nil
        selectedEventId = nil
        pendingFocusRecordId = nil
        backupFlow = nil
        importFlow = nil
        destinationFlow = nil
        confirmDelete = false
        pendingDeletion = nil
        notice = nil
        errorMessage = nil
        showSwitcher = false
        if !switcherText.isEmpty { switcherText = "" }
        switcherResults = []
        if !searchText.isEmpty { searchText = "" }
        if noteTagFilter != nil { noteTagFilter = nil }
        noteTags = []
        noteSnippets = [:]
        if !patientSearchText.isEmpty { patientSearchText = "" }
        if !todoSearchText.isEmpty { todoSearchText = "" }
        if !eventSearchText.isEmpty { eventSearchText = "" }
    }

    /// Reopens what was selected when the store locked, if the reloaded list
    /// still shows it: a new record the lock discarded stays closed.
    private func restoreSelectionAfterLock() {
        guard let saved = selectionAtLock else { return }
        selectionAtLock = nil
        if selectedNoteId == nil, let id = saved.note, notes.contains(where: { $0.id == id }) {
            selectedNoteId = id
        }
        if selectedPatientId == nil, let id = saved.patient, patients.contains(where: { $0.id == id }) {
            selectedPatientId = id
        }
        if selectedTodoId == nil, let id = saved.todo, todos.contains(where: { $0.id == id }) {
            selectedTodoId = id
        }
        if selectedEventId == nil, let id = saved.event, events.contains(where: { $0.id == id }) {
            selectedEventId = id
        }
    }

    /// The draft save of the lock in progress. Opening a store waits for it,
    /// so an Unlock pressed while the old connection is still writing reloads
    /// what the lock just saved rather than the version before it.
    private var draftFlush: Task<Void, Never>?
    /// Saved by a lock without the quiet push their save would have made;
    /// `finishOpening` makes it.
    private var todosSavedAtLock: Set<UUID> = []
    private var eventsSavedAtLock: Set<UUID> = []

    /// `draft` as `save` would store it, taken while `patientDirectory` still
    /// holds the names a todo is saved with.
    private func preparedForSave(_ draft: OpenEditorDraft) -> OpenEditorDraft {
        switch draft {
        case .todo(let todo, true):
            return .todo(normalizedForSave(todo), edited: true)
        case .event(var event, true):
            event.ensureEndNotBeforeStart()
            return .event(event, edited: true)
        default:
            return draft
        }
    }

    /// The lock's last write before the store closes: an edited draft is
    /// saved and a new record nobody touched is discarded, as leaving its
    /// editor would. Nothing is reloaded or shown; unlock reloads everything.
    private func saveDrafts(_ drafts: [OpenEditorDraft], into store: AppStore) async {
        var failures = 0
        for draft in drafts {
            do {
                switch draft {
                case .note(let note, let edited):
                    if edited {
                        try await store.notes.save(note)
                        if !isUntouchedNewNote(note) { seededNoteContent[note.id] = nil }
                    } else if isUntouchedNewNote(note) {
                        try await store.notes.discard(id: note.id)
                        seededNoteContent[note.id] = nil
                    }
                case .patient(let patient, let edited, let knownFileIDs):
                    if edited {
                        try await store.patients.save(patient, knownFileIDs: knownFileIDs)
                    } else if patient.isUntouchedNewRecord {
                        try await store.patients.discard(id: patient.id)
                    }
                case .todo(let todo, let edited):
                    if edited {
                        _ = try await store.todos.save(todo)
                        todosSavedAtLock.insert(todo.id)
                    } else if todo.isUntouchedNewRecord, todo.reminderIdentifier == nil {
                        // One already in Apple Reminders would need its copy
                        // there deleted too, which a lock does not do.
                        try await store.todos.discard(id: todo.id)
                    }
                case .event(let event, let edited):
                    if edited {
                        _ = try await store.events.save(event)
                        eventsSavedAtLock.insert(event.id)
                    } else if event.isUntouchedNewRecord, event.ekEventIdentifier == nil {
                        try await store.events.discard(id: event.id)
                    }
                }
            } catch {
                failures += 1
            }
        }
        if failures > 0 {
            // The alert waits for the unlock; ContentView hides it while locked.
            errorMessage = String(localized: "MedNotes locked while a record was being edited, and \(failures) edit(s) could not be saved.")
        }
    }

    /// Publishes a store that was just opened and reloads every list from it,
    /// still behind the curtain. Shared by launch, unlock, the encryption
    /// migration and key recovery; `finishOpening` then uncovers the session.
    private func loadStore(_ store: AppStore) async {
        await draftFlush?.value
        // Before the store is published, so nothing can be saving: objects a
        // crash left behind between a file write and its commit are removed.
        await store.sweepOrphanedAttachments()
        self.store = store
        restartIdleClock()
        await reload()
        await reloadPatients()
        await reloadPatientDirectory()
        await reloadTodos()
        await reloadEvents()
        await refreshSyncDestinations()
        await loadGraphSettings()
    }

    /// The session is open: the curtain lifts (unless the app is inactive)
    /// and everything a live store runs starts. Every path that opens a store
    /// ends here, so none of them can forget the idle lock or the EventKit
    /// observers, as the migration and recovery once did.
    /// Reseals restore points an earlier build wrote under a public
    /// passphrase. Tracked so a lock can cancel it.
    private var restorePointUpgradeTask: Task<Void, Never>?

    private func finishOpening() async {
        if obscureWhenReady {
            obscureWhenReady = false
            isObscured = true
        }
        isLocked = false
        initError = nil
        isReady = true
        restoreSelectionAfterLock()
        startIdleMonitor()
        startBridgeObservation()
        observeCalendarChanges()
        observeRemindersChanges()
        await pushDraftsSavedAtLock()
        if let store {
            restorePointUpgradeTask?.cancel()
            restorePointUpgradeTask = Task { await store.backups.upgradeLegacyRestorePoints() }
        }
        if !hasCheckedIntegrity {
            hasCheckedIntegrity = true
            await checkIntegrityQuietly()
        }
    }

    /// Whether this process has run the launch integrity check. Launch runs
    /// it when it opens the store; a launch whose Touch ID prompt was
    /// cancelled leaves it to the first unlock.
    private var hasCheckedIntegrity = false

    /// A lock arrived while `store` was being opened: it is closed and its
    /// keys wiped instead of left open behind a locked curtain. `lockNow`
    /// closed it already if it found it published.
    private func abandon(_ store: AppStore, published: Bool) async {
        coordinator?.lock()
        if published {
            guard self.store === store else { return }
            self.store = nil
            clearDisplayedRecords()
        }
        await store.close()
    }

    /// The quiet pushes the lock's draft saves skipped, under the conditions
    /// a save applies (automatic sync on, access granted, a confirmed
    /// destination).
    private func pushDraftsSavedAtLock() async {
        let todoIDs = todosSavedAtLock
        let eventIDs = eventsSavedAtLock
        todosSavedAtLock = []
        eventsSavedAtLock = []
        guard let store else { return }
        for id in todoIDs {
            if let todo = try? await store.todos.load(id: id) { await pushTodoQuietly(todo) }
        }
        for id in eventIDs {
            if let event = try? await store.events.load(id: id) { await pushQuietly(event) }
        }
    }

    /// Set by the launch check or a failed Check Now, shown as a banner in
    /// the main window; a passing check clears it. Dismissable for the
    /// session — it comes back on the next launch while the store still fails.
    @Published var integrityWarning: String?

    @Published var destinationFlow: DestinationFlow?

    // MARK: - Sync destination state

    /// What Settings › Sync reports about each bridge's confirmed destination.
    /// Nil before a destination is chosen; the wizard writes one.
    @Published var syncDestinationCandidates: [SyncBridgeType: SyncDestinationViewState] = [:]

    @Published var backupFlow: BackupFlow?
    /// What the last backup, restore or import did, for the confirmation alert.
    @Published var notice: String?

    /// The backups and Markdown exports under way, which write outside the
    /// container, by token. A lock cancels each one (`closeStore`), and they
    /// look for that before every record or note they write.
    var outgoing: [UUID: () -> Void] = [:]

    /// Test seam: runs as a backup or export begins writing outside the
    /// container, so a test can land a lock there. Nothing in the app sets it.
    var outgoingWillBegin: @MainActor () async -> Void = {}

    /// Test seam: told as each attachment is sealed into a backup, so a test
    /// can land a lock while the archive is being written. Nothing in the app
    /// sets it.
    var backupProgress: (@Sendable (Int, Int) -> Void)?

    // MARK: - One-time Markdown export (retired continuous mirror)

    /// Why the last Markdown export stopped short, for Settings › Data to show
    /// until the next export starts. Not an alert: the export is asked for in
    /// Settings, whose pane the lock rebuilds, and the main window, which
    /// draws the session's alerts, may be closed.
    @Published var markdownExportInterruption: String?

    static let legacyImportBookmarkKey = "legacyImportBookmark"

    @Published var importFlow: ImportFlow?

    /// The store to open. `nil` resolves the real one (or the preview root
    /// under `--preview-seed`); tests pass a temporary root and never touch
    /// Application Support.
    private let injectedDataRoot: DataRoot?
    /// Test seam: when set, key material comes from here instead of the
    /// Keychain, so the suite never prompts or reads the user's real items.
    private let injectedKeyManager: KeyManager?
    /// The open and save panels; tests pass their own. See `FilePanels`.
    let panels: FilePanels

    /// Where "Open Externally" copies go, and what a lock empties: the app's
    /// folder for the app's own session, the injected root's own folder for
    /// a test's. The test host is this app, so emptying the app's folder
    /// from a test would delete a copy the owner's MedNotes had handed to a
    /// viewer.
    private var externalCopiesURL: URL {
        injectedDataRoot?.externalCopiesURL ?? DataRoot.appExternalCopiesURL
    }

    /// `followsSystem`: whether the session locks on the system's lock
    /// events, covers itself when the app resigns active and counts input
    /// toward the idle lock. By default only the app's own session does, the
    /// one without an injected root; a test passes true to check that wiring.
    init(dataRoot: DataRoot? = nil, defaults: UserDefaults = .standard,
         keyManager: KeyManager? = nil, followsSystem: Bool? = nil,
         panels: FilePanels? = nil) {
        // In the XCTest host `.standard` is the owner's real preferences file:
        // a test's session would read their settings and overwrite their last
        // module. It gets a suite of its own (`TestDefaults` in the tests).
        precondition(dataRoot == nil || !Self.isTestHost || defaults !== UserDefaults.standard,
                     "a test session must not use the host's real preferences")
        self.injectedDataRoot = dataRoot
        self.injectedKeyManager = keyManager
        self.panels = panels ?? AppKitFilePanels()
        self.defaults = defaults
        self.calendarAutoSyncEnabled = Self.autoSyncSetting(defaults, key: Self.calendarAutoSyncDefaultsKey)
        self.remindersAutoSyncEnabled = Self.autoSyncSetting(defaults, key: Self.remindersAutoSyncDefaultsKey)
        self.defaultNoteTemplateID = defaults.string(forKey: Self.defaultNoteTemplateDefaultsKey)
        self.noteInspectorShown = defaults.object(forKey: Self.noteInspectorDefaultsKey) as? Bool ?? true
        self.graphPanelShown = defaults.object(forKey: Self.graphPanelDefaultsKey) as? Bool ?? false
        let launch = LaunchModule(storageValue: defaults.string(forKey: Self.launchModuleDefaultsKey))
        self.launchModule = launch
        self.selectedModule = launch.startModule(
            lastUsed: defaults.string(forKey: Self.lastModuleDefaultsKey).flatMap(AppModule.init(rawValue:)))
        if dataRoot == nil {
            // The XCTest host is this app, and its own session would open the
            // user's real store and read their Keychain item while the suite
            // runs. It stays at "Starting MedNotes…"; tests make their own
            // sessions over temporary roots.
            guard !Self.isTestHost else { return }
            removeExternalCopiesOnQuit()
        }
        // Only the app's own session (the real or preview root) follows the
        // system. A test's session has an injected root and must not lock
        // when the tester's screen does, or cover itself when the test host
        // loses focus; tests that need either call the observers themselves.
        if followsSystem ?? (dataRoot == nil) {
            observeSystemLockEvents()
            observeAppActivation()
            observeUserInput()
        }
        loadTask = Task { await bootstrap() }
    }

    /// Whether the system lock events, activation and input are all observed:
    /// what `followsSystem` turns on. Tests check the app's wiring with it.
    var isFollowingSystem: Bool {
        !systemLockObservers.isEmpty && !activationObservers.isEmpty && !inputObservers.isEmpty
    }

    /// True in the process XCTest injects its bundle into.
    nonisolated static var isTestHost: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    private var terminationObserver: AnyCancellable?

    /// "Open Externally" copies are plaintext. A lock removes them; so does
    /// quitting, and launch removes whatever a crash left behind. Not losing
    /// focus: opening the copy hands focus to the viewer, which would lose the
    /// file it was just given.
    private func removeExternalCopiesOnQuit() {
        terminationObserver = NotificationCenter.default
            .publisher(for: NSApplication.willTerminateNotification)
            .sink { _ in
                EncryptedFileStore.purgeOrphanedTemporaries(in: DataRoot.appExternalCopiesURL)
            }
    }

    /// The real store, unless this process was launched with `--preview-seed`.
    /// `DataRoot.preview(reset:)` resets before it hands back a root, so the
    /// wipe can never happen after `AppStore` has opened the database.
    private static func resolveDataRoot() throws -> DataRoot {
        #if DEBUG
        if PreviewSeed.isActive {
            return try DataRoot.preview(reset: PreviewSeed.wantsFreshData)
        }
        #endif
        return try DataRoot.applicationSupport()
    }

    private func bootstrap() async {
        if injectedDataRoot == nil {
            // Plaintext copies a crash left in the app's temporary folder.
            EncryptedFileStore.purgeOrphanedTemporaries(in: DataRoot.appExternalCopiesURL)
        }
        do {
            let dataRoot = try injectedDataRoot ?? Self.resolveDataRoot()
            self.dataRoot = dataRoot
            let keyManager = resolvedKeyManager()
            try await StoreMigrator(dataRoot: dataRoot, keyManager: keyManager).recoverInterruptedMigration()
            let coordinator = SecureStoreCoordinator(keyManager: keyManager, dataRoot: dataRoot)
            self.coordinator = coordinator

            // One Keychain read decides the route. A cancelled or refused
            // prompt leaves the store locked for Unlock to retry; only a key
            // item that is really gone offers recovery.
            do {
                if try coordinator.authenticate() == .plaintextStore {
                    // The wizard owns the screen until the store is converted.
                    isMigrating = true
                    return
                }
            } catch SecureStoreError.missingKeyForExistingStore {
                needsRecovery = true
                initError = SecureStoreError.missingKeyForExistingStore.localizedDescription
                return
            } catch SecureStoreError.keyUnavailable(let status) {
                isLocked = true
                initError = SecureStoreError.keyUnavailable(status).localizedDescription
                return
            }

            let store = try AppStore(
                dataRoot: dataRoot,
                databaseKey: coordinator.requireDatabaseKey(),
                attachmentKey: coordinator.requireAttachmentKey(),
                restorePointKey: coordinator.requireRestoreKey())
            // This is the store's first open, so any lock request so far (the
            // screen locked while Touch ID was up, say) counts against it.
            guard lockRequests == 0 else {
                await abandon(store, published: false)
                return
            }
            #if DEBUG
            // Plain `--preview-seed` keeps the previous run's edits so that
            // "quit, relaunch, my change survived" stays reviewable;
            // `--preview-seed=fresh` reset the directory above.
            if PreviewSeed.isActive, try await SampleData.isEmpty(store) {
                try await SampleData.seed(into: store)
            }
            #endif
            await loadStore(store)
            guard lockRequests == 0 else {
                await abandon(store, published: true)
                return
            }
            await finishOpening()
        } catch {
            let message = error.localizedDescription
            let lower = message.lowercased()
            if lower.contains("database is locked") || lower.contains("sqlite_busy") || lower.contains("database is busy") {
                self.initError = message + "\n\n" + String(localized: "Another MedNotes copy may be running. Quit it, then relaunch.")
            } else {
                self.initError = message
            }
        }
    }

    #if DEBUG
    /// The preview root's fixed key. It must be exactly 32 bytes: the
    /// coordinator rejects any other length, which left `--preview-seed`
    /// unable to open its store while this was a 31-byte string.
    static let previewStoreKey = Data("MedNotes-Preview-Store-Key-00000".utf8)
    #endif

    /// The production key manager unless the process is a preview or a test.
    ///
    /// The preview root gets a fixed, process-independent key so
    /// `--preview-seed` keeps the previous run's edits across relaunches. That
    /// root is a compile-time constant throwaway and never the user's store.
    private func resolvedKeyManager() -> KeyManager {
        if let injectedKeyManager { return injectedKeyManager }
        #if DEBUG
        if PreviewSeed.isActive {
            return InMemoryKeyManager(key: Self.previewStoreKey)
        }
        #endif
        return KeychainKeyManager()
    }

    /// Runs the encryption migration after the wizard has produced a verified
    /// backup. Called from the migration UI.
    ///
    /// A lock that arrives while it runs (display sleep during a long
    /// conversion) leaves the converted store closed and locked; Unlock opens
    /// it. One that came before the user pressed Encrypt does not count: they
    /// were present to type the passphrase.
    func runMigration(backupURL: URL, passphrase: String) async throws {
        guard let dataRoot, let coordinator else { return }
        let lockRequestsAtStart = lockRequests
        isMigrating = true
        defer { isMigrating = false }
        let migrator = StoreMigrator(dataRoot: dataRoot, keyManager: coordinator.keyManager)
        var swapped = false
        do {
            // Inside the do block: a failure here reaches the wizard instead of leaving the spinner up.
            let rootKey = try coordinator.createMigrationKey()
            let report = try await migrator.migrate(
                backupDestination: backupURL, passphrase: passphrase, rootKey: rootKey)
            swapped = true
            migrationReport = report
            try coordinator.finishMigration(rootKey: rootKey)
            let store = try AppStore(
                dataRoot: dataRoot,
                databaseKey: coordinator.requireDatabaseKey(),
                attachmentKey: coordinator.requireAttachmentKey(),
                restorePointKey: coordinator.requireRestoreKey())
            try await migrator.finishCleanup()
            // The conversion is complete either way; only what is shown differs.
            guard lockRequests == lockRequestsAtStart else {
                await abandon(store, published: false)
                return
            }
            await loadStore(store)
            guard lockRequests == lockRequestsAtStart else {
                await abandon(store, published: true)
                return
            }
            await finishOpening()
            if !report.missingAttachments.isEmpty {
                let names = report.missingAttachments.prefix(5).joined(separator: ", ")
                notice = String(localized: "\(report.missingAttachments.count) attachment(s) were already missing from disk and could not be carried over: \(names). They are still in the backup made before encrypting.")
            }
        } catch {
            if !swapped { try? await migrator.recoverInterruptedMigration() }
            // The wizard is part of the curtain, which goes away with
            // `isMigrating`; without this the window would sit on the startup
            // spinner with no explanation and no way to retry but relaunch.
            initError = error.localizedDescription
            throw error
        }
    }

    /// Restores a portable backup over a store whose device key is gone, with
    /// a fresh device key. Only reachable from the recovery curtain. The
    /// chosen backup is the user's file and stays where it is.
    ///
    /// As for the migration, a lock that arrives while it runs leaves the
    /// recovered store closed and locked, and one from before the user
    /// started it does not count.
    func recoverFromBackup(at url: URL, passphrase: String) async throws {
        guard let dataRoot, let coordinator else { return }
        let lockRequestsAtStart = lockRequests
        let recovery = StoreRecovery(dataRoot: dataRoot, keyManager: coordinator.keyManager)
        let report = try await recovery.recover(from: url, passphrase: passphrase)
        try coordinator.finishRecovery(rootKey: report.rootKey)
        let store = try AppStore(
            dataRoot: dataRoot,
            databaseKey: coordinator.requireDatabaseKey(),
            attachmentKey: coordinator.requireAttachmentKey(),
                restorePointKey: coordinator.requireRestoreKey())
        SecurityLog.record(.backupRestored, count: report.attachmentCount)
        // Only once the store has opened: until then the curtain had to keep
        // offering recovery rather than uncover a session with nothing behind
        // it. The device key exists now, so a lock leaves plain Unlock.
        guard lockRequests == lockRequestsAtStart else {
            needsRecovery = false
            await abandon(store, published: false)
            return
        }
        await loadStore(store)
        needsRecovery = false
        guard lockRequests == lockRequestsAtStart else {
            await abandon(store, published: true)
            return
        }
        await finishOpening()
    }

    /// Abandons a migration before it started staging; the plaintext store is
    /// left exactly as it was.
    func cancelMigration() {
        isMigrating = false
        initError = String(localized: "Encryption was cancelled. The store is unchanged and still plaintext.")
    }

    // MARK: - Templates

    /// Bumped by every change made in Settings › Templates, so an open note's
    /// insert menu reloads rather than offering yesterday's copy.
    @Published var templateEpoch = 0

    struct StoreNotOpenError: LocalizedError {
        var errorDescription: String? { String(localized: "The store is not open.") }
    }

    func openStore() throws -> AppStore {
        guard let store else { throw StoreNotOpenError() }
        return store
    }

    /// The record `newPatient()`, `newTodo()` or `newEvent()` just created,
    /// until its editor has opened. The detail view consumes this to drop the
    /// keyboard into the first field once — only for a record the user asked
    /// for, never when they are merely arrowing through a list. Ids are
    /// unique across kinds, so one slot serves all three.
    var pendingFocusRecordId: UUID?
}
