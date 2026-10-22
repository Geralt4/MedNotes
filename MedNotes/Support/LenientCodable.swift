import Foundation

enum LenientDateError: Error, LocalizedError {
    case unsupported

    var errorDescription: String? {
        switch self {
        case .unsupported: return String(localized: "unsupported date format")
        }
    }
}

enum LenientDate {
    private static let lock = NSLock()

    static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static let sqlFractional: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
        return f
    }()

    static let sql: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f
    }()

    /// Calendar dates have no timezone. Interpret them as local midnight so
    /// DOB and medication end dates do not shift a day west of UTC.
    private static func dateOnlyLocal(_ value: String) -> Date? {
        let parts = value.split(separator: "-")
        guard parts.count == 3,
              parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              (1...12).contains(month), (1...31).contains(day)
        else { return nil }
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        let calendar = Calendar(identifier: .gregorian)
        guard let date = calendar.date(from: comps) else { return nil }
        let out = calendar.dateComponents([.year, .month, .day], from: date)
        guard out.year == year, out.month == month, out.day == day else { return nil }
        return date
    }

    static func decode(_ value: String) throws -> Date {
        lock.lock()
        defer { lock.unlock() }
        if let d = isoFractional.date(from: value) { return d }
        if let d = iso.date(from: value) { return d }
        if let d = sqlFractional.date(from: value) { return d }
        if let d = sql.date(from: value) { return d }
        if let d = dateOnlyLocal(value) { return d }
        if let t = Double(value) {
            return try decodeTimestamp(t)
        }
        throw LenientDateError.unsupported
    }

    /// Years like 1996 are valid Doubles but are not Unix timestamps.
    static func decodeTimestamp(_ t: Double) throws -> Date {
        guard t.isFinite, abs(t) >= 100_000_000 else { throw LenientDateError.unsupported }
        return Date(timeIntervalSince1970: t)
    }

    static func encodeJSON(_ date: Date) -> String {
        lock.lock()
        defer { lock.unlock() }
        return iso.string(from: date)
    }

    static func encodeSQL(_ date: Date) -> String {
        lock.lock()
        defer { lock.unlock() }
        return isoFractional.string(from: date)
    }
}

protocol LenientEnum: Codable, RawRepresentable, CaseIterable where RawValue == String {
    static var fallback: Self { get }
    /// A requirement, not just an extension member: `init(from:)` below calls
    /// `Self.parse`, and types with a custom `parse` (BloodType's "A+" forms)
    /// only get it during decoding if the call dispatches dynamically.
    static func parse(_ raw: String) -> Self
}

extension LenientEnum {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        self = Self.parse(raw)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    static func parse(_ raw: String) -> Self {
        if let exact = Self(rawValue: raw) { return exact }
        let normalized = Self.normalize(raw)
        for c in Self.allCases where Self.normalize(c.rawValue) == normalized {
            return c
        }
        return fallback
    }

    static func normalize(_ s: String) -> String {
        s.lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }
}

struct LossyUUID: Decodable {
    let value: UUID?

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let id = try? c.decode(UUID.self) {
            value = id
        } else if let s = try? c.decode(String.self) {
            value = UUID(uuidString: s)
        } else {
            value = nil
        }
    }
}

func decodeLossyUUIDs<K: CodingKey>(_ c: KeyedDecodingContainer<K>, forKey key: K) -> [UUID] {
    guard let raw = try? c.decodeIfPresent([LossyUUID].self, forKey: key) else { return [] }
    var seen = Set<UUID>()
    return raw.compactMap(\.value).filter { seen.insert($0).inserted }
}

func decodeLossyUUID<K: CodingKey>(_ c: KeyedDecodingContainer<K>, forKey key: K) -> UUID? {
    (try? c.decodeIfPresent(LossyUUID.self, forKey: key))?.value
}

func decodeLossyUUIDs(from data: Data) -> [UUID] {
    guard let raw = try? JSONDecoder().decode([LossyUUID].self, from: data) else { return [] }
    var seen = Set<UUID>()
    return raw.compactMap(\.value).filter { seen.insert($0).inserted }
}

struct LossyString: Decodable {
    let value: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        value = try? c.decode(String.self)
    }
}

func decodeLossyString<K: CodingKey>(_ c: KeyedDecodingContainer<K>, forKey key: K) -> String? {
    try? c.decodeIfPresent(String.self, forKey: key)
}

func decodeLossyBool<K: CodingKey>(_ c: KeyedDecodingContainer<K>, forKey key: K) -> Bool? {
    if let b = try? c.decodeIfPresent(Bool.self, forKey: key) { return b }
    if let i = try? c.decodeIfPresent(Int.self, forKey: key) { return i != 0 }
    if let s = try? c.decodeIfPresent(String.self, forKey: key) {
        switch s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "true", "yes", "1": return true
        case "false", "no", "0": return false
        default: return nil
        }
    }
    return nil
}

func decodeLossyInt<K: CodingKey>(_ c: KeyedDecodingContainer<K>, forKey key: K) -> Int? {
    if let i = try? c.decodeIfPresent(Int.self, forKey: key) { return i }
    if let d = try? c.decodeIfPresent(Double.self, forKey: key), let i = Int(exactly: d) { return i }
    if let s = try? c.decodeIfPresent(String.self, forKey: key) { return Int(s) }
    return nil
}

func decodeLossyDouble<K: CodingKey>(_ c: KeyedDecodingContainer<K>, forKey key: K) -> Double? {
    if let d = try? c.decodeIfPresent(Double.self, forKey: key) { return d }
    if let i = try? c.decodeIfPresent(Int.self, forKey: key) { return Double(i) }
    if let s = try? c.decodeIfPresent(String.self, forKey: key) { return Double(s) }
    return nil
}

func decodeLossyStrings<K: CodingKey>(_ c: KeyedDecodingContainer<K>, forKey key: K) -> [String] {
    guard let raw = try? c.decodeIfPresent([LossyString].self, forKey: key) else { return [] }
    return raw.compactMap(\.value)
}

struct LossyDecodable<T: Decodable>: Decodable {
    let value: T?

    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}

func decodeLossyArray<T: Decodable, K: CodingKey>(_ type: T.Type, _ c: KeyedDecodingContainer<K>, forKey key: K) -> [T] {
    guard let raw = try? c.decodeIfPresent([LossyDecodable<T>].self, forKey: key) else { return [] }
    return raw.compactMap(\.value)
}

func decodeLossyStrings(from data: Data) -> [String] {
    guard let raw = try? JSONDecoder().decode([LossyString].self, from: data) else { return [] }
    return raw.compactMap(\.value)
}

func decodeJSONData<T: Decodable>(_ type: T.Type, from data: Data, dateDecoding: JSONDecoder.DateDecodingStrategy = .custom { d in
    let c = try d.singleValueContainer()
    if let s = try? c.decode(String.self) {
        return try LenientDate.decode(s)
    }
    if let t = try? c.decode(Double.self) {
        return try LenientDate.decodeTimestamp(t)
    }
    throw LenientDateError.unsupported
}) throws -> T {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = dateDecoding
    return try decoder.decode(type, from: data)
}

func encodeJSONData<T: Encodable>(_ value: T, dateEncoding: JSONEncoder.DateEncodingStrategy = .custom { date, encoder in
    var c = encoder.singleValueContainer()
    try c.encode(LenientDate.encodeJSON(date))
}, sortedKeys: Bool = true) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = dateEncoding
    if sortedKeys {
        encoder.outputFormatting = [.sortedKeys]
    }
    return try encoder.encode(value)
}
