import Combine
import SwiftUI
import UniformTypeIdentifiers

/// Settings > Data: storage summary, restore points, integrity checks, index rebuild.
extension AppSession {
    /// What Settings › Data shows about the store itself.
    func storageSummary() async -> StorageSummary? {
        guard let store, let dataRoot else { return nil }
        let counts = (try? await store.counts()) ?? [:]
        let lastBackup = (try? await store.audit.latest(action: "backup_create"))
            .flatMap { $0.map { StorageSummary.LastBackup(date: $0.timestamp, name: $0.entityId) } }
        return StorageSummary(
            rootURL: dataRoot.rootURL,
            backupsURL: dataRoot.restorePointsURL,
            counts: counts,
            lastBackup: lastBackup)
    }

    /// The encrypted restore points, newest first, each measured.
    /// Measuring walks the file, so it runs off the main actor.
    func restorePoints() async -> [RestorePoint] {
        guard let store else { return [] }
        let infos = (try? store.backups.listRestorePoints()) ?? []
        return await Task.detached(priority: .utility) {
            infos.map { info in
                RestorePoint(url: info.url, createdAt: info.manifest.createdAt, name: info.manifest.name,
                             counts: info.manifest.counts, sizeBytes: BackupService.sizeOnDisk(at: info.url))
            }
        }.value
    }

    func deleteRestorePoint(_ point: RestorePoint) async throws {
        let store = try openStore()
        try store.backups.removeRestorePoint(at: point.url)
        try? await store.audit.log(
            action: "restore_point_delete", entityType: "backup", entityId: point.id,
            details: "Deleted restore point \"\(point.name)\"")
    }

    /// Keeps the newest `BackupService.restorePointsToKeep`, audited when
    /// anything went. Housekeeping only: a failed prune costs disk, not data.
    func pruneRestorePoints() async {
        guard let store else { return }
        guard let removed = try? store.backups.pruneRestorePoints(),
              !removed.isEmpty else { return }
        try? await store.audit.log(
            action: "restore_point_prune", entityType: "backup", entityId: "restore-points",
            details: "Removed \(removed.count) older restore point(s)")
    }

    /// The checks a backup must pass before it is trusted, run on the live
    /// store on request. The outcome lands in the audit trail either way.
    func checkIntegrity() async -> IntegrityReport {
        guard let store else {
            return IntegrityReport(passed: false, checkedAt: Date(),
                                   detail: String(localized: "The store is not open."))
        }
        let report = await runIntegrityChecks(on: store)
        try? await store.audit.log(
            action: "integrity_check", entityType: "store", entityId: "settings",
            details: report.passed ? "ok" : report.detail)
        integrityWarning = report.passed ? nil : report.detail
        return report
    }

    /// Rebuilds everything derived from the notes and patients (links,
    /// metadata, both search indexes) and checks it. The audit row carries
    /// counts only.
    func rebuildIndexes() async -> IndexRebuildOutcome {
        guard let store else {
            return IndexRebuildOutcome(passed: false, rebuiltAt: Date(),
                                       detail: String(localized: "The store is not open."))
        }
        do {
            let report = try await store.db.rebuildIndexes()
            try? await store.audit.log(
                action: "indexes_rebuilt", entityType: "store", entityId: "settings",
                details: report.auditDetails)
            await reload()
            if report.passed, integrityWarning == Self.searchRebuildWarning { integrityWarning = nil }
            var detail = String(localized: "Rebuilt \(report.notes) notes: \(report.links) links (\(report.unresolvedLinks) unresolved), \(report.headings) headings, \(report.tags) tags.")
            if report.failedNotes > 0 {
                detail += " " + String(localized: "\(report.failedNotes) notes could not be read into the indexes; they are tried again when the store opens.")
            } else if report.passed {
                detail += " " + String(localized: "All checks passed.")
            } else {
                detail += " " + String(localized: "A check failed after the rebuild.")
            }
            return IndexRebuildOutcome(passed: report.passed, rebuiltAt: Date(), detail: detail)
        } catch {
            if let failure = error as? IndexRebuildError {
                try? await store.audit.log(
                    action: "indexes_rebuilt", entityType: "store", entityId: "settings",
                    details: "passed=0 problems=\(failure.problems.count)")
            }
            return IndexRebuildOutcome(passed: false, rebuiltAt: Date(),
                                       detail: String(localized: "The indexes could not be rebuilt and were left as they were."))
        }
    }

    /// Shown when the one-time search refold failed at launch.
    static var searchRebuildWarning: String {
        String(localized: "Search needs rebuilding: open Settings › Data › Rebuild Indexes.")
    }

    /// The same checks after launch, off the critical path: nothing on a
    /// pass (a row per launch would drown the trail), the warning and an
    /// audit row on a failure.
    func checkIntegrityQuietly() async {
        guard let store else { return }
        let report = await runIntegrityChecks(on: store)
        if report.passed {
            if await store.db.searchIndexNeedsRebuild {
                try? await store.audit.log(
                    action: "integrity_check", entityType: "store", entityId: "launch",
                    details: "search index needs rebuilding")
                integrityWarning = Self.searchRebuildWarning
            } else {
                integrityWarning = nil
            }
            return
        }
        try? await store.audit.log(
            action: "integrity_check", entityType: "store", entityId: "launch",
            details: report.detail)
        integrityWarning = report.detail
    }

    private func runIntegrityChecks(on store: AppStore) async -> IntegrityReport {
        do {
            let result = try await store.integrity()
            let violations = try await store.foreignKeyViolations()
            let passed = result == "ok" && violations == 0
            let detail: String
            if passed {
                detail = String(localized: "No problems found.")
            } else if result != "ok" {
                detail = String(localized: "The database file is damaged. SQLite reports: \(result)")
            } else {
                detail = String(localized: "\(violations) records point to a patient that no longer exists.")
            }
            return IntegrityReport(passed: passed, checkedAt: Date(), detail: detail)
        } catch {
            return IntegrityReport(passed: false, checkedAt: Date(), detail: error.localizedDescription)
        }
    }
}
