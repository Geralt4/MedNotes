import Foundation
#if canImport(SQLCipher)
import SQLCipher
#else
import SQLite3
#endif
enum SQLiteError: Error, CustomStringConvertible, LocalizedError, Equatable {
    case open(String)
    case prepare(String, sql: String)
    case step(String, sql: String)
    case exec(String, sql: String)
    case keyingFailed(String)
    case wrongKey
    case plaintextDatabase(String)
    case invalidRawKey

    var description: String {
        switch self {
        case let .open(msg): return "SQLite open failed: \(msg)"
        case let .prepare(msg, sql): return "SQLite prepare failed: \(msg) [\(sql)]"
        case let .step(msg, sql): return "SQLite step failed: \(msg) [\(sql)]"
        case let .exec(msg, sql): return "SQLite exec failed: \(msg) [\(sql)]"
        case let .keyingFailed(msg): return "SQLCipher keying failed: \(msg)"
        case .wrongKey: return "The database key is wrong or the file is not an encrypted MedNotes store."
        case let .plaintextDatabase(path): return "Refusing to open a plaintext database in encrypted mode: \(path)"
        case .invalidRawKey: return "The database key must be 64 hex characters (a 256-bit raw key)."
        }
    }

    /// What the app shows. `description` stays English for the CLI and logs.
    /// This text never carries the SQL, which for `PRAGMA key` and `rekey`
    /// holds the raw key.
    var errorDescription: String? {
        switch self {
        case let .step(msg, _) where msg.hasPrefix("UNIQUE constraint failed: patients.amka"):
            return String(localized: "Another patient already has this AMKA.")
        case let .open(msg):
            return String(localized: "The database could not be opened: \(msg)")
        case let .prepare(msg, _), let .step(msg, _), let .exec(msg, _):
            return String(localized: "A database operation failed: \(msg)")
        case let .keyingFailed(msg):
            return String(localized: "The database encryption key could not be applied: \(msg)")
        case .wrongKey:
            return String(localized: "The database key is wrong or the file is not an encrypted MedNotes store.")
        case .plaintextDatabase:
            return String(localized: "This database is not encrypted, so it cannot be opened in encrypted mode.")
        case .invalidRawKey:
            return String(localized: "The database key must be 64 hex characters (a 256-bit raw key).")
        }
    }
}

let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Which encryption mode a connection is opened in. Production stores are
/// always `.encrypted`; tests, the dry-run importer and the one-time migration
/// reader open `.plaintext` deliberately.
enum SQLConnectionMode: Sendable, Equatable {
    case encrypted(rawKey: Data)
    case plaintext
}

final class Statement {
    private let handle: OpaquePointer?
    private let sqlText: String
    fileprivate var finalized = false

    init(db: OpaquePointer?, sql: String) throws {
        self.sqlText = sql
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteError.prepare(String(cString: sqlite3_errmsg(db)), sql: sql)
        }
        self.handle = stmt
    }

    deinit {
        if !finalized { sqlite3_finalize(handle) }
    }

    func bind(_ idx: Int32, _ value: String?) {
        if let v = value {
            // Explicit byte count: with -1, an embedded NUL would end the stored text early.
            sqlite3_bind_text(handle, idx, v, Int32(v.utf8.count), SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(handle, idx)
        }
    }

    func bind(_ idx: Int32, _ value: Int) {
        sqlite3_bind_int64(handle, idx, Int64(value))
    }

    func bind(_ idx: Int32, _ value: Int?) {
        if let value {
            sqlite3_bind_int64(handle, idx, Int64(value))
        } else {
            sqlite3_bind_null(handle, idx)
        }
    }

    func bind(_ idx: Int32, _ value: Double) {
        sqlite3_bind_double(handle, idx, value)
    }

    func bind(_ idx: Int32, _ value: Bool) {
        sqlite3_bind_int64(handle, idx, value ? 1 : 0)
    }

    func bind(_ idx: Int32, _ value: Data?) {
        if let d = value {
            if d.isEmpty {
                sqlite3_bind_zeroblob(handle, idx, 0)
            } else {
                _ = d.withUnsafeBytes { buf in
                    sqlite3_bind_blob64(handle, idx, buf.baseAddress, sqlite3_uint64(d.count), SQLITE_TRANSIENT)
                }
            }
        } else {
            sqlite3_bind_null(handle, idx)
        }
    }

    @discardableResult
    func step() throws -> Bool {
        let rc = sqlite3_step(handle)
        if rc == SQLITE_ROW { return true }
        if rc == SQLITE_DONE { return false }
        throw SQLiteError.step(String(cString: sqlite3_errmsg(sqlite3_db_handle(handle))), sql: sqlText)
    }

    func reset() {
        sqlite3_reset(handle)
        sqlite3_clear_bindings(handle)
    }

    func finalize() {
        guard !finalized else { return }
        finalized = true
        sqlite3_finalize(handle)
    }

    func columnIsNull(_ i: Int32) -> Bool {
        sqlite3_column_type(handle, i) == SQLITE_NULL
    }

    func columnText(_ i: Int32) -> String? {
        guard !columnIsNull(i), let c = sqlite3_column_text(handle, i) else { return nil }
        // Read by byte count: String(cString:) would stop at an embedded NUL.
        let count = Int(sqlite3_column_bytes(handle, i))
        return String(decoding: UnsafeBufferPointer(start: c, count: count), as: UTF8.self)
    }

    func columnInt64(_ i: Int32) -> Int64? {
        columnIsNull(i) ? nil : sqlite3_column_int64(handle, i)
    }

    func columnInt(_ i: Int32) -> Int? {
        columnInt64(i).map(Int.init)
    }

    func columnBool(_ i: Int32) -> Bool? {
        columnInt64(i).map { $0 != 0 }
    }

    func columnData(_ i: Int32) -> Data? {
        guard !columnIsNull(i) else { return nil }
        guard let ptr = sqlite3_column_blob(handle, i) else { return Data() }
        let count = Int(sqlite3_column_bytes(handle, i))
        return Data(bytes: ptr, count: count)
    }
}

final class SQLConnection {
    private(set) var handle: OpaquePointer?
    let path: String
    let mode: SQLConnectionMode

    /// Opens a connection. Encrypted connections are keyed before any other
    /// statement, then hardened, then verified with `cipher_integrity_check`.
    /// Keying must precede `configure` because the first page read decides
    /// whether the codec is engaged.
    init(path: String, key: Data, readonly: Bool = false) throws {
        guard key.count == 32 else { throw SQLiteError.invalidRawKey }
        self.path = path
        self.mode = .encrypted(rawKey: key)
        try open(readonly: readonly)
        try applyKey(key)
        try SQLConnection.applyCipherPragmas(self)
        try verifyCipherIntegrity()
    }

    /// Plaintext connections are for the migration reader, the dry-run
    /// importer, and tests. Callers that want the production path must pass a key.
    init(path: String, readonly: Bool = false) throws {
        self.path = path
        self.mode = .plaintext
        try open(readonly: readonly)
    }

    private func open(readonly: Bool) throws {
        var flags: Int32 = SQLITE_OPEN_NOMUTEX
        if readonly {
            flags |= SQLITE_OPEN_READONLY
        } else {
            flags |= SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        }
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(db)
            throw SQLiteError.open("\(path): \(msg)")
        }
        self.handle = db
    }

    private func applyKey(_ key: Data) throws {
        guard let handle else { throw SQLiteError.open("connection closed") }
        // A 64-character hex literal in x'…' form makes SQLCipher use the
        // bytes as the raw AES key instead of running PBKDF2 over a
        // passphrase. The key is already 256 random bits from libsodium.
        let hex = key.map { String(format: "%02x", $0) }.joined()
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, "PRAGMA key = \"x'\(hex)'\"", nil, nil, &err) == SQLITE_OK else {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw SQLiteError.keyingFailed(msg)
        }
    }

    /// SQLCipher hardening applied to every encrypted connection. Memory
    /// security is on (SQLCipher zeroes its key schedule and page buffers),
    /// and `cipher_plaintext_header_size = 0` keeps the file header encrypted.
    static func applyCipherPragmas(_ conn: SQLConnection) throws {
        try conn.exec("PRAGMA cipher_memory_security = ON")
        try conn.exec("PRAGMA cipher_plaintext_header_size = 0")
    }

    /// `cipher_integrity_check` walks every page's HMAC; a wrong key or a
    /// corrupted page fails here rather than surfacing as garbage rows later.
    private func verifyCipherIntegrity() throws {
        let s = try prepare("PRAGMA cipher_integrity_check")
        if try s.step(), let detail = s.columnText(0), !detail.isEmpty {
            throw SQLiteError.wrongKey
        }
    }

    deinit {
        close()
    }

    func close() {
        if let h = handle {
            sqlite3_close_v2(h)
            handle = nil
        }
    }

    func prepare(_ sql: String) throws -> Statement {
        try Statement(db: handle, sql: sql)
    }

    func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(handle, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw SQLiteError.exec(msg, sql: sql)
        }
    }
}

/// Detects whether a file begins with a plaintext SQLite header.
enum SQLiteHeaderInspection {
    static let magic = Data("SQLite format 3\u{0}".utf8)

    static func isPlaintextSQLite(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: magic.count), head.count == magic.count else {
            return false
        }
        return head == magic
    }
}
