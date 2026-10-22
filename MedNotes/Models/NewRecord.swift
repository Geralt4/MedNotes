import Foundation

// MARK: - New-record templates
//
// The four creators in `AppSession` save a record before the user has typed
// anything, so the editor has something to edit in place. If the user then
// leaves without touching it, the editor discards it rather than leave an
// "Unnamed Patient" or "New Todo" row behind. The template and the test for
// "still the template" live together here so they cannot drift apart.
//
// `isUntouchedNewRecord` ignores identity, store-stamped timestamps and sync
// bookkeeping, and nothing else: a record the user typed into and cleared again
// still qualifies, because discarding it loses nothing.

extension Patient {
    static func newRecord(now: Date = Date()) -> Patient {
        // Epoch-0 is the missing-DOB sentinel (hasKnownDateOfBirth == false),
        // so a new patient shows "Unknown" instead of a fabricated age.
        Patient(profile: PatientProfile(dateOfBirth: Date(timeIntervalSince1970: 0)),
                createdAt: now, lastModified: now)
    }

    var isUntouchedNewRecord: Bool {
        var template = Patient.newRecord(now: createdAt)
        template.id = id
        template.lastModified = lastModified   // stamped by every save
        return self == template
    }
}

extension Note {
    static func newRecord(now: Date = Date()) -> Note {
        Note(title: String(localized: "New Note"), content: "", createdAt: now, updatedAt: now)
    }

    var isUntouchedNewRecord: Bool {
        isUntouchedNewRecord(seededContent: nil)
    }

    /// A note born from a default template (Settings › Templates) is still
    /// untouched while its body is exactly what was seeded into it; the
    /// session remembers that text for as long as it matters.
    func isUntouchedNewRecord(seededContent: String?) -> Bool {
        var template = Note.newRecord(now: createdAt)
        template.id = id
        template.updatedAt = updatedAt   // stamped by every save
        template.content = seededContent ?? ""
        return self == template
    }
}

extension TodoItem {
    static func newRecord(now: Date = Date()) -> TodoItem {
        TodoItem(title: String(localized: "New Todo"), createdAt: now)
    }

    var isUntouchedNewRecord: Bool {
        var template = TodoItem.newRecord(now: createdAt)
        template.id = id
        template.updatedAt = updatedAt   // stamped by every save
        // Apple Reminders sync bookkeeping is not a user edit.
        template.reminderIdentifier = reminderIdentifier
        template.reminderListIdentifier = reminderListIdentifier
        template.syncStatus = syncStatus
        template.lastSyncDate = lastSyncDate
        return self == template
    }
}

extension CalendarEvent {
    static let newRecordDuration: TimeInterval = 30 * 60

    static func newRecord(now: Date = Date()) -> CalendarEvent {
        // One `now` for the schedule and the creation stamp, so the template
        // can be rebuilt from `createdAt` alone.
        CalendarEvent(title: String(localized: "New Event"),
                      startDate: now, endDate: now.addingTimeInterval(newRecordDuration),
                      createdAt: now, updatedAt: now)
    }

    var isUntouchedNewRecord: Bool {
        var template = CalendarEvent.newRecord(now: createdAt)
        template.id = id
        template.updatedAt = updatedAt   // stamped by every save
        // Apple Calendar sync bookkeeping is not a user edit.
        template.ekEventIdentifier = ekEventIdentifier
        template.syncStatus = syncStatus
        template.lastSyncDate = lastSyncDate
        // The store keeps milliseconds; allow that much slack on the schedule
        // instead of demanding bit-equality with what `Date()` produced.
        if startDate.isWithinStoragePrecision(of: template.startDate) { template.startDate = startDate }
        if endDate.isWithinStoragePrecision(of: template.endDate) { template.endDate = endDate }
        return self == template
    }
}

private extension Date {
    func isWithinStoragePrecision(of other: Date) -> Bool {
        abs(timeIntervalSince(other)) < 0.01
    }
}
