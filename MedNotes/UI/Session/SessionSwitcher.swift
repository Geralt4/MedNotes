import Combine
import SwiftUI
import UniformTypeIdentifiers

/// The quick switcher (⌘O) and the reveal helpers that open a record in its module.
extension AppSession {
    // MARK: - Quick switcher

    func scheduleSwitcherSearch() {
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
                // Compared folded (case, accents, final sigma), as the notes and
                // patients above are by the full-text index.
                let lowered = WikiLinkParser.normalizedKey(query)
                // The whole store, not `self.todos`/`self.events`: those hold
                // what the module's current filter shows, so a past event or a
                // completed todo would never be found from here.
                let todos = try await store.todos.loadAll(includeCompleted: true).filter {
                    WikiLinkParser.normalizedKey($0.title).contains(lowered)
                }.prefix(3)
                hits.append(contentsOf: todos.map {
                    SwitcherHit(id: $0.id, kind: .todo, title: DisplayCopy.title($0.title), subtitle: String(localized: "Todo"))
                })
                let events = try await store.events.loadAll().filter {
                    WikiLinkParser.normalizedKey($0.title).contains(lowered)
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
    func revealNote(_ id: UUID) async {
        if !searchText.isEmpty {
            searchText = ""
            searchTask?.cancel()
        }
        await reload()
        selectedModule = .notes
        selectedNoteId = id
        noteEpoch += 1
    }

    func revealPatient(_ id: UUID) async {
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

    func revealEvent(_ id: UUID) async {
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
}
