# MedNotes Bug Audit

**Audit date:** 2026-10-27  
**Mode:** Read-only review. This report is the only file created in the repository.

## Executive summary

The repository has a broad automated test suite, and the full macOS test run completed with **504 passed, 4 skipped, 0 failed**. Two additional targeted XCTest probes, compiled in an isolated copy under `/private/tmp`, reproduced defects in the patient-lock save path and backup schema validation.

The highest-risk findings affect encrypted backup restore and first-run encryption migration. Restore validation accepts a malicious SQLite trigger when its name ends in an FTS-like suffix. A crash between the migration's database and attachment swaps can leave an encrypted database paired with the old attachment tree; startup does not consult the migration journal. Other confirmed defects can silently discard a newly added patient attachment during a lock flush, exhaust disk during restore, resurrect deleted Apple Calendar/Reminders items after a remote-delete failure, and block release after the passing suite's fourth skip.

## Areas inspected and coverage limitations

- Read the repository README, encryption and store ADRs, security/dependency documentation, and prior bug-review notes. Checked project instructions and repository file inventory.
- Traced storage, database schema and attachment synchronization, migration, key management, backup creation/restore, archive extraction, JSON import, patient save flows, Apple Calendar/Reminders synchronization, app startup/locking, and release/dependency scripts.
- Reviewed the model/UI/test areas through repository-wide inventory and targeted searches, then ran the full macOS suite. The test suite uses in-process/offscreen UI coverage; there is no end-to-end UI test target for real system interactions.
- The full test command was `xcodebuild -project MedNotes.xcodeproj -scheme MedNotes -destination 'platform=macOS' -derivedDataPath /private/tmp/MedNotesAuditDerivedData -resultBundlePath /private/tmp/MedNotesAudit.xcresult -parallel-testing-enabled NO test`.
- Two probes were compiled and run in a temporary repository copy, not added to this repository. Both passed while asserting the defective behavior described below.
- I did not run a live EventKit permission/delete failure, interrupt a real migration process at the filesystem swap boundary, build a full large malicious archive, or exercise near-limit backup sizes. Those limitations are called out in the relevant findings. No release was attempted because it requires signing/notarization credentials and creates release artifacts.
- The review prioritized executable behavior and high-risk paths; it is not a formal proof of every possible UI state or every platform-specific EventKit outcome. No source changes or tests were added to the repository.

## Confirmed bugs

### BUG-001 — Restore schema validation accepts and installs active SQLite triggers

**Severity:** HIGH  
**Status:** Confirmed; trigger bypass and execution reproduced in an isolated targeted XCTest. The probe used the same restore-stage schema validator, but did not construct a complete sealed archive end to end.

**Evidence:** [BackupService.swift](/Users/giannismanologlou/Documents/MedNotes/MedNotes/Services/BackupService.swift:23) accepts any trigger whose name ends with `_fts_insert`, `_fts_delete`, or `_fts_update` (lines 23–37). Restore calls this validator on the staged database before installing it (lines 673–686). Legitimate trigger names are known and limited, for example `patients_fts_insert` and `notes_fts_insert` in [Schema.swift](/Users/giannismanologlou/Documents/MedNotes/MedNotes/Storage/Schema.swift:158).

**Reproduction:** Add `CREATE TRIGGER audit_probe_fts_insert AFTER INSERT ON notes BEGIN DELETE FROM patients; END` to a staged database, call `validateExpectedSchema()`, then insert a note. The validator accepts the database and the note insert deletes patient rows. The isolated probe passed with those assertions.

**Expected:** A restored database contains only the exact trusted schema and trigger definitions used by the app.

**Actual:** A trigger with an arbitrary SQL body passes because only its name suffix is checked. It remains in the restored database and executes on later writes, allowing a crafted backup to corrupt or delete user records.

**Recommended fix:** Compare the complete trigger-name set and SQL definitions against trusted schema definitions, or rebuild a clean database from validated records instead of installing untrusted schema objects.

**Interaction:** Affects every restore path that reaches `validateStagedDatabase`, including recovery from a user-selected portable backup. This is independent of the disk-capacity issue in BUG-004.

### BUG-002 — Migration crash between database and attachment swaps is not recovered

**Severity:** HIGH  
**Status:** Confirmed by source control-flow; the exact process-kill timing was not executed.

**Evidence:** [StoreMigrator.swift](/Users/giannismanologlou/Documents/MedNotes/MedNotes/Storage/StoreMigrator.swift:252) writes the `.swapping` journal and performs two sequential filesystem operations: `swapInEncryptedDatabase` then `swapInAttachments` (lines 255–269). The old database and old attachment tree are moved aside separately (lines 287–324). `readJournal()` exists (lines 102–111), but repository search found no caller. Startup in [AppSession.swift](/Users/giannismanologlou/Documents/MedNotes/MedNotes/UI/Notes/AppSession.swift:1916) classifies and opens the database without inspecting the journal or validating attachment files. The startup integrity check validates SQLite and foreign keys only (lines 1257–1274). The migration test named `testMigrationCrashAtEachPhaseLeavesTheOriginalIntact` only writes a journal before the swap and calls rollback; it does not simulate a crash after either swap ([SecurityTests.swift](/Users/giannismanologlou/Documents/MedNotes/MedNotesTests/SecurityTests.swift:400)).

**Reproduction:** Begin migration on a plaintext store containing an attachment. Stop the process after `swapInEncryptedDatabase(from:)` returns and before `swapInAttachments(stagingRoot:)` begins. On relaunch, the key has already been persisted by `createMigrationKey()` ([SecureStoreCoordinator.swift](/Users/giannismanologlou/Documents/MedNotes/MedNotes/Storage/SecureStoreCoordinator.swift:205)), so startup recognizes the encrypted database and opens it. The attachment swap did not happen; the database points at encrypted storage IDs that are absent from the live `Attachments` directory, while plaintext originals remain under the old migration paths. Opening those attachment records then fails.

**Expected:** Startup uses the journal to deterministically roll back or finish the migration before opening the store, and verifies every attachment.

**Actual:** Startup ignores the journal and can expose a partially installed store. Depending on the interruption point, attachments become unavailable and plaintext database/file copies remain on disk. If migration throws after a swap, `runMigration` calls `rollbackStaging()` ([AppSession.swift](/Users/giannismanologlou/Documents/MedNotes/MedNotes/UI/Notes/AppSession.swift:2041)), which removes staging and the journal but does not restore the old store ([StoreMigrator.swift](/Users/giannismanologlou/Documents/MedNotes/MedNotes/Storage/StoreMigrator.swift:369)).

**Recommended fix:** Make startup read and validate the journal before store construction; implement phase-aware rollback/roll-forward that treats the database and attachment directory as one unit. Verify cleanup and retain the journal until recovery or cleanup is complete. Add process-level crash tests at each operation boundary.

**Interaction:** Can make the local data unavailable after migration interruption and can leave plaintext PHI at rest despite successful encrypted-database startup. Suppressed cleanup errors in `finishCleanup()` (lines 350–367) make manual recovery and plaintext-remnant detection harder.

### BUG-003 — Lock-time patient save omits the attachment IDs that protect stale drafts

**Severity:** MEDIUM  
**Status:** Confirmed; the save behavior was reproduced with an isolated targeted XCTest. The exact visible lock interaction was traced in production source rather than exercised through a live UI test.

**Evidence:** Normal patient saves pass the file IDs from the editor's original snapshot ([PatientDetailView.swift](/Users/giannismanologlou/Documents/MedNotes/MedNotes/UI/Patients/PatientDetailView.swift:137), lines 139–140). The lock callback captures only the patient draft and edited flag (lines 39–43; [OpenEditorDraft.swift](/Users/giannismanologlou/Documents/MedNotes/MedNotes/UI/Notes/OpenEditorDraft.swift:14)). Lock flushing then calls `store.patients.save(patient)` without `knownFileIDs` ([AppSession.swift](/Users/giannismanologlou/Documents/MedNotes/MedNotes/UI/Notes/AppSession.swift:1045), lines 1058–1062). That parameter defaults to `nil` ([Services.swift](/Users/giannismanologlou/Documents/MedNotes/MedNotes/Services/Services.swift:37)). The database rejects stale attachment rows only when the known-ID set is present; without it, `syncPatientFiles` deletes rows absent from the stale draft ([Database.swift](/Users/giannismanologlou/Documents/MedNotes/MedNotes/Storage/Database.swift:620), lines 629–637 and 708–722). After commit, the superseded-object sweep removes storage IDs no longer referenced ([Services.swift](/Users/giannismanologlou/Documents/MedNotes/MedNotes/Services/Services.swift:91)).

**Reproduction:** Load a patient draft with no attachment and edit a field. While that draft remains open, add an attachment to the same patient through a newer save/import. Lock the store. The lock flush writes the older draft without known IDs; the newly added metadata row is deleted, and the ciphertext becomes eligible for removal. The isolated XCTest modeled this lock-save call and verified the metadata row disappeared.

**Expected:** A stale lock-time draft is rejected or merged without removing file IDs it never loaded.

**Actual:** The ordinary editor-save path has the stale-draft guard, but the lock-save path bypasses it and can permanently remove an attachment added since the editor loaded.

**Recommended fix:** Carry the editor's original attachment IDs in `OpenEditorDraft` and pass them to `PatientService.save` during lock flush, or apply equivalent revision/presence validation to all editor writes.

**Interaction:** Requires an attachment-changing save/import while an edited patient draft is open and then a lock. It is separate from JSON import's intentional whole-record upsert behavior.

### BUG-004 — Restore free-space precheck ignores per-attachment ciphertext padding

**Severity:** MEDIUM  
**Status:** Confirmed from bounded archive rules and storage behavior; a 90,000-file disk-filling restore was not run.

**Evidence:** Restore checks free space using only twice the input archive size ([BackupService.swift](/Users/giannismanologlou/Documents/MedNotes/MedNotes/Services/BackupService.swift:330), lines 330–332). V2 permits up to 100,000 records and attachments up to 2 GiB each ([BackupArchiveV2.swift](/Users/giannismanologlou/Documents/MedNotes/MedNotes/Support/BackupArchiveV2.swift:35), lines 38–43); extraction accepts attachment metadata up to the record cap (lines 561–566). Extraction stores every completed attachment, including zero-byte attachments ([ArchiveExtraction.swift](/Users/giannismanologlou/Documents/MedNotes/MedNotes/Support/ArchiveExtraction.swift:38), lines 38–48). `EncryptedFileStore.store` pads every payload to a 64 KiB boundary, so even an empty file consumes roughly one 64 KiB encrypted block plus headers/tags (lines 122–158).

**Reproduction:** Create a valid archive/database containing tens of thousands of zero-byte attachments (for example 90,000, within the record cap). Restore it on a volume with enough room for the archive and the `archiveSize * 2` precheck, but less than the roughly 5.5 GiB of padded attachment ciphertext. The precheck passes; extraction then attempts to write the much larger staging tree and can fill the volume.

**Expected:** Restore estimates checked aggregate staging bytes, including encryption overhead/padding, and rejects an archive before writing when space is insufficient.

**Actual:** The archive's small metadata cost is used as the capacity estimate, while the restored file count determines a much larger output footprint. A valid user-selected archive can exhaust disk during restore.

**Recommended fix:** Compute overflow-safe aggregate padded size from validated attachment lengths/counts and include snapshot, attachment, restore-point, and swap overhead in the preflight estimate. Enforce a total extracted-size/file-count limit as well.

**Interaction:** This is in the same restore pipeline as BUG-001. A disk-full error can also interrupt staging/cleanup, although the staging directory is deferred for removal.

### BUG-005 — Failed remote deletion is hidden and the next sync recreates the item

**Severity:** MEDIUM  
**Status:** Confirmed conditional behavior from source; no live EventKit failure was induced.

**Evidence:** `removeTodo` and `removeEvent` delete the local row first, then discard errors from remote deletion using `try?` ([AppSession.swift](/Users/giannismanologlou/Documents/MedNotes/MedNotes/UI/Notes/AppSession.swift:2661), lines 2665–2679; lines 2846–2864). EventKit's `deleteRemote` methods can throw when `store.remove` fails ([AppleRemindersService.swift](/Users/giannismanologlou/Documents/MedNotes/MedNotes/Services/AppleRemindersService.swift:363), lines 374–378; [AppleCalendarService.swift](/Users/giannismanologlou/Documents/MedNotes/MedNotes/Services/AppleCalendarService.swift:304), lines 315–319). On the next pull, a marker-owned remote object with no matching local identifier is returned as a creation (Reminders lines 448–469; Calendar lines 378–402), and `AppSession` saves those creations as new local records ([AppSession.swift](/Users/giannismanologlou/Documents/MedNotes/MedNotes/UI/Notes/AppSession.swift:2978), lines 2978–2983 and 3087–3094).

**Reproduction:** Start with a synced todo/event, make EventKit's remove call fail while the local delete succeeds, then run sync. The delete error is not surfaced or queued; the surviving marked remote item has no local row and is imported with a new local UUID. The original local association/identity is lost and the supposedly deleted item reappears.

**Expected:** A failed remote delete is reported and retained for retry, or represented as a durable tombstone that prevents pull from resurrecting it.

**Actual:** The UI reports local deletion as complete, suppresses the remote failure, and the next pull can recreate the item locally.

**Recommended fix:** Persist delete tombstones/outbox entries until the remote delete succeeds; surface failure and make pull reconcile tombstones before importing marked remote objects.

**Interaction:** Applies to both Calendar and Reminders. It is conditional on EventKit leaving the remote object present after a failed remove.

### BUG-006 — Release gate rejects the current passing test suite's skip count

**Severity:** MEDIUM  
**Status:** Confirmed by the full test run and release-script condition; the release pipeline itself was not run.

**Evidence:** The full suite completed with 504 passing tests and 4 skipped. [release.sh](/Users/giannismanologlou/Documents/MedNotes/scripts/release.sh:52) says only three skips are allowed, and exits when the counted skipped cases exceed three (lines 64–67).

**Reproduction:** Run the full macOS test command above, then apply the release script's `SKIPPED > 3` check to its test log. With the observed four skips, the gate exits with “unexpected skips (4 > 3)” despite `** TEST SUCCEEDED **`.

**Expected:** A passing suite with only known, documented environment skips proceeds to archive/signing.

**Actual:** The current suite's observed result is rejected, so a release stops before archive creation.

**Recommended fix:** Reconcile the allowlist with actual skip cases and count/validate named tests rather than relying on a stale numeric threshold. Keep unexpected skips fail-closed.

**Interaction:** Independent of application runtime defects; blocks shipping fixes for them until the release gate is updated.

### BUG-007 — Dependency documentation points to a nonexistent scanner script

**Severity:** LOW  
**Status:** Confirmed by repository inventory.

**Evidence:** [docs/dependencies.md](/Users/giannismanologlou/Documents/MedNotes/docs/dependencies.md:15) instructs users to run `scripts/scan_dependencies.sh`, but the repository contains `scripts/scan_dependencies.py`; README and `release.sh` use the Python path.

**Reproduction:** From the repository root, run `scripts/scan_dependencies.sh`; the shell reports that the file does not exist.

**Expected:** The documented dependency check runs successfully.

**Actual:** Following this document's command fails before scanning. The release script is unaffected because it invokes the Python file.

**Recommended fix:** Update the dependency documentation to name `scripts/scan_dependencies.py`.

## Suspected bugs requiring further investigation

### BUG-008 — Backup and attachment size limits exceed the in-memory processing path

**Severity:** MEDIUM  
**Status:** Suspected resource-exhaustion defect; no near-limit fixture was run.

**Evidence:** V2 permits an 8 GiB snapshot and 2 GiB attachment ([BackupArchiveV2.swift](/Users/giannismanologlou/Documents/MedNotes/MedNotes/Support/BackupArchiveV2.swift:42)). Snapshot creation materializes the complete snapshot file as `Data` before the size check in `seal` ([BackupService.swift](/Users/giannismanologlou/Documents/MedNotes/MedNotes/Services/BackupService.swift:224), lines 253–256; [BackupArchiveV2.swift](/Users/giannismanologlou/Documents/MedNotes/MedNotes/Support/BackupArchiveV2.swift:303), lines 303–306). Archive extraction accumulates each attachment in `pending` before storing it ([ArchiveExtraction.swift](/Users/giannismanologlou/Documents/MedNotes/MedNotes/Support/ArchiveExtraction.swift:31), lines 31–48 and 67–76). `EncryptedFileStore.store` builds additional plaintext/padded and ciphertext `Data` buffers (lines 122–159), while `read` loads and decrypts a complete attachment in memory (lines 164–215).

**Reproduction to investigate:** Create or restore a valid archive with a near-limit attachment or snapshot while observing peak resident memory. The expected robust behavior is streaming or an explicit lower resource cap; the suspected actual behavior is multi-gigabyte allocation and possible process termination before the declared limits are reached.

**Recommended fix:** Stream snapshot and attachment bytes through bounded buffers, or set and enforce limits that account for peak memory before allocation. Add large-but-safe resource tests and measure peak memory on supported macOS versions.

**Interaction:** May occur alongside BUG-004 for large restores, but it is an independent memory-capacity failure mode.

## Potential interactions and prioritization

- BUG-001 and BUG-004 affect backup restore, but trigger acceptance is a database-integrity/security defect while BUG-004 is capacity exhaustion.
- BUG-002 can leave a mixed migration state and plaintext artifacts; BUG-003 can permanently remove ciphertext/metadata during a later lock. Both concern attachment availability but require different user actions and code paths.
- BUG-005 is a two-system consistency issue: local deletion commits before EventKit deletion, and later pull treats the remote record as a new import.
- BUG-006 and BUG-007 affect release/documentation workflows, not runtime data. BUG-008 needs targeted large-file profiling before its practical threshold can be established.
