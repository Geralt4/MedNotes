import Combine
import SwiftUI
import UniformTypeIdentifiers

/// Apple Calendar and Reminders: the destination wizard, sync state, and the two bridges.
extension AppSession {
    // MARK: - Destination wizard

    /// Presented after permission when a bridge has no confirmed destination
    /// or its destination went stale.
    struct DestinationFlow: Identifiable {
        let bridge: SyncBridgeType
        let wizard: SyncDestinationWizard
        var id: String { bridge.rawValue }
    }

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

    /// Observes the Apple Calendar bridge for external changes and triggers
    /// an automatic pull when EventKit reports modifications.
    ///
    /// The flag's current value counts: EventKit keeps reporting while the
    /// store is locked, and a change made in Calendar meanwhile is pulled by
    /// the pass this starts on unlock (through the usual automatic gates).
    /// The `false` that a pass publishes when it consumes the flag is not a
    /// change and starts nothing.
    func observeCalendarChanges() {
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
    func observeRemindersChanges() {
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
    func startBridgeObservation() {
        if !PreviewSeed.isActive {
            appleCalendar.startObservingChanges()
            appleReminders.startObservingChanges()
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
    func pushQuietly(_ event: CalendarEvent) async {
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
    func pushTodoQuietly(_ todo: TodoItem) async {
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
}
