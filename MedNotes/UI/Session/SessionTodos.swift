import Combine
import SwiftUI
import UniformTypeIdentifiers

/// The todo list: loading, search, creating, saving, completing and deleting.
extension AppSession {
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

    func scheduleTodoSearch() {
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
    func normalizedForSave(_ todo: TodoItem) -> TodoItem {
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
        do {
            if let snapshot = try await store.todos.load(id: id), snapshot.reminderIdentifier != nil {
                guard appleReminders.state == .granted,
                      let destination = try await store.destinations.destination(for: .reminders),
                      SyncDestinationCore.mayWrite(destination) else {
                    throw LinkedDeletionError.reminders
                }
                try await appleReminders.deleteRemote(snapshot, from: destination)
            }
            if discarding {
                try await store.todos.discard(id: id)
            } else {
                try await store.todos.delete(id: id)
            }
            if selectedTodoId == id { selectedTodoId = nil }
            todoEpoch += 1
            await reloadTodos()
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
}
