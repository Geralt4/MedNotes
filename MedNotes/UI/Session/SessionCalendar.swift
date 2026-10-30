import Combine
import SwiftUI
import UniformTypeIdentifiers

/// The calendar: loading, search, creating, saving and deleting events.
extension AppSession {
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

    func scheduleEventSearch() {
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
            // As in `newPatient`: a lock during the save leaves nothing to select.
            guard canUseStore, self.store === store else { return }
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
        do {
            if let snapshot = try await store.events.load(id: id) {
                // A lookup that fails must not stop an unlinked row being deleted.
                let destination = try? await store.destinations.destination(for: .calendar)
                let canReach = appleCalendar.state == .granted && SyncDestinationCore.mayWrite(destination)
                if snapshot.ekEventIdentifier != nil {
                    // Linked: the delete waits until the Apple copy can be removed.
                    guard canReach, let destination else { throw LinkedDeletionError.calendar }
                    try await appleCalendar.deleteRemote(snapshot, from: destination)
                } else if canReach, let destination, !snapshot.isUntouchedNewRecord {
                    // No identifier stored (a push's result was never saved), but
                    // an Apple copy may exist under its marker. Best effort: the
                    // tombstone written by the delete keeps it from coming back
                    // either way, and a delete that works today must still work.
                    // An untouched placeholder is never pushed, so it has no copy
                    // to look for.
                    try? await appleCalendar.deleteRemote(snapshot, from: destination)
                }
            }
            if discarding {
                try await store.events.discard(id: id)
            } else {
                try await store.events.delete(id: id)
            }
            if selectedEventId == id { selectedEventId = nil }
            eventEpoch += 1
            await reloadEvents()
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
}
