import Combine
import SwiftUI
import UniformTypeIdentifiers

/// The patients list: loading, search, creating, saving, archiving and deleting.
extension AppSession {
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

    func schedulePatientSearch() {
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

    func reloadPatientDirectory() async {
        guard let store else { return }
        do {
            patientDirectory = try await store.patients.loadAll(includeArchived: true)
            sidebarPatientCount = patientDirectory.filter { !$0.isArchived }.count
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
