import Combine
import SwiftUI
import UniformTypeIdentifiers

/// The modules, launch choices and list filters the session switches between.
enum AppModule: String, CaseIterable, Identifiable {
    case notes
    case patients
    case todos
    case calendar
    case graph

    var id: String { rawValue }

    var title: String {
        switch self {
        case .notes: return String(localized: "Notes")
        case .patients: return String(localized: "Patients")
        case .todos: return String(localized: "Todos")
        case .calendar: return String(localized: "Calendar")
        case .graph: return String(localized: "Graph")
        }
    }

    var icon: String {
        switch self {
        case .notes: return "doc.text"
        case .patients: return "person.2"
        case .todos: return "checklist"
        case .calendar: return "calendar"
        case .graph: return "arrow.triangle.branch"
        }
    }

    var newItemTitle: String {
        switch self {
        case .notes: return String(localized: "New Note")
        case .patients: return String(localized: "New Patient")
        case .todos: return String(localized: "New Todo")
        case .calendar: return String(localized: "New Event")
        case .graph: return String(localized: "New Note")
        }
    }

    /// Graph has no list of its own to search; Find is disabled there.
    var hasSearch: Bool { self != .graph }

    var deleteConfirmTitle: String {
        switch self {
        case .notes: return String(localized: "Delete this note?")
        case .patients: return String(localized: "Delete this patient permanently?")
        case .todos: return String(localized: "Delete this todo?")
        case .calendar: return String(localized: "Delete this event?")
        case .graph: return "Delete?"
        }
    }
}

/// Settings › General › “At launch, open”. Persisted as one string —
/// `lastUsed` or a module's raw value — so a value written by a newer build
/// that names a module this one lacks falls back to the default instead of
/// costing a launch.
enum LaunchModule: Hashable {
    case lastUsed
    case fixed(AppModule)

    /// Patients, as the window has always opened; nothing changes until the
    /// user says so.
    static let `default` = LaunchModule.fixed(.patients)
    static let lastUsedStorageValue = "lastUsed"

    init(storageValue: String?) {
        guard let storageValue else {
            self = .default
            return
        }
        if storageValue == Self.lastUsedStorageValue {
            self = .lastUsed
        } else if let module = AppModule(rawValue: storageValue) {
            self = .fixed(module)
        } else {
            self = .default
        }
    }

    var storageValue: String {
        switch self {
        case .lastUsed: return Self.lastUsedStorageValue
        case .fixed(let module): return module.rawValue
        }
    }

    /// The module to show now, given the one that was showing last time.
    func startModule(lastUsed: AppModule?) -> AppModule {
        switch self {
        case .lastUsed: return lastUsed ?? Self.default.startModule(lastUsed: nil)
        case .fixed(let module): return module
        }
    }
}

enum TodoFilter: String, CaseIterable, Identifiable {
    case all
    case pending
    case completed
    case overdue
    case today

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return String(localized: "All")
        case .pending: return String(localized: "Pending")
        case .completed: return String(localized: "Completed")
        case .overdue: return String(localized: "Overdue")
        case .today: return String(localized: "Today")
        }
    }
}

enum EventFilter: String, CaseIterable, Identifiable {
    case all
    case upcoming
    case past

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return String(localized: "All")
        case .upcoming: return String(localized: "Upcoming")
        case .past: return String(localized: "Past")
        }
    }
}

enum PatientFilter: String, CaseIterable, Identifiable {
    case active
    case archived

    var id: String { rawValue }

    var title: String {
        switch self {
        case .active: return String(localized: "Active patients")
        case .archived: return String(localized: "Archived patients")
        }
    }
}
