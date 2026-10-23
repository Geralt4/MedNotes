import Combine
import SwiftUI
import UniformTypeIdentifiers

enum AppModule: String, CaseIterable, Identifiable {
    case notes
    case patients
    case todos
    case calendar
    case graph

    var id: String { rawValue }

    var title: String {
        switch self {
        case .notes: return String(localized: "Notes")
        case .patients: return String(localized: "Patients")
        case .todos: return String(localized: "Todos")
        case .calendar: return String(localized: "Calendar")
        case .graph: return String(localized: "Graph")
        }
    }

    var icon: String {
        switch self {
        case .notes: return "doc.text"
        case .patients: return "person.2"
        case .todos: return "checklist"
        case .calendar: return "calendar"
        case .graph: return "arrow.triangle.branch"
        }
    }

    var newItemTitle: String {
        switch self {
        case .notes: return String(localized: "New Note")
        case .patients: return String(localized: "New Patient")
        case .todos: return String(localized: "New Todo")
        case .calendar: return String(localized: "New Event")
        case .graph: return String(localized: "New Note")
        }
    }

    /// Graph has no list of its own to search; Find is disabled there.
    var hasSearch: Bool { self != .graph }

    var deleteConfirmTitle: String {
        switch self {
        case .notes: return String(localized: "Delete this note?")
        case .patients: return String(localized: "Delete this patient permanently?")
        case .todos: return String(localized: "Delete this todo?")
        case .calendar: return String(localized: "Delete this event?")
        case .graph: return "Delete?"
        }
    }
}

/// Settings › General › “At launch, open”. Persisted as one string —
/// `lastUsed` or a module's raw value — so a value written by a newer build
/// that names a module this one lacks falls back to the default instead of
/// costing a launch.
enum LaunchModule: Hashable {
    case lastUsed
    case fixed(AppModule)

    /// Patients, as the window has always opened; nothing changes until the
    /// user says so.
    static let `default` = LaunchModule.fixed(.patients)
    static let lastUsedStorageValue = "lastUsed"

    init(storageValue: String?) {
        guard let storageValue else {
            self = .default
            return
        }
        if storageValue == Self.lastUsedStorageValue {
            self = .lastUsed
        } else if let module = AppModule(rawValue: storageValue) {
            self = .fixed(module)
        } else {
            self = .default
        }
    }

    var storageValue: String {
        switch self {
        case .lastUsed: return Self.lastUsedStorageValue
        case .fixed(let module): return module.rawValue
        }
    }

    /// The module to show now, given the one that was showing last time.
    func startModule(lastUsed: AppModule?) -> AppModule {
        switch self {
        case .lastUsed: return lastUsed ?? Self.default.startModule(lastUsed: nil)
        case .fixed(let module): return module
        }
    }
}

enum TodoFilter: String, CaseIterable, Identifiable {
    case all
    case pending
    case completed
    case overdue
    case today

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return String(localized: "All")
        case .pending: return String(localized: "Pending")
        case .completed: return String(localized: "Completed")
        case .overdue: return String(localized: "Overdue")
        case .today: return String(localized: "Today")
        }
    }
}

enum EventFilter: String, CaseIterable, Identifiable {
    case all
    case upcoming
    case past

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return String(localized: "All")
        case .upcoming: return String(localized: "Upcoming")
        case .past: return String(localized: "Past")
        }
    }
}

enum PatientFilter: String, CaseIterable, Identifiable {
    case active
    case archived

    var id: String { rawValue }

    var title: String {
        switch self {
        case .active: return String(localized: "Active patients")
        case .archived: return String(localized: "Archived patients")
        }
    }
}

@MainActor
final class AppSession: ObservableObject {
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
    @Published private(set) var noteEpoch = 0
    @Published var searchText = "" {
        didSet { scheduleSearch() }
    }
    @Published var errorMessage: String?

    @Published var patients: [Patient] = []
    @Published private(set) var patientDirectory: [Patient] = []
    @Published var selectedPatientId: UUID?
    @Published private(set) var patientEpoch = 0
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
    @Published private(set) var todoEpoch = 0
    @Published private(set) var todoPoolCount = 0

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
    @Published private(set) var eventEpoch = 0
    @Published private(set) var eventPoolCount = 0

    @Published private(set) var sidebarNoteCount = 0
    @Published private(set) var sidebarPatientCount = 0
    @Published private(set) var sidebarPendingTodoCount = 0
    @Published private(set) var sidebarUpcomingEventCount = 0
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
    @Published private(set) var switcherResults: [SwitcherHit] = []

    // MARK: Wiki-links & graph

    @Published private(set) var linksOut: [(label: String, kind: String)] = []
    @Published private(set) var backlinks: [(noteId: UUID, title: String)] = []
    @Published private(set) var graphData = LinkingService.GraphData()

    // MARK: Apple Calendar bridge

    let appleCalendar = AppleCalendarService()
    @Published private(set) var lastCalendarSyncSummary: String?

    // MARK: Apple Reminders bridge

    let appleReminders = AppleRemindersService()
    @Published private(set) var lastRemindersSyncSummary: String?

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
    @Published private(set) var pendingDeletion: PendingDeletion?

    private(set) var store: AppStore?
    private var searchTask: Task<Void, Never>?
    private var patientSearchTask: Task<Void, Never>?
    private var todoSearchTask: Task<Void, Never>?
    private var eventSearchTask: Task<Void, Never>?
    private var switcherTask: Task<Void, Never>?
    /// Supersedes a lookup still in flight when the query changes again.
    private var switcherGeneration = 0
    private var calendarObserverTask: Task<Void, Never>?
    private var remindersObserverTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    private var notesReloadGeneration = 0
    private var patientsReloadGeneration = 0
    private var todosReloadGeneration = 0
    private var eventsReloadGeneration = 0

    // MARK: - Settings (ADR 0001)

    /// Where preferences live. Injected so a test session never reads or
    /// writes the host's real defaults.
    private let defaults: UserDefaults

    static let launchModuleDefaultsKey = "launchModule"
    static let lastModuleDefaultsKey = "lastModule"
    static let calendarAutoSyncDefaultsKey = "calendarAutoSync"
    static let remindersAutoSyncDefaultsKey = "remindersAutoSync"
    static let defaultNoteTemplateDefaultsKey = "defaultNoteTemplate"

    /// Which module the window opens on; the Settings picker binds to it.
    @Published var launchModule: LaunchModule {
        didSet { defaults.set(launchModule.storageValue, forKey: Self.launchModuleDefaultsKey) }
    }

    /// Whether a granted bridge moves data on its own — pushes on every
    /// save, pulls on every change EventKit reports. On by default, which is
    /// how the bridges have always behaved; off, only Sync Now moves data.
    /// Deletes are not gated: a synced row deleted here loses its Apple copy
    /// at once either way, or the next pass would bring it back as new.
    @Published private(set) var calendarAutoSyncEnabled: Bool
    @Published private(set) var remindersAutoSyncEnabled: Bool

    /// Absent means on: `bool(forKey:)` would read a never-set key as off.
    private static func autoSyncSetting(_ defaults: UserDefaults, key: String) -> Bool {
        defaults.object(forKey: key) as? Bool ?? true
    }

    func setCalendarAutoSync(_ on: Bool) async {
        guard on != calendarAutoSyncEnabled else { return }
        calendarAutoSyncEnabled = on
        defaults.set(on, forKey: Self.calendarAutoSyncDefaultsKey)
        try? await store?.audit.log(
            action: on ? "calendar_auto_sync_on" : "calendar_auto_sync_off",
            entityType: "calendar", entityId: "settings")
    }

    func setRemindersAutoSync(_ on: Bool) async {
        guard on != remindersAutoSyncEnabled else { return }
        remindersAutoSyncEnabled = on
        defaults.set(on, forKey: Self.remindersAutoSyncDefaultsKey)
        try? await store?.audit.log(
            action: on ? "reminders_auto_sync_on" : "reminders_auto_sync_off",
            entityType: "reminders", entityId: "settings")
    }

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
    private var seededNoteContent: [UUID: String] = [:]

    func isUntouchedNewNote(_ note: Note) -> Bool {
        note.isUntouchedNewRecord(seededContent: seededNoteContent[note.id])
    }

    /// The record editors on screen, by the token each registered with, and
    /// how to read each one's draft. `closeStore` reads them all before it
    /// detaches the store; see `OpenEditorDraft`.
    private var openEditors: [UUID: () -> OpenEditorDraft?] = [:]

    /// Called by a record editor when it appears. `draft` must not capture
    /// the view itself (pass its state bindings), or the session would keep
    /// the view alive.
    func registerOpenEditor(_ token: UUID, draft: @escaping () -> OpenEditorDraft?) {
        openEditors[token] = draft
    }

    func unregisterOpenEditor(_ token: UUID) {
        openEditors[token] = nil
    }

    /// The open store's layout, once `bootstrap` has resolved it.
    private(set) var dataRoot: DataRoot?

    /// The retired Markdown mirror's folder. Kept only so the upgrade can
    /// reconcile it once and then report it for deletion.
    var legacyVaultURL: URL? {
        dataRoot?.vaultURL
    }

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
    private var lockRequests = 0

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
        let plaintext = try Database(path: dataRoot.databaseURL.path)
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
        graphData = LinkingService.GraphData()
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
                case .patient(let patient, let edited):
                    if edited {
                        try await store.patients.save(patient)
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

    /// What Settings › Data shows about the store itself.
    func storageSummary() async -> StorageSummary? {
        guard let store, let dataRoot else { return nil }
        let counts = (try? await store.counts()) ?? [:]
        let lastBackup = (try? await store.audit.latest(action: "backup_create"))
            .flatMap { $0.map { StorageSummary.LastBackup(date: $0.timestamp, name: $0.entityId) } }
        return StorageSummary(
            rootURL: dataRoot.rootURL,
            backupsURL: dataRoot.backupsURL,
            counts: counts,
            lastBackup: lastBackup)
    }

    /// The encrypted restore points, newest first, each measured.
    /// Measuring walks the file, so it runs off the main actor.
    func restorePoints() async -> [RestorePoint] {
        guard let store else { return [] }
        let infos = (try? store.backups.listRestorePoints()) ?? []
        return await Task.detached(priority: .utility) {
            infos.map { info in
                RestorePoint(url: info.url, createdAt: info.manifest.createdAt, name: info.manifest.name,
                             counts: info.manifest.counts, sizeBytes: BackupService.sizeOnDisk(at: info.url))
            }
        }.value
    }

    func deleteRestorePoint(_ point: RestorePoint) async throws {
        let store = try openStore()
        try store.backups.removeRestorePoint(at: point.url)
        try? await store.audit.log(
            action: "restore_point_delete", entityType: "backup", entityId: point.id,
            details: "Deleted restore point \"\(point.name)\"")
    }

    /// Keeps the newest `BackupService.restorePointsToKeep`, audited when
    /// anything went. Housekeeping only: a failed prune costs disk, not data.
    func pruneRestorePoints() async {
        guard let store else { return }
        guard let removed = try? store.backups.pruneRestorePoints(),
              !removed.isEmpty else { return }
        try? await store.audit.log(
            action: "restore_point_prune", entityType: "backup", entityId: "restore-points",
            details: "Removed \(removed.count) older restore point(s)")
    }

    /// Set by the launch check or a failed Check Now, shown as a banner in
    /// the main window; a passing check clears it. Dismissable for the
    /// session — it comes back on the next launch while the store still fails.
    @Published var integrityWarning: String?

    /// The checks a backup must pass before it is trusted, run on the live
    /// store on request. The outcome lands in the audit trail either way.
    func checkIntegrity() async -> IntegrityReport {
        guard let store else {
            return IntegrityReport(passed: false, checkedAt: Date(),
                                   detail: String(localized: "The store is not open."))
        }
        let report = await runIntegrityChecks(on: store)
        try? await store.audit.log(
            action: "integrity_check", entityType: "store", entityId: "settings",
            details: report.passed ? "ok" : report.detail)
        integrityWarning = report.passed ? nil : report.detail
        return report
    }

    /// The same checks after launch, off the critical path: nothing on a
    /// pass (a row per launch would drown the trail), the warning and an
    /// audit row on a failure.
    func checkIntegrityQuietly() async {
        guard let store else { return }
        let report = await runIntegrityChecks(on: store)
        if report.passed {
            integrityWarning = nil
            return
        }
        try? await store.audit.log(
            action: "integrity_check", entityType: "store", entityId: "launch",
            details: report.detail)
        integrityWarning = report.detail
    }

    private func runIntegrityChecks(on store: AppStore) async -> IntegrityReport {
        do {
            let result = try await store.integrity()
            let violations = try await store.foreignKeyViolations()
            let passed = result == "ok" && violations == 0
            let detail: String
            if passed {
                detail = String(localized: "No problems found.")
            } else if result != "ok" {
                detail = String(localized: "The database file is damaged. SQLite reports: \(result)")
            } else {
                detail = String(localized: "\(violations) records point to a patient that no longer exists.")
            }
            return IntegrityReport(passed: passed, checkedAt: Date(), detail: detail)
        } catch {
            return IntegrityReport(passed: false, checkedAt: Date(), detail: error.localizedDescription)
        }
    }

    // MARK: - Destination wizard

    /// Presented after permission when a bridge has no confirmed destination
    /// or its destination went stale.
    struct DestinationFlow: Identifiable {
        let bridge: SyncBridgeType
        let wizard: SyncDestinationWizard
        var id: String { bridge.rawValue }
    }

    @Published var destinationFlow: DestinationFlow?

    /// Builds the wizard for a bridge from live EventKit state. Requires
    /// access to have been granted; `Sync Now` is what raises the dialog.
    func presentDestinationWizard(for bridge: SyncBridgeType) async {
        guard !PreviewSeed.isActive else { return }
        guard let store else { return }
        // The disclosure names what would leave the app. Count the whole
        // store, not the list column's current search or filter: a filtered
        // view would understate it.
        let recordSummary: String
        let fields: [String]
        let recordCount: Int
        switch bridge {
        case .calendar:
            recordCount = (try? await store.events.loadAll().count) ?? events.count
            recordSummary = String(localized: "\(recordCount) calendar event(s) from MedNotes.")
            fields = [String(localized: "title"), String(localized: "notes"),
                      String(localized: "start and end dates"), String(localized: "all-day flag")]
        case .reminders:
            recordCount = (try? await store.todos.loadAll().count) ?? todos.count
            recordSummary = String(localized: "\(recordCount) todo(s) from MedNotes.")
            fields = [String(localized: "title"), String(localized: "notes"),
                      String(localized: "due day"), String(localized: "completion"),
                      String(localized: "priority")]
        }

        let sources: [SyncDestinationWizard.SourceOption]
        let existing: [SyncDestinationCandidate]
        let create: (String) async throws -> SyncDestinationCandidate
        let confirm: (SyncDestinationCandidate) async throws -> SyncDestination

        switch bridge {
        case .calendar:
            sources = appleCalendar.sourceCandidates().map {
                SyncDestinationWizard.SourceOption(
                    identifier: $0.identifier, title: $0.title, type: $0.type, isCloud: $0.isCloud)
            }
            existing = appleCalendar.destinationCandidates(
                recordCount: recordCount, transmittedFields: fields)
            create = { try self.appleCalendar.createMedNotesCalendar(inSource: $0) }
        case .reminders:
            sources = appleReminders.sourceCandidates().map {
                SyncDestinationWizard.SourceOption(
                    identifier: $0.identifier, title: $0.title, type: $0.type, isCloud: $0.isCloud)
            }
            existing = appleReminders.destinationCandidates(
                recordCount: recordCount, transmittedFields: fields)
            create = { try self.appleReminders.createMedNotesList(inSource: $0) }
        }

        confirm = { candidate in
            let destination = try await store.destinations.confirm(bridge: bridge, candidate: candidate)
            try? await store.audit.log(
                action: "sync_destination_confirm",
                entityType: bridge == .calendar ? "calendar" : "reminders",
                entityId: destination.calendarIdentifier,
                details: "Confirmed a \(candidate.sourceType) destination; appCreated=\(candidate.isAppCreated)")
            return destination
        }
        destinationFlow = DestinationFlow(
            bridge: bridge,
            wizard: SyncDestinationWizard(
                bridge: bridge == .calendar ? .calendar : .reminders,
                sources: sources,
                existing: existing,
                recordSummary: recordSummary,
                transmittedFields: fields,
                createInSource: create,
                confirm: { candidate in
                    let destination = try await confirm(candidate)
                    await self.refreshSyncDestinations()
                    self.destinationFlow = nil
                    return destination
                },
                onCancel: { self.destinationFlow = nil }))
    }

    /// Legacy mappings are used only to preselect: a unique candidate is
    /// offered, never auto-confirmed; multiple or none opens the chooser.
    func legacyPreselection(for bridge: SyncBridgeType) async -> SyncDestinationCandidate? {
        guard let store else { return nil }
        let domain = bridge == .calendar ? "calendar" : "reminders"
        let mappings = (try? await store.destinations.allMappings(domain: domain)) ?? []
        guard !mappings.isEmpty else { return nil }
        let candidates: [SyncDestinationCandidate]
        switch bridge {
        case .calendar:
            candidates = appleCalendar.destinationCandidates(recordCount: events.count, transmittedFields: [])
        case .reminders:
            candidates = appleReminders.destinationCandidates(recordCount: todos.count, transmittedFields: [])
        }
        return SyncDestinationCore.preselectLegacyCandidate(
            mappings: mappings, candidates: candidates)
    }

    // MARK: - Sync destination state

    /// What Settings › Sync reports about each bridge's confirmed destination.
    /// Nil before a destination is chosen; the wizard writes one.
    @Published private(set) var syncDestinationCandidates: [SyncBridgeType: SyncDestinationViewState] = [:]

    /// Refreshes the published destination state from the encrypted store.
    func refreshSyncDestinations() async {
        guard let store else {
            syncDestinationCandidates = [:]
            return
        }
        var next: [SyncBridgeType: SyncDestinationViewState] = [:]
        for destination in (try? await store.destinations.allDestinations()) ?? [] {
            next[destination.bridgeType] = SyncDestinationViewState(
                bridge: destination.bridgeType,
                calendarTitle: destination.calendarTitle,
                sourceTitle: destination.sourceTitle,
                sourceType: destination.sourceType,
                state: destination.state,
                appCreated: destination.appCreated)
        }
        syncDestinationCandidates = next
    }

    /// True when the bridge may write: a confirmed destination with a recorded
    /// consent, and no restore since.
    func maySync(_ bridge: SyncBridgeType) async -> Bool {
        guard let store else { return false }
        return (try? await store.destinations.destination(for: bridge))?.mayReceiveWrites ?? false
    }

    // MARK: - Backups

    enum BackupFlow: Identifiable {
        case backUp
        case restore(fileURL: URL)

        var id: String {
            switch self {
            case .backUp: return "backUp"
            case .restore(let url): return "restore:\(url.path)"
            }
        }
    }

    @Published var backupFlow: BackupFlow?
    /// What the last backup, restore or import did, for the confirmation alert.
    @Published var notice: String?

    /// Whether the store is open for the menu commands: ready, unlocked, with
    /// a store behind the curtain. A sheet opened while locked would sit above
    /// the curtain, and a session that lost its key has nothing to act on.
    var canUseStore: Bool {
        isReady && !isLocked && !needsRecovery && store != nil
    }

    func presentBackup() {
        guard canUseStore else { return }
        backupFlow = .backUp
    }

    /// Picks the archive first; the passphrase is asked for in the sheet.
    func presentRestore() async {
        guard canUseStore else { return }
        let chosen = await choose(FilePanelRequest(
            kind: .file(types: [.data]),
            message: String(localized: "Choose a MedNotes backup (.\(EncryptedBackupFormat.fileExtension)).")))
        // A lock closes the panel, and a choice that lands after one is dropped.
        guard let url = chosen, canUseStore else { return }
        backupFlow = .restore(fileURL: url)
    }

    func dismissBackupFlow() {
        backupFlow = nil
    }

    // MARK: File panels and what leaves the container

    /// Shows a file panel where a lock can still reach the session, and
    /// returns what the user chose: nil when they cancelled, a lock closed
    /// the panel, or the session locked before it could open.
    ///
    /// `runModal()` spins a nested run loop until the panel closes. Inside a
    /// main-actor job, as every `Task` and `async` method here runs, that
    /// loop cannot drain the main queue, which the job itself holds: every
    /// other main-actor task waits for the panel, the lock's among them, since
    /// the system lock events and the idle check each lock through a `Task`.
    /// Back Up and the Markdown export ran their panels that way, so a screen
    /// lock or sleep with the panel open left the store open and its keys in
    /// memory until the panel closed, and the lock then landed under the
    /// backup or export the panel had just started. From a run-loop block, as
    /// AppKit runs a menu command, the job has already suspended: the panel's
    /// loop drains the queue as `NSApp.run` does, and a lock goes ahead and
    /// closes the panel (`closeStore`). Default mode only, so a panel never
    /// opens inside a menu being tracked or another modal session.
    private func choose(_ request: FilePanelRequest) async -> URL? {
        await withCheckedContinuation { continuation in
            RunLoop.main.perform(inModes: [.default]) {
                let url = MainActor.assumeIsolated {
                    // A lock that ran first leaves nothing to choose for.
                    self.canUseStore ? self.panels.run(request) : nil
                }
                continuation.resume(returning: url)
            }
        }
    }

    /// The backups and Markdown exports under way, which write outside the
    /// container, by token. A lock cancels each one (`closeStore`), and they
    /// look for that before every record or note they write.
    private var outgoing: [UUID: () -> Void] = [:]

    /// Test seam: runs as a backup or export begins writing outside the
    /// container, so a test can land a lock there. Nothing in the app sets it.
    var outgoingWillBegin: @MainActor () async -> Void = {}

    /// Test seam: told as each attachment is sealed into a backup, so a test
    /// can land a lock while the archive is being written. Nothing in the app
    /// sets it.
    var backupProgress: (@Sendable (Int, Int) -> Void)?

    /// Runs `work`, a backup or export writing outside the container, as a
    /// task of its own that a lock cancels. It is registered before `work`
    /// starts, so a lock at any point from here on reaches it.
    private func runOutgoing<T: Sendable>(
        _ work: @escaping @MainActor () async throws -> T
    ) async throws -> T {
        let task = Task { @MainActor in try await work() }
        let token = UUID()
        outgoing[token] = task.cancel
        defer { outgoing[token] = nil }
        return try await task.value
    }

    // MARK: - One-time Markdown export (retired continuous mirror)

    /// Why the last Markdown export stopped short, for Settings › Data to show
    /// until the next export starts. Not an alert: the export is asked for in
    /// Settings, whose pane the lock rebuilds, and the main window, which
    /// draws the session's alerts, may be closed.
    @Published private(set) var markdownExportInterruption: String?

    /// Runs the deliberate one-time export to a user-chosen folder. The number
    /// and kinds of records are returned so the confirmation can name them, and
    /// the caller labels the result plaintext. Nil when no folder was chosen
    /// or a lock stopped the export.
    ///
    /// The store is read after the panel, never before: a lock while it was
    /// up closed it. The export is on the audit trail before any plaintext
    /// leaves the app, and one the trail cannot record does not run. A lock
    /// while the files are written stops the export before its next note, and
    /// Settings › Data says how many went (`markdownExportInterruption`).
    func exportMarkdownVault() async throws -> MarkdownExportService.ExportReport? {
        guard canUseStore else { throw StoreNotOpenError() }
        markdownExportInterruption = nil
        let chosen = await choose(FilePanelRequest(
            kind: .folder(canCreate: true),
            message: String(localized: "Choose a folder for the plaintext Markdown export.")))
        guard let url = chosen, canUseStore, let store else { return nil }
        let locksAtStart = lockRequests
        let service = MarkdownExportService(db: store.db)
        let noteCount: Int
        let report: MarkdownExportService.ExportReport
        do {
            // One task from the folder on: a lock while the notes are read or
            // audited cancels it as surely as one while they are written.
            let outcome = try await runOutgoing {
                let prepared = try await service.prepare()
                try await store.audit.log(
                    action: "markdown_export", entityType: "export", entityId: url.lastPathComponent,
                    details: "notes=\(prepared.noteCount) bytes=\(prepared.byteCount)")
                await self.outgoingWillBegin()
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                return (prepared.noteCount, try await service.write(prepared, to: url))
            }
            noteCount = outcome.0
            report = outcome.1
        } catch where lockRequests != locksAtStart {
            // Nothing was written: the lock closed the store under the read or
            // the audit.
            return nil
        }
        if report.wasCancelled {
            // Said where the export was asked for. The Settings pane that asked
            // is rebuilt by the lock, and the main window may be closed.
            markdownExportInterruption = String(localized: "MedNotes locked during the Markdown export: \(report.notesWritten) of \(noteCount) notes were written to “\(url.lastPathComponent)” as plaintext before it stopped. Export again to write them all.")
            return nil
        }
        if !report.failures.isEmpty {
            // A partial export must not read as a complete one. The report
            // names the notes that were written; this says the rest were not.
            markdownExportInterruption = String(localized: "The Markdown export wrote \(report.notesWritten) of \(noteCount) notes to “\(url.lastPathComponent)”; \(report.failures.count) could not be written. Export again to write them all.")
            return nil
        }
        notice = String(localized: "Exported \(report.notesWritten) notes as plaintext Markdown.")
        return report
    }

    /// What Settings › Data shows after the mirror is retired: every note the
    /// vault knew about, classified against the database. Nil before upgrade
    /// scanning or when there is no vault folder.
    func legacyVaultReport() async -> VaultReconciliation.Report? {
        guard let store, let dataRoot else { return nil }
        let root = dataRoot.vaultURL
        guard FileManager.default.fileExists(atPath: root.path) else { return nil }
        let scan = VaultReconciliation.scan(root: root)
        let notes = (try? await store.db.loadAllNotes()) ?? []
        var report = VaultReconciliation.reconcile(vaultNotes: scan.notes, databaseNotes: notes)
        report.parseFailures = scan.failures
        return report
    }

    /// Takes the vault's copy of a divergent note. The mirror is deleted only
    /// after every divergent item has been resolved.
    func resolveVaultItem(_ item: VaultReconciliation.Item, takeVaultCopy: Bool) async throws {
        guard takeVaultCopy, let dataRoot else { return }
        let store = try openStore()
        let scan = VaultReconciliation.scan(root: dataRoot.vaultURL)
        guard let entry = scan.notes.first(where: { $0.note.id == item.noteID }) else { return }
        try await store.notes.save(entry.note)
        noteEpoch += 1
        await reload()
    }

    /// Deletes the retired plaintext mirror. Only reached after the user has
    /// seen the reconciliation report and confirmed.
    func deleteLegacyVault() async throws {
        guard let store, let dataRoot else { return }
        let url = dataRoot.vaultURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
        try? await store.audit.log(
            action: "legacy_vault_delete", entityType: "vault", entityId: "vault",
            details: "Deleted the retired plaintext Markdown mirror")
        notice = String(localized: "The plaintext Markdown mirror was deleted.")
    }

    /// Asks where the archive goes, then writes it there.
    ///
    /// The store and its keys are read after the panel, never before: a lock
    /// while it was up closed them. A lock while the archive is written
    /// cancels it (`closeStore`): it stops before its next record, leaves
    /// nothing where the user chose, and the alert after the unlock says so.
    func performBackup(name: String, passphrase: String) async throws {
        guard canUseStore else { return }
        let chosen = await choose(FilePanelRequest(
            kind: .save(suggestedName: "\(name).\(BackupArchiveV2.fileExtension)"),
            message: String(localized: "The backup is encrypted with the passphrase you entered.")))
        guard let url = chosen, canUseStore, let store, let coordinator else { return }
        _ = try coordinator.requireAttachmentKey()
        let locksAtStart = lockRequests
        let manifest: BackupManifest
        do {
            let progress = backupProgress
            manifest = try await runOutgoing {
                await self.outgoingWillBegin()
                return try await store.backups.createEncryptedBackup(
                    name: name, to: url, passphrase: passphrase, progress: progress)
            }
        } catch where lockRequests != locksAtStart {
            // The lock took BackupFlowSheet, and the error it would show, with
            // it; ContentView holds this alert until the unlock.
            errorMessage = String(localized: "MedNotes locked before the backup was finished, so nothing was saved to “\(url.lastPathComponent)”. Choose File › Back Up… to make one.")
            return
        }
        try? await store.audit.log(
            action: "backup_create", entityType: "backup", entityId: url.lastPathComponent,
            details: BackupFlowSheet.summary(of: manifest))
        backupFlow = nil
        notice = String(localized: "Backed up to \(url.lastPathComponent): \(BackupFlowSheet.summary(of: manifest)).")
    }

    func inspectBackup(at fileURL: URL, passphrase: String) async throws -> BackupManifest {
        guard let store else { throw BackupError.invalidArchive }
        // v1 archives are accepted read-only; v2 is the write format. Only a
        // file that is not v2 at all is tried as v1: a wrong passphrase or a
        // damaged v2 archive must report that, not "not a MedNotes backup".
        do {
            return try store.backups.inspectEncryptedBackup(at: fileURL, passphrase: passphrase)
        } catch BackupArchiveV2.ArchiveError.notAnArchive {
            return try store.backups.inspectLegacyBackup(at: fileURL, passphrase: passphrase)
        }
    }

    func performRestore(from fileURL: URL, passphrase: String) async throws {
        guard let store, let coordinator else { return }
        let databaseKey = try coordinator.requireDatabaseKey()
        let attachmentKey = try coordinator.requireAttachmentKey()
        let manifest: BackupManifest
        do {
            do {
                manifest = try await store.backups.restore(
                    fromEncryptedBackupAt: fileURL, passphrase: passphrase,
                    databaseKey: databaseKey, attachmentKey: attachmentKey)
            } catch BackupArchiveV2.ArchiveError.notAnArchive {
                // Only a container that is not v2 at all is tried as v1. Any
                // other failure is about a v2 archive and must not be retried
                // against a store that a failed install may have touched.
                manifest = try await store.backups.restore(
                    fromLegacyBackupAt: fileURL, passphrase: passphrase,
                    databaseKey: databaseKey, attachmentKey: attachmentKey)
            }
        } catch let error as BackupError {
            if case .rollbackFailed = error {
                // The live files may be half replaced: nothing may use this
                // session. The folder named in the message holds the originals.
                errorMessage = error.localizedDescription
                await lockNow(reason: "restore-rollback-failed")
            }
            throw error
        }
        try? await store.audit.log(
            action: "backup_restore", entityType: "backup", entityId: fileURL.lastPathComponent,
            details: BackupFlowSheet.summary(of: manifest))
        await pruneRestorePoints()
        // Every record may have changed identity; start the UI over. Sync is
        // suspended until the user reconfirms each destination.
        selectedNoteId = nil
        selectedPatientId = nil
        selectedTodoId = nil
        selectedEventId = nil
        noteEpoch += 1
        patientEpoch += 1
        todoEpoch += 1
        eventEpoch += 1
        await reload()
        await reloadPatients()
        await reloadPatientDirectory()
        await reloadTodos()
        await reloadEvents()
        // The restore marked every destination stale in the database; make
        // Settings › Sync show that instead of the pre-restore confirmation.
        await refreshSyncDestinations()
        // Health and pass summaries belonged to the store just replaced.
        integrityWarning = nil
        lastCalendarSyncSummary = nil
        lastRemindersSyncSummary = nil
        backupFlow = nil
        notice = String(localized: "Restored \(DisplayCopy.backupName(manifest.name)): \(BackupFlowSheet.summary(of: manifest)). Reconnect Calendar and Reminders before syncing again.")
    }

    // MARK: - Activity

    func recentActivity(limit: Int = 500) async -> [AuditLogEntry] {
        guard let store else { return [] }
        return (try? await store.audit.recentLogs(limit: limit)) ?? []
    }

    // MARK: - Legacy import

    struct ImportFlow: Identifiable {
        let folderURL: URL
        var id: String { folderURL.path }
    }

    static let legacyImportBookmarkKey = "legacyImportBookmark"

    @Published var importFlow: ImportFlow?

    /// Picks the legacy folder; the sheet dry-runs it before anything is written.
    func presentImport() async {
        guard canUseStore else { return }
        var lastFolder: URL?
        if let data = defaults.data(forKey: Self.legacyImportBookmarkKey) {
            var stale = false
            lastFolder = try? URL(resolvingBookmarkData: data, options: .withSecurityScope,
                                  relativeTo: nil, bookmarkDataIsStale: &stale)
        }
        let chosen = await choose(FilePanelRequest(
            kind: .folder(canCreate: false),
            message: String(localized: "Choose the legacy MedNotes folder — the one containing Patients, Notes, Todos and CalendarEvents."),
            directoryURL: lastFolder))
        // A lock closes the panel, and a choice that lands after one is dropped.
        guard let url = chosen, canUseStore else { return }
        // Keep the grant so a later run starts where this one did.
        if let bookmark = try? url.bookmarkData(options: .withSecurityScope,
                                                includingResourceValuesForKeys: nil, relativeTo: nil) {
            defaults.set(bookmark, forKey: Self.legacyImportBookmarkKey)
        }
        importFlow = ImportFlow(folderURL: url)
    }

    func dismissImportFlow() {
        importFlow = nil
    }

    /// The folder read into a throwaway store: the report is exactly what the
    /// real import would do, and the real store is not touched.
    func dryRunImport(from folderURL: URL) async throws -> ImportReport {
        let scratch = try DataRoot.temporary()
        defer { try? FileManager.default.removeItem(at: scratch.rootURL) }
        let accessing = folderURL.startAccessingSecurityScopedResource()
        defer { if accessing { folderURL.stopAccessingSecurityScopedResource() } }
        let db = try Database(path: scratch.databaseURL.path)
        // The same attachment path as the real import, into a store of its own
        // that is removed with the scratch root, so both report the same things.
        let report = try await JSONImporter(directoryURL: folderURL)
            .importAll(
                into: db,
                fileStore: EncryptedFileStore(
                    root: scratch.attachmentsURL, key: StoreKeyContext.newRootKey()))
        await db.close()
        return report
    }

    /// Restore point first: the importer is idempotent, but a folder full of
    /// surprises must never be a one-way door.
    func performImport(from folderURL: URL) async throws {
        guard let store else { return }
        let accessing = folderURL.startAccessingSecurityScopedResource()
        defer { if accessing { folderURL.stopAccessingSecurityScopedResource() } }
        _ = try await store.backups.createEncryptedRestorePoint(name: "Pre-import snapshot")
        // Legacy JSON import stages through the encrypted attachment store:
        // an inline file is encrypted on save, never written beside the store.
        let report = try await JSONImporter(directoryURL: folderURL)
            .importAll(into: store.db, filesRoot: nil, fileStore: store.fileStore)
        try? await store.audit.log(
            action: "import_legacy", entityType: "import", entityId: folderURL.lastPathComponent,
            details: ImportFlowSheet.summary(of: report))
        await pruneRestorePoints()
        noteEpoch += 1
        patientEpoch += 1
        todoEpoch += 1
        eventEpoch += 1
        await reload()
        await reloadPatients()
        await reloadPatientDirectory()
        await reloadTodos()
        await reloadEvents()
        importFlow = nil
        notice = String(localized: "Imported \(ImportFlowSheet.summary(of: report)).")
    }

    /// The store to open. `nil` resolves the real one (or the preview root
    /// under `--preview-seed`); tests pass a temporary root and never touch
    /// Application Support.
    private let injectedDataRoot: DataRoot?
    /// Test seam: when set, key material comes from here instead of the
    /// Keychain, so the suite never prompts or reads the user's real items.
    private let injectedKeyManager: KeyManager?
    /// The open and save panels; tests pass their own. See `FilePanels`.
    private let panels: FilePanels

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
        let rootKey = try coordinator.createMigrationKey()
        let migrator = StoreMigrator(dataRoot: dataRoot, keyManager: coordinator.keyManager)
        do {
            let report = try await migrator.migrate(
                backupDestination: backupURL, passphrase: passphrase)
            try await migrator.finishCleanup()
            migrationReport = report
            try coordinator.finishMigration(rootKey: rootKey)
            let store = try AppStore(
                dataRoot: dataRoot,
                databaseKey: coordinator.requireDatabaseKey(),
                attachmentKey: coordinator.requireAttachmentKey(),
                restorePointKey: coordinator.requireRestoreKey())
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
        } catch {
            await migrator.rollbackStaging()
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

    /// Observes the Apple Calendar bridge for external changes and triggers
    /// an automatic pull when EventKit reports modifications.
    ///
    /// The flag's current value counts: EventKit keeps reporting while the
    /// store is locked, and a change made in Calendar meanwhile is pulled by
    /// the pass this starts on unlock (through the usual automatic gates).
    /// The `false` that a pass publishes when it consumes the flag is not a
    /// change and starts nothing.
    private func observeCalendarChanges() {
        calendarObserverTask?.cancel()
        calendarObserverTask = Task { @MainActor in
            for await pending in appleCalendar.$hasPendingExternalChanges.values where pending {
                guard !Task.isCancelled else { return }
                await syncCalendarNow(automatic: true)
            }
        }
    }

    /// Observes the Apple Reminders bridge for external changes and triggers
    /// an automatic pull when EventKit reports modifications; see
    /// `observeCalendarChanges`.
    private func observeRemindersChanges() {
        remindersObserverTask?.cancel()
        remindersObserverTask = Task { @MainActor in
            for await pending in appleReminders.$hasPendingExternalChanges.values where pending {
                guard !Task.isCancelled else { return }
                await syncRemindersNow(automatic: true)
            }
        }
    }

    /// Starts the EventKit change observers once the store is ready.
    ///
    /// Kept as a condition rather than removed under preview: an EventKit
    /// notification here is the first link in the chain that ends with
    /// seeded events being pushed to the user's real calendar, but deleting
    /// the line outright would silently cost the real app its sync with no
    /// test covering the loss.
    private func startBridgeObservation() {
        if !PreviewSeed.isActive {
            appleCalendar.startObservingChanges()
            appleReminders.startObservingChanges()
        }
    }

    func reload() async {
        guard let store else { return }
        notesReloadGeneration += 1
        let generation = notesReloadGeneration
        do {
            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            let result: [Note]
            let totalCount: Int?
            if query.isEmpty {
                result = try await store.notes.loadAll()
                totalCount = result.count
            } else {
                result = try await store.notes.search(query)
                totalCount = nil
            }
            guard generation == notesReloadGeneration else { return }
            if let totalCount { sidebarNoteCount = totalCount }
            notes = result
        } catch {
            guard generation == notesReloadGeneration else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            await reload()
        }
    }

    func newNote() async {
        guard let store else { return }
        var note = Note.newRecord()
        // A default template seeds the body; no patient is linked yet, so
        // {{patient}} renders as the placeholder dash.
        if let templateID = defaultNoteTemplateID,
           let template = (try? await store.templates.allTemplates())?.first(where: { $0.id == templateID }) {
            note.content = template.rendered(patientName: nil)
            seededNoteContent[note.id] = note.content
        }
        do {
            try await store.notes.save(note)
            selectedNoteId = note.id
            pendingFocusRecordId = note.id
            noteEpoch += 1
            // Clear the text before cancelling so the didSet-scheduled
            // debounce task is the one that gets cancelled.
            if !searchText.isEmpty { searchText = "" }
            searchTask?.cancel()
            await reload()
        } catch {
            errorMessage = error.localizedDescription
            if await noteExists(id: note.id) == true {
                selectedNoteId = note.id
                pendingFocusRecordId = note.id
                if !searchText.isEmpty { searchText = "" }
                searchTask?.cancel()
            }
            noteEpoch += 1
            await reload()
        }
    }

    func select(_ noteId: UUID?) {
        selectedNoteId = noteId
    }

    @discardableResult
    func save(_ note: Note) async -> Bool {
        guard let store else { return false }
        do {
            try await store.notes.save(note)
            // Once the body is the user's own, the seed no longer matters.
            if seededNoteContent[note.id] != nil, !isUntouchedNewNote(note) {
                seededNoteContent[note.id] = nil
            }
            noteEpoch += 1
            await reload()
            return true
        } catch {
            errorMessage = error.localizedDescription
            noteEpoch += 1
            await reload()
            return false
        }
    }

    func deleteNote(id: UUID) async {
        await removeNote(id: id, discarding: false)
    }

    /// Drops a note the user created and then left exactly as created, so an
    /// abandoned "+" never leaves a "New Note" row behind. The editor calls
    /// this on the way out; see `Note.isUntouchedNewRecord`.
    func discardIfUntouched(_ note: Note) async {
        guard isUntouchedNewNote(note),
              await noteExists(id: note.id) == true else { return }
        await removeNote(id: note.id, discarding: true)
        seededNoteContent[note.id] = nil
    }

    private func removeNote(id: UUID, discarding: Bool) async {
        guard let store else { return }
        do {
            if discarding {
                try await store.notes.discard(id: id)
            } else {
                try await store.notes.delete(id: id)
            }
            if selectedNoteId == id { selectedNoteId = nil }
            noteEpoch += 1
            await reload()
        } catch {
            errorMessage = error.localizedDescription
            if selectedNoteId == id,
               await noteExists(id: id) == false {
                selectedNoteId = nil
            }
            noteEpoch += 1
            await reload()
        }
    }

    func deleteSelected() async {
        guard let id = selectedNoteId else { return }
        await deleteNote(id: id)
    }

    @discardableResult
    func togglePin(_ note: Note) async -> Bool {
        guard let store else { return false }
        do {
            try await store.notes.togglePin(id: note.id)
            noteEpoch += 1
            await reload()
            return true
        } catch {
            errorMessage = error.localizedDescription
            noteEpoch += 1
            await reload()
            return false
        }
    }

    func loadSelectedNote() async -> Note? {
        guard let store, let id = selectedNoteId else { return nil }
        do {
            return try await store.notes.load(id: id)
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// Tri-state: true/false = existence, nil = the lookup itself failed
    /// (error surfaced via errorMessage). Callers must compare explicitly so a
    /// transient store error is never mistaken for "does not exist".
    func noteExists(id: UUID) async -> Bool? {
        guard let store else { return nil }
        do {
            return try await store.notes.load(id: id) != nil
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    // MARK: - Patients

    func reloadPatients() async {
        guard let store else { return }
        patientsReloadGeneration += 1
        let generation = patientsReloadGeneration
        do {
            let query = patientSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
            let showArchived = patientFilter == .archived
            let loaded = query.isEmpty
                ? try await store.patients.loadAll(includeArchived: showArchived)
                : try await store.patients.search(query, includeArchived: showArchived)
            guard generation == patientsReloadGeneration else { return }
            // The sidebar badge counts active patients; the directory reload keeps it.
            patients = showArchived ? loaded.filter(\.isArchived) : loaded
        } catch {
            guard generation == patientsReloadGeneration else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func schedulePatientSearch() {
        patientSearchTask?.cancel()
        patientSearchTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            await reloadPatients()
        }
    }

    func newPatient() async {
        guard let store else { return }
        let patient = Patient.newRecord()
        do {
            try await store.patients.save(patient)
            // A new patient is active. Creating one while the Archived list is
            // showing would select a row that list does not contain, so follow
            // it to the list it belongs to before setting the selection.
            if patientFilter != .active { patientFilter = .active }
            selectedPatientId = patient.id
            pendingFocusRecordId = patient.id
            patientEpoch += 1
            if !patientSearchText.isEmpty { patientSearchText = "" }
            patientSearchTask?.cancel()
            await reloadPatients()
            await reloadPatientDirectory()
        } catch {
            errorMessage = error.localizedDescription
            if await patientExists(id: patient.id) == true {
                if patientFilter != .active { patientFilter = .active }
                selectedPatientId = patient.id
                pendingFocusRecordId = patient.id
                if !patientSearchText.isEmpty { patientSearchText = "" }
                patientSearchTask?.cancel()
            }
            patientEpoch += 1
            await reloadPatients()
            await reloadPatientDirectory()
        }
    }

    func selectPatient(_ patientId: UUID?) {
        selectedPatientId = patientId
    }

    @discardableResult
    func save(_ patient: Patient, knownFileIDs: Set<UUID>? = nil) async -> Bool {
        guard let store else { return false }
        do {
            try await store.patients.save(patient, knownFileIDs: knownFileIDs)
            patientEpoch += 1
            await reloadPatients()
            await reloadPatientDirectory()
            todoEpoch += 1
            eventEpoch += 1
            noteEpoch += 1
            await reloadTodos()
            await reloadEvents()
            await reload()
            return true
        } catch {
            errorMessage = error.localizedDescription
            patientEpoch += 1
            await reloadPatients()
            await reloadPatientDirectory()
            todoEpoch += 1
            eventEpoch += 1
            noteEpoch += 1
            await reloadTodos()
            await reloadEvents()
            await reload()
            return false
        }
    }

    func deletePatient(id: UUID) async {
        await removePatient(id: id, discarding: false)
    }

    /// Drops a patient the user created and then left exactly as created, so
    /// an abandoned "+" never leaves an "Unnamed Patient" row behind. The
    /// editor calls this on the way out; see `Patient.isUntouchedNewRecord`.
    func discardIfUntouched(_ patient: Patient) async {
        guard patient.isUntouchedNewRecord,
              await patientExists(id: patient.id) == true else { return }
        await removePatient(id: patient.id, discarding: true)
    }

    private func removePatient(id: UUID, discarding: Bool) async {
        guard let store else { return }
        do {
            if discarding {
                try await store.patients.discard(id: id)
            } else {
                try await store.patients.delete(id: id)
            }
            if selectedPatientId == id { selectedPatientId = nil }
            patientEpoch += 1
            await reloadPatients()
            await reloadPatientDirectory()
            todoEpoch += 1
            eventEpoch += 1
            noteEpoch += 1
            await reloadTodos()
            await reloadEvents()
            await reload()
        } catch {
            errorMessage = error.localizedDescription
            if selectedPatientId == id,
               await patientExists(id: id) == false {
                selectedPatientId = nil
            }
            patientEpoch += 1
            await reloadPatients()
            await reloadPatientDirectory()
            todoEpoch += 1
            eventEpoch += 1
            noteEpoch += 1
            await reloadTodos()
            await reloadEvents()
            await reload()
        }
    }

    func deleteSelectedPatient() async {
        guard let id = selectedPatientId else { return }
        await deletePatient(id: id)
    }

    /// Hides the patient from the active list and pickers; the row and its
    /// links stay, and `unarchivePatient` brings it back. Every Delete
    /// affordance for an active patient does this; permanent deletion is
    /// reached only from the archived list.
    func archivePatient(id: UUID) async {
        guard let store else { return }
        do {
            try await store.patients.archive(id: id)
            if selectedPatientId == id, patientFilter == .active { selectedPatientId = nil }
        } catch {
            errorMessage = error.localizedDescription
        }
        patientEpoch += 1
        await reloadPatients()
        await reloadPatientDirectory()
    }

    func unarchivePatient(id: UUID) async {
        guard let store else { return }
        do {
            try await store.patients.unarchive(id: id)
            // Follow the record back to the active list.
            if selectedPatientId == id, patientFilter == .archived {
                patientFilter = .active
                selectedPatientId = id
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        patientEpoch += 1
        await reloadPatients()
        await reloadPatientDirectory()
    }

    func archiveSelectedPatient() async {
        guard let id = selectedPatientId else { return }
        await archivePatient(id: id)
    }

    func loadSelectedPatient() async -> Patient? {
        guard let store, let id = selectedPatientId else { return nil }
        do {
            return try await store.patients.load(id: id)
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// Tri-state: true/false = existence, nil = the lookup itself failed
    /// (error surfaced via errorMessage). Callers must compare explicitly so a
    /// transient store error is never mistaken for "does not exist".
    func patientExists(id: UUID) async -> Bool? {
        guard let store else { return nil }
        do {
            return try await store.patients.load(id: id) != nil
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    private func reloadPatientDirectory() async {
        guard let store else { return }
        do {
            patientDirectory = try await store.patients.loadAll(includeArchived: true)
            sidebarPatientCount = patientDirectory.filter { !$0.isArchived }.count
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Todos

    func reloadTodos() async {
        guard let store else { return }
        todosReloadGeneration += 1
        let generation = todosReloadGeneration
        do {
            var items = try await store.todos.loadAll(includeCompleted: true)
            let totalCount = items.filter { !$0.isCompleted }.count
            let query = todoSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !query.isEmpty {
                items = items.filter { todo in
                    var fields = [todo.title, todo.notes ?? "", todo.patientName ?? ""]
                    fields.append(contentsOf: todo.tags)
                    if let pid = todo.patientId,
                       let patient = patientDirectory.first(where: { $0.id == pid }) {
                        fields.append(patientName(for: pid) ?? "")
                        fields.append(patient.profile.fathersName ?? "")
                    }
                    return Self.matchesSearchTokens(query, fields: fields)
                }
            }
            let poolCount = items.count
            switch todoFilter {
            case .all: break
            case .pending: items = items.filter { !$0.isCompleted }
            case .completed: items = items.filter(\.isCompleted)
            case .overdue: items = items.filter(\.isOverdue)
            case .today: items = items.filter(\.isDueToday)
            }
            guard generation == todosReloadGeneration else { return }
            sidebarPendingTodoCount = totalCount
            todoPoolCount = poolCount
            todos = items
        } catch {
            guard generation == todosReloadGeneration else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func scheduleTodoSearch() {
        todoSearchTask?.cancel()
        todoSearchTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            await reloadTodos()
        }
    }

    func newTodo() async {
        guard let store else { return }
        let todo = TodoItem.newRecord()
        do {
            try await store.todos.save(todo)
            selectedTodoId = todo.id
            pendingFocusRecordId = todo.id
            todoEpoch += 1
            if !todoSearchText.isEmpty { todoSearchText = "" }
            todoSearchTask?.cancel()
            if todoFilter != .all { todoFilter = .all }
            await reloadTodos()
        } catch {
            errorMessage = error.localizedDescription
            if await todoExists(id: todo.id) == true {
                selectedTodoId = todo.id
                pendingFocusRecordId = todo.id
                if !todoSearchText.isEmpty { todoSearchText = "" }
                todoSearchTask?.cancel()
                if todoFilter != .all { todoFilter = .all }
            }
            todoEpoch += 1
            await reloadTodos()
        }
    }

    func selectTodo(_ todoId: UUID?) {
        selectedTodoId = todoId
    }

    @discardableResult
    func save(_ todo: TodoItem) async -> Bool {
        guard let store else { return false }
        let stored = normalizedForSave(todo)
        do {
            // Push the row as persisted: `stored` still carries the pre-save
            // `updatedAt`, and pushing that would make pushTodoQuietly's
            // staleness check fail every time, so the sync metadata would
            // never stick.
            let persisted = try await store.todos.save(stored)
            todoEpoch += 1
            await reloadTodos()
            await pushTodoQuietly(persisted)
            return true
        } catch {
            errorMessage = error.localizedDescription
            todoEpoch += 1
            await reloadTodos()
            return false
        }
    }

    /// The todo as `save` stores it: blank notes dropped, and the linked
    /// patient's name taken from the directory.
    private func normalizedForSave(_ todo: TodoItem) -> TodoItem {
        var stored = todo
        if stored.notes?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            stored.notes = nil
        }
        if let pid = stored.patientId,
           let patient = patientDirectory.first(where: { $0.id == pid }) {
            let name = patient.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            stored.patientName = name.isEmpty ? nil : name
        } else if stored.patientName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            stored.patientName = nil
        }
        return stored
    }

    func deleteTodo(id: UUID) async {
        await removeTodo(id: id, discarding: false)
    }

    /// Drops a todo the user created and then left exactly as created; see
    /// `TodoItem.isUntouchedNewRecord`. Goes through the same path as a
    /// deletion so a copy already pushed to Apple Reminders is removed too.
    func discardIfUntouched(_ todo: TodoItem) async {
        guard todo.isUntouchedNewRecord,
              await todoExists(id: todo.id) == true else { return }
        await removeTodo(id: todo.id, discarding: true)
    }

    private func removeTodo(id: UUID, discarding: Bool) async {
        guard let store else { return }
        // Snapshot before deletion so a linked Apple Reminders copy can go too.
        let snapshot = try? await store.todos.load(id: id)
        do {
            if discarding {
                try await store.todos.discard(id: id)
            } else {
                try await store.todos.delete(id: id)
            }
            if selectedTodoId == id { selectedTodoId = nil }
            todoEpoch += 1
            await reloadTodos()
            if let snapshot, snapshot.reminderIdentifier != nil,
               appleReminders.state == .granted,
               let destination = try? await store.destinations.destination(for: .reminders),
               SyncDestinationCore.mayWrite(destination) {
                _ = try? await appleReminders.deleteRemote(snapshot, from: destination)
            }
        } catch {
            errorMessage = error.localizedDescription
            if selectedTodoId == id,
               await todoExists(id: id) == false {
                selectedTodoId = nil
            }
            todoEpoch += 1
            await reloadTodos()
        }
    }

    func deleteSelectedTodo() async {
        guard let id = selectedTodoId else { return }
        await deleteTodo(id: id)
    }

    func toggleTodo(id: UUID) async {
        guard let store else { return }
        do {
            try await store.todos.toggle(id: id)
            todoEpoch += 1
            await reloadTodos()
            if let toggled = try? await store.todos.load(id: id) {
                await pushTodoQuietly(toggled)
            }
        } catch {
            errorMessage = error.localizedDescription
            todoEpoch += 1
            await reloadTodos()
        }
    }

    func loadSelectedTodo() async -> TodoItem? {
        guard let store, let id = selectedTodoId else { return nil }
        do {
            return try await store.todos.load(id: id)
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// Tri-state: true/false = existence, nil = the lookup itself failed
    /// (error surfaced via errorMessage). Callers must compare explicitly so a
    /// transient store error is never mistaken for "does not exist".
    func todoExists(id: UUID) async -> Bool? {
        guard let store else { return nil }
        do {
            return try await store.todos.load(id: id) != nil
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    // MARK: - Calendar

    func reloadEvents() async {
        guard let store else { return }
        eventsReloadGeneration += 1
        let generation = eventsReloadGeneration
        do {
            var items = try await store.events.loadAll()
            let totalUpcoming = items.filter(\.isUpcoming).count
            let query = eventSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !query.isEmpty {
                items = items.filter { event in
                    var fields = [event.title, event.description]
                    if let pid = event.patientId,
                       let patient = patientDirectory.first(where: { $0.id == pid }) {
                        fields.append(patientName(for: pid) ?? "")
                        fields.append(patient.profile.fathersName ?? "")
                    }
                    return Self.matchesSearchTokens(query, fields: fields)
                }
            }
            let poolCount = items.count
            switch eventFilter {
            case .all: break
            case .upcoming: items = items.filter(\.isUpcoming)
            case .past: items = items.filter { !$0.isUpcoming }
            }
            guard generation == eventsReloadGeneration else { return }
            sidebarUpcomingEventCount = totalUpcoming
            eventPoolCount = poolCount
            events = items
        } catch {
            guard generation == eventsReloadGeneration else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func scheduleEventSearch() {
        eventSearchTask?.cancel()
        eventSearchTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            await reloadEvents()
        }
    }

    func newEvent() async {
        guard let store else { return }
        let event = CalendarEvent.newRecord()
        do {
            try await store.events.save(event)
            selectedEventId = event.id
            pendingFocusRecordId = event.id
            eventEpoch += 1
            if !eventSearchText.isEmpty { eventSearchText = "" }
            eventSearchTask?.cancel()
            if eventFilter == .past { eventFilter = .upcoming }
            await reloadEvents()
        } catch {
            errorMessage = error.localizedDescription
            if await eventExists(id: event.id) == true {
                selectedEventId = event.id
                pendingFocusRecordId = event.id
                if !eventSearchText.isEmpty { eventSearchText = "" }
                eventSearchTask?.cancel()
                if eventFilter == .past { eventFilter = .upcoming }
            }
            eventEpoch += 1
            await reloadEvents()
        }
    }

    func selectEvent(_ eventId: UUID?) {
        selectedEventId = eventId
    }

    @discardableResult
    func save(_ event: CalendarEvent) async -> Bool {
        guard let store else { return false }
        var stored = event
        stored.ensureEndNotBeforeStart()
        do {
            // Push the row as persisted: `stored` still carries the pre-save
            // `updatedAt`, and pushing that would make pushQuietly's staleness
            // check fail every time, so the sync metadata would never stick.
            let persisted = try await store.events.save(stored)
            eventEpoch += 1
            await reloadEvents()
            await pushQuietly(persisted)
            return true
        } catch {
            errorMessage = error.localizedDescription
            eventEpoch += 1
            await reloadEvents()
            return false
        }
    }

    func deleteEvent(id: UUID) async {
        await removeEvent(id: id, discarding: false)
    }

    /// Drops an event the user created and then left exactly as created; see
    /// `CalendarEvent.isUntouchedNewRecord`. Goes through the same path as a
    /// deletion so a copy already pushed to Apple Calendar is removed too.
    func discardIfUntouched(_ event: CalendarEvent) async {
        guard event.isUntouchedNewRecord,
              await eventExists(id: event.id) == true else { return }
        await removeEvent(id: event.id, discarding: true)
    }

    private func removeEvent(id: UUID, discarding: Bool) async {
        guard let store else { return }
        // Snapshot before deletion so a linked Apple Calendar copy can go too.
        let snapshot = try? await store.events.load(id: id)
        do {
            if discarding {
                try await store.events.discard(id: id)
            } else {
                try await store.events.delete(id: id)
            }
            if selectedEventId == id { selectedEventId = nil }
            eventEpoch += 1
            await reloadEvents()
            if let snapshot, snapshot.ekEventIdentifier != nil,
               appleCalendar.state == .granted,
               let destination = try? await store.destinations.destination(for: .calendar),
               SyncDestinationCore.mayWrite(destination) {
                _ = try? await appleCalendar.deleteRemote(snapshot, from: destination)
            }
        } catch {
            errorMessage = error.localizedDescription
            if selectedEventId == id,
               await eventExists(id: id) == false {
                selectedEventId = nil
            }
            eventEpoch += 1
            await reloadEvents()
        }
    }

    func deleteSelectedEvent() async {
        guard let id = selectedEventId else { return }
        await deleteEvent(id: id)
    }

    func loadSelectedEvent() async -> CalendarEvent? {
        guard let store, let id = selectedEventId else { return nil }
        do {
            return try await store.events.load(id: id)
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// Tri-state: true/false = existence, nil = the lookup itself failed
    /// (error surfaced via errorMessage). Callers must compare explicitly so a
    /// transient store error is never mistaken for "does not exist".
    func eventExists(id: UUID) async -> Bool? {
        guard let store else { return nil }
        do {
            return try await store.events.load(id: id) != nil
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    // MARK: - Apple Calendar sync

    private func ensureCalendarAccess() async -> Bool {
        if appleCalendar.state == .granted { return true }
        let granted = await appleCalendar.requestAccess()
        if !granted {
            errorMessage = appleCalendar.lastError
                ?? String(localized: "Apple Calendar access is required for syncing. Enable it in System Settings › Privacy & Security › Calendars.")
        }
        return granted
    }

    private func needsPush(_ event: CalendarEvent) -> Bool {
        if event.ekEventIdentifier == nil { return true }
        guard event.syncStatus != .localOnly else { return true }
        guard let synced = event.lastSyncDate else { return true }
        return event.updatedAt > synced
    }

    /// Full two-way pass: push dirty rows, then pull remote drift. Manual via
    /// "Sync now"; automatic pull also fires when EventKit reports changes.
    ///
    /// An automatic pass never raises the permission dialog: EventKit tells
    /// every store in the process about every change, so a Reminders edit
    /// would otherwise prompt for Calendar access out of nowhere.
    func syncCalendarNow(automatic: Bool = false) async {
        guard let store else { return }
        // Sample data never reaches Apple Calendar. `needsPush` is true for
        // every seeded event, since none has an `ekEventIdentifier`.
        guard !PreviewSeed.isActive else { return }
        // Settings › Sync: off means nothing moves until Sync Now.
        if automatic, !calendarAutoSyncEnabled { return }
        if automatic, !AppleCalendarService.hasFullAccess { return }
        guard await ensureCalendarAccess() else { return }
        // No destination, no consent, no writes. The wizard creates one.
        let calendarDestination = try? await store.destinations.destination(for: .calendar)
        guard let destination = calendarDestination, SyncDestinationCore.mayWrite(destination) else {
            lastCalendarSyncSummary = SyncPassReport(skippedForConsent: 1).summary
            // Only Sync Now asks. An automatic pass runs because something
            // changed in Calendar or MedNotes was unlocked, and must not open
            // a wizard over whatever the user is doing.
            if !automatic { await presentDestinationWizard(for: .calendar) }
            return
        }
        do {
            // The destination must still exist exactly as chosen.
            guard appleCalendar.calendar(for: destination) != nil else {
                try await store.destinations.markNeedsReconnection(bridge: .calendar)
                await refreshSyncDestinations()
                throw AppleCalendarService.CalendarSyncError.destinationMissing
            }
            var locals = try await store.events.loadAll()
            var report = SyncPassReport()
            for local in locals where needsPush(local) {
                let synced = try await appleCalendar.push(local, to: destination)
                // A save during the push has already written a newer row.
                // Storing this snapshot over it would undo that edit; leave
                // the row dirty so the next pass pushes the newer version.
                if let latest = try? await store.events.load(id: synced.id),
                   latest.updatedAt <= synced.updatedAt {
                    try await store.events.saveSyncResult(synced)
                    report.pushed += 1
                }
            }
            locals = try await store.events.loadAll()
            let result = try await appleCalendar.pull(localEvents: locals, from: destination)
            var pulled = 0
            for updated in result.updates {
                if let latest = try? await store.events.load(id: updated.id),
                   latest.updatedAt <= updated.updatedAt {
                    try await store.events.saveSyncResult(updated)
                    pulled += 1
                }
            }
            for created in result.creations {
                // Not `save`: that stamps `updatedAt` past `lastSyncDate`, so
                // the imported row would read as a local edit and be pushed
                // straight back to Calendar on the next pass.
                try await store.events.saveSyncResult(created)
            }
            report.pulled = pulled
            report.created = result.creations.count
            report.conflicts = result.conflictingIDs.count
            report.remoteMissing = result.remoteMissing
            appleCalendar.consumePendingExternalChanges()
            lastCalendarSyncSummary = report.summary
            var warnings: [String] = []
            if !result.conflictingIDs.isEmpty {
                warnings.append(String(localized: "Calendar conflict: \(result.conflictingIDs.count) event(s) had unsynced local edits that were overwritten by newer versions from Apple Calendar."))
            }
            if !result.remoteMissing.isEmpty {
                warnings.append(String(localized: "Calendar: \(result.remoteMissing.count) event(s) are missing from the chosen calendar. Reconnect or resolve them manually; nothing was deleted."))
            }
            if !warnings.isEmpty { errorMessage = warnings.joined(separator: "\n\n") }
            eventEpoch += 1
            await reloadEvents()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Fire-and-forget push used right after a user edit, when access was
    /// previously granted and a destination is confirmed. Silent failure: the
    /// next Sync Now retries.
    private func pushQuietly(_ event: CalendarEvent) async {
        guard calendarAutoSyncEnabled else { return }
        guard let store, appleCalendar.state == .granted, needsPush(event),
              let destination = try? await store.destinations.destination(for: .calendar),
              SyncDestinationCore.mayWrite(destination) else { return }
        if let synced = try? await appleCalendar.push(event, to: destination),
           let latest = try? await store.events.load(id: synced.id),
           latest.updatedAt <= synced.updatedAt {
            try? await store.events.saveSyncResult(synced)
            eventEpoch += 1
        }
    }

    // MARK: - Apple Reminders sync

    private func ensureRemindersAccess() async -> Bool {
        if appleReminders.state == .granted { return true }
        let granted = await appleReminders.requestAccess()
        if !granted {
            errorMessage = appleReminders.lastError
                ?? String(localized: "Apple Reminders access is required for syncing. Enable it in System Settings › Privacy & Security › Reminders.")
        }
        return granted
    }

    private func needsPush(_ todo: TodoItem) -> Bool {
        if todo.reminderIdentifier == nil { return true }
        guard todo.syncStatus != .localOnly else { return true }
        guard let synced = todo.lastSyncDate else { return true }
        return todo.updatedAt > synced
    }

    /// Full two-way pass: push dirty rows, then pull remote drift. Manual via
    /// "Sync now"; automatic pull also fires when EventKit reports changes and,
    /// as for the calendar, never raises the permission dialog.
    func syncRemindersNow(automatic: Bool = false) async {
        guard let store else { return }
        // Sample data never reaches Apple Reminders. `needsPush` is true for
        // every seeded todo, since none has a `reminderIdentifier`.
        guard !PreviewSeed.isActive else { return }
        // Settings › Sync: off means nothing moves until Sync Now.
        if automatic, !remindersAutoSyncEnabled { return }
        if automatic, !AppleRemindersService.hasFullAccess { return }
        guard await ensureRemindersAccess() else { return }
        let remindersDestination = try? await store.destinations.destination(for: .reminders)
        guard let destination = remindersDestination, SyncDestinationCore.mayWrite(destination) else {
            lastRemindersSyncSummary = SyncPassReport(skippedForConsent: 1).summary
            // Only Sync Now asks; see `syncCalendarNow`.
            if !automatic { await presentDestinationWizard(for: .reminders) }
            return
        }
        do {
            guard appleReminders.list(for: destination) != nil else {
                try await store.destinations.markNeedsReconnection(bridge: .reminders)
                await refreshSyncDestinations()
                throw AppleRemindersService.RemindersSyncError.destinationMissing
            }
            var locals = try await store.todos.loadAll()
            var report = SyncPassReport()
            for local in locals where needsPush(local) {
                let synced = try await appleReminders.push(local, to: destination)
                // As for Calendar: a newer local edit must not be overwritten
                // by the snapshot this push started from.
                if let latest = try? await store.todos.load(id: synced.id),
                   latest.updatedAt <= synced.updatedAt {
                    try await store.todos.saveSyncResult(synced)
                    report.pushed += 1
                }
            }
            locals = try await store.todos.loadAll()
            let result = try await appleReminders.pull(localTodos: locals, from: destination)
            var pulled = 0
            for updated in result.updates {
                if let latest = try? await store.todos.load(id: updated.id),
                   latest.updatedAt <= updated.updatedAt {
                    try await store.todos.saveSyncResult(updated)
                    pulled += 1
                }
            }
            for created in result.creations {
                // Not `save`: that would stamp `updatedAt` past `lastSyncDate`
                // and the row would read as dirty and push straight back.
                try await store.todos.saveSyncResult(created)
                try await store.audit.log(
                    action: "todo_sync_import", entityType: "todo", entityId: created.id.uuidString,
                    details: "todo imported from the Apple Reminders destination")
            }
            report.pulled = pulled
            report.created = result.creations.count
            report.conflicts = result.conflictingIDs.count
            report.remoteMissing = result.remoteMissing
            appleReminders.consumePendingExternalChanges()
            lastRemindersSyncSummary = report.summary
            var warnings: [String] = []
            if !result.conflictingIDs.isEmpty {
                warnings.append(String(localized: "Reminders conflict: \(result.conflictingIDs.count) todo(s) had unsynced local edits that were overwritten by newer versions from Apple Reminders."))
            }
            if !result.remoteMissing.isEmpty {
                warnings.append(String(localized: "Reminders: \(result.remoteMissing.count) todo(s) are missing from the chosen list. Reconnect or resolve them manually; nothing was deleted."))
            }
            if !warnings.isEmpty { errorMessage = warnings.joined(separator: "\n\n") }
            todoEpoch += 1
            await reloadTodos()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Fire-and-forget push used right after a user edit, when access was
    /// previously granted. Silent failure: next Sync now retries.
    private func pushTodoQuietly(_ todo: TodoItem) async {
        guard remindersAutoSyncEnabled else { return }
        guard let store, appleReminders.state == .granted, needsPush(todo),
              let destination = try? await store.destinations.destination(for: .reminders),
              SyncDestinationCore.mayWrite(destination) else { return }
        if let synced = try? await appleReminders.push(todo, to: destination),
           let latest = try? await store.todos.load(id: synced.id),
           latest.updatedAt <= synced.updatedAt {
            try? await store.todos.saveSyncResult(synced)
            todoEpoch += 1
        }
    }

    // MARK: - Quick switcher

    private func scheduleSwitcherSearch() {
        switcherTask?.cancel()
        switcherTask = Task {
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            await updateSwitcherResults()
        }
    }

    func updateSwitcherResults() async {
        guard let store else { return }
        switcherGeneration &+= 1
        let generation = switcherGeneration
        let query = switcherText.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let notes = query.isEmpty
                ? Array((try await store.notes.loadAll()).prefix(6))
                : try await store.notes.search(query, limit: 8)
            let patients = query.isEmpty
                ? Array(try await store.patients.loadAll(includeArchived: false).prefix(4))
                : try await store.patients.search(query, limit: 5)
            var hits: [SwitcherHit] = notes.map {
                SwitcherHit(id: $0.id, kind: .note, title: DisplayCopy.title($0.title), subtitle: String(localized: "Note"))
            }
            hits.append(contentsOf: patients.map {
                SwitcherHit(id: $0.id, kind: .patient, title: DisplayCopy.patient($0), subtitle: String(localized: "Patient"))
            })
            if !query.isEmpty {
                let lowered = query.lowercased()
                // The whole store, not `self.todos`/`self.events`: those hold
                // what the module's current filter shows, so a past event or a
                // completed todo would never be found from here.
                let todos = try await store.todos.loadAll(includeCompleted: true).filter {
                    $0.title.lowercased().contains(lowered)
                }.prefix(3)
                hits.append(contentsOf: todos.map {
                    SwitcherHit(id: $0.id, kind: .todo, title: DisplayCopy.title($0.title), subtitle: String(localized: "Todo"))
                })
                let events = try await store.events.loadAll().filter {
                    $0.title.lowercased().contains(lowered)
                }.prefix(3)
                hits.append(contentsOf: events.map {
                    SwitcherHit(id: $0.id, kind: .event, title: DisplayCopy.title($0.title), subtitle: String(localized: "Event"))
                })
            }
            // A cancellation only stops the debounce sleep. A lookup that was
            // already running finishes after the newer one started; its
            // results must not overwrite the query the user is typing now.
            guard generation == switcherGeneration else { return }
            switcherResults = Array(hits.prefix(12))
        } catch {
            guard generation == switcherGeneration else { return }
            switcherResults = []
        }
    }

    func open(_ hit: SwitcherHit) async {
        showSwitcher = false
        switch hit.kind {
        case .note:
            await revealNote(hit.id)
        case .patient:
            await revealPatient(hit.id)
        case .todo:
            await revealTodo(hit.id)
        case .event:
            await revealEvent(hit.id)
        }
    }

    /// Selects a record and makes sure its list column will show it. Quick
    /// Open and the graph can reach records the current search or filter
    /// hides — a past event while the list says Upcoming, an archived
    /// patient, a completed todo under the Pending filter — and selecting one
    /// without revealing it left the detail pane open on a row the list did
    /// not contain.
    private func revealNote(_ id: UUID) async {
        if !searchText.isEmpty {
            searchText = ""
            searchTask?.cancel()
        }
        await reload()
        selectedModule = .notes
        selectedNoteId = id
        noteEpoch += 1
    }

    private func revealPatient(_ id: UUID) async {
        let archived = (try? await store?.patients.load(id: id))?.isArchived ?? false
        let filter: PatientFilter = archived ? .archived : .active
        if patientFilter != filter { patientFilter = filter }
        if !patientSearchText.isEmpty {
            patientSearchText = ""
            patientSearchTask?.cancel()
        }
        await reloadPatients()
        selectedModule = .patients
        selectedPatientId = id
        patientEpoch += 1
    }

    private func revealTodo(_ id: UUID) async {
        if todoFilter != .all { todoFilter = .all }
        if !todoSearchText.isEmpty {
            todoSearchText = ""
            todoSearchTask?.cancel()
        }
        await reloadTodos()
        selectedModule = .todos
        selectedTodoId = id
        todoEpoch += 1
    }

    private func revealEvent(_ id: UUID) async {
        if eventFilter != .all { eventFilter = .all }
        if !eventSearchText.isEmpty {
            eventSearchText = ""
            eventSearchTask?.cancel()
        }
        await reloadEvents()
        selectedModule = .calendar
        selectedEventId = id
        eventEpoch += 1
    }

    // MARK: - Wiki-links & graph data

    struct LinkCandidate: Identifiable, Hashable {
        enum Kind: Hashable {
            case note
            case patient
        }
        let id: UUID
        let title: String
        let kind: Kind
    }

    /// Completions for an open `[[` anchor, over the whole store rather than
    /// the list column's current load: notes whose title starts with the
    /// text, then titles containing it, then bodies mentioning it, then
    /// patients by name. An empty anchor offers the notes touched most
    /// recently; one character is too little to ask.
    func linkCandidates(anchor: String, excluding noteId: UUID?) async -> [LinkCandidate] {
        guard let store else { return [] }
        let query = anchor.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if query.isEmpty {
                return try await store.notes.loadAll()
                    .filter { $0.id != noteId }
                    .prefix(6)
                    .map { LinkCandidate(id: $0.id, title: DisplayCopy.title($0.title), kind: .note) }
            }
            guard query.count >= 2 else { return [] }
            let lowered = query.lowercased()
            let notes = try await store.notes.search(query, limit: 12).filter { $0.id != noteId }
            let ranked = notes.enumerated()
                .sorted { lhs, rhs in
                    let l = Self.linkRank(title: lhs.element.title, query: lowered)
                    let r = Self.linkRank(title: rhs.element.title, query: lowered)
                    return l == r ? lhs.offset < rhs.offset : l < r
                }
                .map(\.element)
            var out = ranked.prefix(4).map {
                LinkCandidate(id: $0.id, title: DisplayCopy.title($0.title), kind: .note)
            }
            let patients = try await store.patients.search(query, limit: 5)
            out += patients.prefix(3).map {
                LinkCandidate(id: $0.id, title: DisplayCopy.patient($0), kind: .patient)
            }
            return Array(out.prefix(6))
        } catch {
            return []
        }
    }

    /// 0 = the title starts with the text, 1 = contains it, 2 = body only.
    private static func linkRank(title: String, query: String) -> Int {
        let lowered = title.lowercased()
        if lowered.hasPrefix(query) { return 0 }
        if lowered.contains(query) { return 1 }
        return 2
    }

    func refreshLinks(noteId: UUID) async {
        guard let store else { return }
        do {
            backlinks = try await store.linking.backlinks(noteId: noteId)
            linksOut = try await store.linking.linksFrom(noteId: noteId)
        } catch {
            backlinks = []
            linksOut = []
        }
    }

    func jumpToNote(_ noteId: UUID) async {
        await revealNote(noteId)
    }

    func loadGraph() async {
        guard let store else { return }
        do {
            graphData = try await store.linking.graph()
        } catch {
            graphData = LinkingService.GraphData()
        }
    }

    func jumpToGraphNode(_ node: LinkingService.GraphNode) async {
        // Node ids are "<kind>:<uuid>" — drop the prefix *and* the separator.
        let raw = String(node.id.dropFirst(2))
        switch node.id.first {
        case "n":
            guard let uuid = UUID(uuidString: raw) else { return }
            await revealNote(uuid)
        case "p":
            guard let uuid = UUID(uuidString: raw) else { return }
            await revealPatient(uuid)
        case "e":
            guard let uuid = UUID(uuidString: raw) else { return }
            await revealEvent(uuid)
        default:
            break
        }
    }

    // MARK: - Templates

    /// Bumped by every change made in Settings › Templates, so an open note's
    /// insert menu reloads rather than offering yesterday's copy.
    @Published private(set) var templateEpoch = 0

    func templatesForMenu() async -> [NoteTemplate] {
        guard let store else { return TemplateService.builtIns.map(\.displayed) }
        return (try? await store.templates.allTemplates()) ?? TemplateService.builtIns.map(\.displayed)
    }

    struct StoreNotOpenError: LocalizedError {
        var errorDescription: String? { String(localized: "The store is not open.") }
    }

    private func openStore() throws -> AppStore {
        guard let store else { throw StoreNotOpenError() }
        return store
    }

    func loadTemplates() async throws -> [NoteTemplate] {
        try await openStore().templates.allTemplates()
    }

    func saveTemplate(_ template: NoteTemplate) async throws {
        try await openStore().templates.save(template)
        templateEpoch += 1
    }

    /// Stores a fresh custom template so the editor has a row to work on;
    /// `discardTemplateIfUntouched` takes it back if nothing is typed.
    func newTemplate() async throws -> NoteTemplate {
        let template = NoteTemplate.newRecord()
        try await openStore().templates.save(template)
        templateEpoch += 1
        return template
    }

    func deleteTemplate(id: String) async throws {
        try await openStore().templates.delete(id: id)
        if defaultNoteTemplateID == id { defaultNoteTemplateID = nil }
        templateEpoch += 1
    }

    func resetTemplate(id: String) async throws -> NoteTemplate {
        let shipped = try await openStore().templates.reset(id: id)
        templateEpoch += 1
        return shipped
    }

    /// Silent by design, like the record editors' discard: an abandoned "+"
    /// leaves no row behind, and a failure to remove one is not worth an alert.
    func discardTemplateIfUntouched(_ template: NoteTemplate) async {
        guard template.isUntouchedNewRecord, let store else { return }
        if (try? await store.templates.delete(id: template.id)) != nil {
            templateEpoch += 1
        }
    }

    private static func matchesSearchTokens(_ query: String, fields: [String]) -> Bool {
        let tokens = Schema.splitTokens(query)
        guard !tokens.isEmpty else { return false }
        let lowered = fields.map { $0.lowercased() }
        return tokens.allSatisfy { token in
            let t = token.lowercased()
            return lowered.contains { $0.contains(t) }
        }
    }

    func patientName(for id: UUID) -> String? {
        patientDirectory.first(where: { $0.id == id }).map { DisplayCopy.patient($0) }
    }

    func sidebarCount(for module: AppModule) -> Int {
        switch module {
        case .notes: return sidebarNoteCount
        case .patients: return sidebarPatientCount
        case .todos: return sidebarPendingTodoCount
        case .calendar: return sidebarUpcomingEventCount
        case .graph: return 0
        }
    }

    /// The record `newPatient()`, `newTodo()` or `newEvent()` just created,
    /// until its editor has opened. The detail view consumes this to drop the
    /// keyboard into the first field once — only for a record the user asked
    /// for, never when they are merely arrowing through a list. Ids are
    /// unique across kinds, so one slot serves all three.
    private(set) var pendingFocusRecordId: UUID?

    func consumeFocusRequest(for recordId: UUID) -> Bool {
        guard pendingFocusRecordId == recordId else { return false }
        pendingFocusRecordId = nil
        return true
    }

    /// Graph has no records of its own, so ⌘N has nothing to create there.
    var canCreateInCurrentModule: Bool { selectedModule != .graph }

    func createInCurrentModule() async {
        switch selectedModule {
        case .notes: await newNote()
        case .patients: await newPatient()
        case .todos: await newTodo()
        case .calendar: await newEvent()
        case .graph: break
        }
    }

    var canDeleteSelection: Bool {
        switch selectedModule {
        case .notes: return selectedNoteId != nil
        case .patients: return selectedPatientId != nil
        case .todos: return selectedTodoId != nil
        case .calendar: return selectedEventId != nil
        case .graph: return false
        }
    }

    private func selectedId(in module: AppModule) -> UUID? {
        switch module {
        case .notes: return selectedNoteId
        case .patients: return selectedPatientId
        case .todos: return selectedTodoId
        case .calendar: return selectedEventId
        case .graph: return nil
        }
    }

    var pendingDeletionArchives: Bool {
        let module = pendingDeletion?.module ?? selectedModule
        guard module == .patients else { return false }
        return !(pendingDeletion?.isPermanent ?? (patientFilter == .archived))
    }

    var pendingDeleteTitle: String {
        if pendingDeletionArchives {
            return String(localized: "Archive this patient?")
        }
        return (pendingDeletion?.module ?? selectedModule).deleteConfirmTitle
    }

    var pendingDeleteMessage: String {
        if pendingDeletionArchives {
            return String(localized: "Notes, todos and appointments stay linked, and the record can be restored from the Archived list.")
        }
        return String(localized: "This cannot be undone.")
    }

    /// Whether Edit › Delete may ask about the selected record now: not while
    /// a sheet, an alert, the quick switcher, the privacy curtain or the
    /// confirmation itself covers the main window. The dialog would queue
    /// behind the sheet, or ask over a record nobody can see.
    var canRequestDelete: Bool {
        canDeleteSelection && !confirmDelete
            && backupFlow == nil && importFlow == nil && destinationFlow == nil
            && errorMessage == nil && notice == nil
            && !showSwitcher && !showsPrivacyCurtain
    }

    func requestDelete() {
        guard canRequestDelete else { return }
        guard let id = selectedId(in: selectedModule) else { return }
        // Snapshot the target now so the confirmation dialog deletes exactly
        // what it described, even if the module or selection changes while the
        // dialog is up.
        pendingDeletion = PendingDeletion(
            module: selectedModule, id: id,
            isPermanent: selectedModule != .patients || patientFilter == .archived)
        confirmDelete = true
    }

    /// Deletes the entity captured in `pendingDeletion` (the module + id
    /// snapshotted when the confirmation was requested — not necessarily the
    /// current module's selection). No-op when no snapshot is pending.
    func deleteInCurrentModule() async {
        defer { pendingDeletion = nil }
        guard let target = pendingDeletion else { return }
        switch target.module {
        case .notes: await deleteNote(id: target.id)
        case .patients:
            if target.isPermanent {
                await deletePatient(id: target.id)
            } else {
                await archivePatient(id: target.id)
            }
        case .todos: await deleteTodo(id: target.id)
        case .calendar: await deleteEvent(id: target.id)
        case .graph: break
        }
    }

    var canPinSelection: Bool {
        // Require the note to be resolvable in the current list so the Pin
        // command can't show a stale title or silently no-op when a search
        // excludes the selected note.
        guard selectedModule == .notes, let id = selectedNoteId else { return false }
        return notes.contains(where: { $0.id == id })
    }

    var selectedNoteIsPinned: Bool {
        guard let id = selectedNoteId else { return false }
        return notes.first(where: { $0.id == id })?.isPinned == true
    }

    func pinSelectedNote() async {
        guard let id = selectedNoteId,
              let note = notes.first(where: { $0.id == id }) else { return }
        _ = await togglePin(note)
    }

    var canToggleSelectedTodo: Bool {
        selectedModule == .todos && selectedTodoId != nil
    }

    func toggleSelectedTodo() async {
        guard let id = selectedTodoId else { return }
        await toggleTodo(id: id)
    }

    func dismissError() {
        errorMessage = nil
    }
}
