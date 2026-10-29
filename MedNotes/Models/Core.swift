import Foundation

struct Note: Codable, Hashable, Sendable, Identifiable {
    var id: UUID
    var title: String
    var content: String
    var createdAt: Date
    var updatedAt: Date
    var tags: [String]
    var mentionedPatients: [UUID]
    var isPinned: Bool

    var wordCount: Int {
        content.split(whereSeparator: \.isWhitespace).count
    }

    var isMedicalNote: Bool {
        !mentionedPatients.isEmpty || tags.contains { $0.lowercased().contains("medical") }
    }

    init(id: UUID = UUID(), title: String = "", content: String = "", createdAt: Date = Date(),
         updatedAt: Date = Date(), tags: [String] = [], mentionedPatients: [UUID] = [],
         isPinned: Bool = false) {
        self.id = id
        self.title = title
        self.content = content
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.tags = tags
        self.mentionedPatients = mentionedPatients
        self.isPinned = isPinned
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = decodeLossyString(c, forKey: .title) ?? ""
        content = decodeLossyString(c, forKey: .content) ?? ""
        createdAt = (try? c.decodeIfPresent(Date.self, forKey: .createdAt)) ?? Date()
        updatedAt = (try? c.decodeIfPresent(Date.self, forKey: .updatedAt)) ?? createdAt
        var seen = Set<String>()
        tags = decodeLossyStrings(c, forKey: .tags).filter { seen.insert($0).inserted }
        mentionedPatients = decodeLossyUUIDs(c, forKey: .mentionedPatients)
        isPinned = decodeLossyBool(c, forKey: .isPinned) ?? false
    }
}

enum TodoPriority: String, LenientEnum, CaseIterable, Hashable {
    case high = "High"
    case medium = "Medium"
    case low = "Low"
    static let fallback: TodoPriority = .medium
}

enum SyncStatus: String, LenientEnum, CaseIterable, Hashable {
    case localOnly = "Local Only"
    case synced = "Synced"
    case syncPending = "Sync Pending"
    case syncFailed = "Sync Failed"
    static let fallback: SyncStatus = .localOnly

    static func parse(_ raw: String) -> SyncStatus {
        if let exact = Self(rawValue: raw) { return exact }
        switch Self.normalize(raw) {
        case "localonly": return .localOnly
        case "synced": return .synced
        case "syncpending": return .syncPending
        case "syncfailed": return .syncFailed
        default: return fallback
        }
    }

    var sqlValue: String {
        switch self {
        case .localOnly: return "localOnly"
        case .synced: return "synced"
        case .syncPending: return "syncPending"
        case .syncFailed: return "syncFailed"
        }
    }

    static func fromSQL(_ raw: String?) -> SyncStatus {
        guard let raw else { return .localOnly }
        return parse(raw)
    }
}

struct TodoItem: Codable, Hashable, Sendable, Identifiable {
    var id: UUID
    var title: String
    var isCompleted: Bool
    var createdAt: Date
    /// Stamped by every user-driven save and toggle. The Apple Reminders
    /// bridge compares it with `lastSyncDate` to tell a local edit from a row
    /// that merely round-tripped, exactly as `CalendarEvent.updatedAt` does
    /// for the calendar bridge.
    var updatedAt: Date
    var completedAt: Date?
    var priority: TodoPriority
    var dueDate: Date?
    var notes: String?
    var patientName: String?
    var patientId: UUID?
    var tags: [String]
    var reminderIdentifier: String?
    var reminderListIdentifier: String?
    var syncStatus: SyncStatus
    var lastSyncDate: Date?

    init(id: UUID = UUID(), title: String = "", isCompleted: Bool = false,
         createdAt: Date = Date(), updatedAt: Date? = nil, completedAt: Date? = nil,
         priority: TodoPriority = .medium,
         dueDate: Date? = nil, notes: String? = nil, patientName: String? = nil,
         patientId: UUID? = nil, tags: [String] = [], reminderIdentifier: String? = nil,
         reminderListIdentifier: String? = nil, syncStatus: SyncStatus = .localOnly,
         lastSyncDate: Date? = nil) {
        self.id = id
        self.title = title
        self.isCompleted = isCompleted
        self.createdAt = createdAt
        // A record that was never edited was last "modified" when it was made.
        self.updatedAt = updatedAt ?? createdAt
        self.completedAt = completedAt
        self.priority = priority
        self.dueDate = dueDate
        self.notes = notes
        self.patientName = patientName
        self.patientId = patientId
        self.tags = tags
        self.reminderIdentifier = reminderIdentifier
        self.reminderListIdentifier = reminderListIdentifier
        self.syncStatus = syncStatus
        self.lastSyncDate = lastSyncDate
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = decodeLossyString(c, forKey: .title) ?? ""
        isCompleted = decodeLossyBool(c, forKey: .isCompleted) ?? false
        createdAt = (try? c.decodeIfPresent(Date.self, forKey: .createdAt)) ?? Date()
        updatedAt = (try? c.decodeIfPresent(Date.self, forKey: .updatedAt)) ?? createdAt
        completedAt = try? c.decodeIfPresent(Date.self, forKey: .completedAt)
        if !isCompleted {
            completedAt = nil
        }
        priority = (try? c.decodeIfPresent(TodoPriority.self, forKey: .priority)) ?? .medium
        dueDate = try? c.decodeIfPresent(Date.self, forKey: .dueDate)
        notes = decodeLossyString(c, forKey: .notes)
        patientName = decodeLossyString(c, forKey: .patientName)
        patientId = decodeLossyUUID(c, forKey: .patientId)
        var seen = Set<String>()
        tags = decodeLossyStrings(c, forKey: .tags).filter { seen.insert($0).inserted }
        reminderIdentifier = decodeLossyString(c, forKey: .reminderIdentifier)
        reminderListIdentifier = decodeLossyString(c, forKey: .reminderListIdentifier)
        syncStatus = (try? c.decodeIfPresent(SyncStatus.self, forKey: .syncStatus)) ?? .localOnly
        lastSyncDate = try? c.decodeIfPresent(Date.self, forKey: .lastSyncDate)
    }
}

extension TodoItem {
    static func startOfToday() -> Date {
        Calendar.current.startOfDay(for: Date())
    }

    var isOverdue: Bool {
        guard let d = dueDate, !isCompleted else { return false }
        return d < Self.startOfToday()
    }

    var isDueToday: Bool {
        guard let d = dueDate, !isCompleted else { return false }
        return Calendar.current.isDate(d, inSameDayAs: Date())
    }
}

enum EventType: String, LenientEnum, CaseIterable, Hashable {
    case appointment = "Appointment"
    case medicationChange = "Medication Change"
    case labResult = "Lab Result"
    case surgery = "Surgery"
    case checkup = "Checkup"
    case consultation = "Consultation"
    case vaccine = "Vaccine"
    case observation = "Observation"
    case customEvent = "Custom Event"
    static let fallback: EventType = .customEvent
}

struct CalendarEvent: Codable, Hashable, Sendable, Identifiable {
    var id: UUID
    var title: String
    var description: String
    var startDate: Date
    var endDate: Date
    var isAllDay: Bool
    var patientId: UUID?
    var eventType: EventType
    var createdAt: Date
    var updatedAt: Date
    /// Apple Calendar linkage. `ekEventIdentifier` stores the EKEvent's
    /// `calendarItemIdentifier`; nil means the event has never been pushed.
    var ekEventIdentifier: String?
    var syncStatus: SyncStatus
    var lastSyncDate: Date?

    init(id: UUID = UUID(), title: String = "", description: String = "",
         startDate: Date = Date(), endDate: Date = Date().addingTimeInterval(1800),
         isAllDay: Bool = false, patientId: UUID? = nil, eventType: EventType = .appointment,
         createdAt: Date = Date(), updatedAt: Date = Date(),
         ekEventIdentifier: String? = nil, syncStatus: SyncStatus = .localOnly,
         lastSyncDate: Date? = nil) {
        self.id = id
        self.title = title
        self.description = description
        self.startDate = startDate
        self.endDate = endDate
        self.isAllDay = isAllDay
        self.patientId = patientId
        self.eventType = eventType
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.ekEventIdentifier = ekEventIdentifier
        self.syncStatus = syncStatus
        self.lastSyncDate = lastSyncDate
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = decodeLossyString(c, forKey: .title) ?? ""
        description = decodeLossyString(c, forKey: .description) ?? ""
        isAllDay = decodeLossyBool(c, forKey: .isAllDay) ?? false
        startDate = (try? c.decodeIfPresent(Date.self, forKey: .startDate)) ?? Date()
        endDate = (try? c.decodeIfPresent(Date.self, forKey: .endDate))
            ?? (isAllDay ? startDate : startDate.addingTimeInterval(1800))
        patientId = decodeLossyUUID(c, forKey: .patientId)
        eventType = (try? c.decodeIfPresent(EventType.self, forKey: .eventType)) ?? .appointment
        createdAt = (try? c.decodeIfPresent(Date.self, forKey: .createdAt)) ?? Date()
        updatedAt = (try? c.decodeIfPresent(Date.self, forKey: .updatedAt)) ?? createdAt
        ekEventIdentifier = decodeLossyString(c, forKey: .ekEventIdentifier)
        syncStatus = (try? c.decodeIfPresent(SyncStatus.self, forKey: .syncStatus)) ?? .localOnly
        lastSyncDate = try? c.decodeIfPresent(Date.self, forKey: .lastSyncDate)
        ensureEndNotBeforeStart()
    }

    mutating func setAllDay(_ allDay: Bool, calendar: Calendar = .current) {
        isAllDay = allDay
        if allDay {
            let originalStart = startDate
            let originalEnd = endDate
            startDate = calendar.startOfDay(for: originalStart)
            if calendar.isDate(originalStart, inSameDayAs: originalEnd)
                || originalEnd.timeIntervalSince(originalStart) < 24 * 3600 {
                endDate = startDate
            } else {
                endDate = calendar.startOfDay(for: originalEnd)
                if endDate < startDate { endDate = startDate }
            }
        } else if endDate <= startDate {
            endDate = startDate.addingTimeInterval(1800)
        }
    }

    mutating func ensureEndNotBeforeStart() {
        if endDate < startDate {
            endDate = isAllDay ? startDate : startDate.addingTimeInterval(1800)
        }
    }

    var isUpcoming: Bool {
        let cal = Calendar.current
        if isAllDay {
            return cal.startOfDay(for: endDate) >= cal.startOfDay(for: Date())
        }
        return endDate >= Date()
    }
}

struct AuditLogEntry: Codable, Hashable, Sendable, Identifiable {
    var id: UUID
    var timestamp: Date
    var userId: String
    var action: String
    var entityType: String
    var entityId: String
    var details: String

    init(id: UUID = UUID(), timestamp: Date = Date(), userId: String = "system",
         action: String, entityType: String, entityId: String, details: String = "") {
        self.id = id
        self.timestamp = timestamp
        self.userId = userId
        self.action = action
        self.entityType = entityType
        self.entityId = entityId
        self.details = details
    }
}

struct ImportReport: Codable, Sendable, Hashable {
    var patientsImported: Int
    var notesImported: Int
    var todosImported: Int
    var eventsImported: Int
    var filesSkipped: Int
    var warnings: [String]
    var errors: [String]
    /// Records in the folder that the store already holds (the same id, or a
    /// patient's AMKA). They are left exactly as they are, not overwritten.
    var patientsAlreadyPresent: Int
    var notesAlreadyPresent: Int
    var todosAlreadyPresent: Int
    var eventsAlreadyPresent: Int

    var totalImported: Int {
        patientsImported + notesImported + todosImported + eventsImported
    }

    var totalAlreadyPresent: Int {
        patientsAlreadyPresent + notesAlreadyPresent + todosAlreadyPresent + eventsAlreadyPresent
    }

    init(patientsImported: Int = 0, notesImported: Int = 0, todosImported: Int = 0,
         eventsImported: Int = 0, filesSkipped: Int = 0, warnings: [String] = [],
         errors: [String] = [], patientsAlreadyPresent: Int = 0, notesAlreadyPresent: Int = 0,
         todosAlreadyPresent: Int = 0, eventsAlreadyPresent: Int = 0) {
        self.patientsAlreadyPresent = patientsAlreadyPresent
        self.notesAlreadyPresent = notesAlreadyPresent
        self.todosAlreadyPresent = todosAlreadyPresent
        self.eventsAlreadyPresent = eventsAlreadyPresent
        self.patientsImported = patientsImported
        self.notesImported = notesImported
        self.todosImported = todosImported
        self.eventsImported = eventsImported
        self.filesSkipped = filesSkipped
        self.warnings = warnings
        self.errors = errors
    }
}

extension TodoItem {
    /// Takes the fields only the Apple Reminders bridge changes from the stored
    /// row. An editor holding a copy read earlier must do this when the store
    /// changes under it: saving the stale link fields would unlink the synced
    /// reminder, and the next pass would import it again as a duplicate.
    mutating func adoptSyncState(from stored: TodoItem) {
        reminderIdentifier = stored.reminderIdentifier
        reminderListIdentifier = stored.reminderListIdentifier
        syncStatus = stored.syncStatus
        lastSyncDate = stored.lastSyncDate
    }
}

extension CalendarEvent {
    /// As `TodoItem.adoptSyncState(from:)`, for the Apple Calendar bridge.
    mutating func adoptSyncState(from stored: CalendarEvent) {
        ekEventIdentifier = stored.ekEventIdentifier
        syncStatus = stored.syncStatus
        lastSyncDate = stored.lastSyncDate
    }
}
