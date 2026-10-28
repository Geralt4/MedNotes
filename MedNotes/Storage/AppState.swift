import Foundation

/// Small named values the app keeps in the encrypted store (`app_state`):
/// settings that may hold a patient's name, such as a graph filter.
/// Not derived from the notes, so nothing here is rebuilt.
extension Database {
    /// Longest value kept, so a damaged or hostile row cannot grow the store.
    static let appStateLimit = 64 * 1024

    func appState(key: String) throws -> String? {
        let s = try conn.prepare("SELECT value_json FROM app_state WHERE key = ?")
        defer { s.finalize() }
        s.bind(1, key)
        return try s.step() ? s.columnText(0) : nil
    }

    func setAppState(key: String, json: String) throws {
        guard !key.isEmpty, key.utf8.count <= 128, json.utf8.count <= Self.appStateLimit else {
            throw SQLiteError.exec("app state key or value out of range", sql: "INSERT INTO app_state")
        }
        let s = try conn.prepare("""
            INSERT INTO app_state(key, value_json, updated_at) VALUES (?, ?, ?)
            ON CONFLICT(key) DO UPDATE SET value_json = excluded.value_json, updated_at = excluded.updated_at
            """)
        defer { s.finalize() }
        s.bind(1, key)
        s.bind(2, json)
        s.bind(3, ISO8601DateFormatter().string(from: Date()))
        _ = try s.step()
    }

    func removeAppState(key: String) throws {
        let s = try conn.prepare("DELETE FROM app_state WHERE key = ?")
        defer { s.finalize() }
        s.bind(1, key)
        _ = try s.step()
    }
}
