# Critical bug review — 2026-10-22

Five confirmed security and data-loss findings. Production code was not changed. All reproductions used synthetic records, temporary stores, and in-memory test keys.

The existing suite passed: **428 passed, 3 skipped, 0 failed**. Eight additional tests reproduced the critical findings below in an isolated project copy. They assert the intended behavior and fail against the reviewed implementation. The included [reproduction tests](BugReviewReproductionTests.swift) exclude the small issues found during review.

## 1. Restore points disclose the entire database without the device key

**Priority: P1 — confidentiality failure.**

Location: `MedNotes/Services/BackupService.swift:431` and `:452`; key derivation in `MedNotes/Support/BackupArchiveV2.swift:214`.

**Reproduction:** Save a synthetic note containing `REVIEW_SECRET_92741`, create an internal `.mnrp` restore point, then close the source store. Open only the restore-point file using the literal `MedNotesRestorePointMedNotesRestorePoint`, extract the database chunks, and open the resulting snapshot with the archive-derived key. The note and its full content are readable. No root key, database key, attachment key, or restore-point key is supplied to the reader.

**Cause:** Internal points use the ordinary portable archive encryption with a public, constant passphrase. Despite the comments, the device restore key never participates. The `attachmentKey` argument to `createEncryptedRestorePoint` is unused. Anyone who can obtain a restore-point file can decrypt its records and inner SQLCipher snapshot.

**Proposed fix:** Give internal points a distinct, versioned encryption path keyed by the device-derived restore key. Thread that key from `SecureStoreCoordinator` through `AppStore` to `BackupService`; use it for both creation and rollback. Re-encrypt existing points while the store is unlocked. Add a test proving that possession of an archive and the public constant cannot decrypt it, and that another device key fails.

Test: `testRestorePointMustRequireDeviceSecret`.

## 2. Backup extraction loses files; a failed restore can leave live data replaced

**Priority: P1 — broken disaster recovery and failed-operation data loss.**

Locations: `MedNotes/Services/BackupService.swift:323`, `:280`, `:299`, `:303`, and `:616`; `MedNotes/Storage/StoreRecovery.swift:198`; writer order in `MedNotes/Support/BackupArchiveV2.swift:279`.

**Reproductions:**

1. Save two distinct four-byte attachments, `AAAA` and `BBBB`, and create a portable backup. Normal restore rejects the app's own backup with `Integrity check failed: attachment 00000000-0000-0000-0000-000000000002`.
2. Recover that same backup into a temporary root with a missing device key. Recovery reports success and `attachmentCount == 2`, but the first attachment's ciphertext file is absent.
3. Save a patient with two attachments plus a note `ORIGINAL_LIVE_NOTE` in the target store. Attempt to restore a different app-created backup containing an empty attachment. Restore throws a verification error, then rollback fails too. After the thrown error, the original patient and note are absent from the live store.

**Causes:** The writer emits all attachment metadata before any attachment content. Both extraction implementations retain only the last metadata record, so content is associated with the wrong file. Zero-byte attachments are never materialized because storing happens only in the chunk handler. Normal restore verifies attachments after replacing the live database and attachment directory; rollback reuses the broken extractor and its error is suppressed with `try?`. Missing-key recovery also omits full attachment digest verification before installation.

**Proposed fix:** Share a single extraction implementation between restore and recovery. Maintain a metadata queue and advance it as each attachment finishes; explicitly create zero-byte files, check every length and digest, and reject incomplete content. Validate the staged database together with the staged attachment store before changing live paths. Preserve the original database and attachment directory until the entire install succeeds, so rollback can restore the originals directly without decrypting a newly created backup. Surface any rollback failure and keep the session closed. Make recovery run the same full validation.

Tests: `testPortableBackupRestoresTwoDistinctAttachments`, `testMissingKeyRecoveryPreservesBothAttachments`, `testPortableBackupRestoresEmptyAttachment`, and `testFailedRestoreKeepsOriginalDataWhenRollbackHasTwoAttachments`.

## 3. The mandatory pre-migration backup passes verification but cannot restore

**Priority: P1 — the migration safety copy is unusable.**

Locations: `MedNotes/UI/Notes/AppSession.swift:831`; `MedNotes/Storage/Database.swift:101`.

**Reproduction:** Create a plaintext database with a note, construct `BackupService` with that database and `fileStore: nil` exactly as `migrationBackup` does, then create the required v2 backup. `BackupArchiveV2.inspect` succeeds. Restoring that backup into an encrypted store fails with `The database key is wrong or the file is not an encrypted MedNotes store.`

**Cause:** `vacuumInto(path:key:)` encrypts/rekeys the snapshot only when the source has a `databaseKey`. A plaintext source therefore produces a plaintext inner snapshot. Restore always opens the inner snapshot with the archive-derived SQLCipher key. The migration's verification reads only the outer manifest, so it never detects the incompatibility.

**Proposed fix:** Build the snapshot under the requested archive key for both plaintext and encrypted sources, using an explicit SQLCipher export or a fresh encrypted staging database. Before allowing migration to proceed, perform a full restore and record/attachment verification into a throwaway encrypted store. Preserve a compatibility path for already generated pre-migration backups.

Test: `testPreMigrationBackupCanActuallyRestore`.

## 4. Legacy import silently discards inline attachment data

**Priority: P1 — successful import loses clinical files.**

Locations: `MedNotes/UI/Notes/AppSession.swift:1733`; `MedNotes/Import/JSONImporter.swift:30`; `MedNotes/Storage/Database.swift:558`.

**Reproduction:** Create legacy patient JSON containing one inline attachment with bytes `LEGACY_FILE_BYTES`. Run the actual `AppSession.performImport` flow, lock the session, then reopen its encrypted store. The patient imports and the file metadata exists, but `storageID` is nil and `loadFileData` returns nil instead of the original 17 bytes. The import completes without reporting that loss.

**Cause:** Production passes `filesRoot: nil` to the importer. This bypasses its only file-persistence branch and directly calls `Database.importBatch`. The database intentionally strips inline bytes, and the importer never receives or invokes the encrypted attachment store. The comment claiming that import stages through encrypted storage does not match the call path.

**Proposed fix:** Add encrypted attachment staging to the batch importer. Pass the store's `AttachmentStore`, encrypt inline bytes to fresh storage IDs, populate length/digest metadata, commit the complete batch atomically, and remove staged ciphertext if the database import fails. Make dry run and actual import validate the same file requirements; verify imported attachment bytes before reporting success.

Test: `BugReviewImportReproductionTests.testLegacyImportPreservesInlineAttachment`.

## 5. A rejected patient save still overwrites committed attachment content

**Priority: P1 — database rollback does not protect file contents.**

Locations: `MedNotes/Services/Services.swift:51`, `:61`, and `:94`.

**Reproduction:** Through `PatientService`, save patient A with AMKA `11111111111`, and patient B with AMKA `22222222222` and an attachment containing `ORIGINAL`. Load B, set its AMKA to A's value, replace the attachment bytes with `REPLACED`, and save. The unique AMKA constraint rejects the save; B's persisted AMKA remains unchanged. Reading the supposedly unchanged attachment returns `REPLACED`. Its database digest still describes the original content.

**Cause:** `stageEncryptedFileBytes` replaces the existing storage ID before the database transaction. Its rollback machinery tracks only the plaintext file-promotion path, so rejection cannot restore the previous ciphertext. The old committed bytes have already been destroyed.

**Proposed fix:** Use immutable attachment versions: write replacement content under a fresh storage ID, commit the new metadata in the database transaction, and remove the previous object only after commit. On failure, delete the newly staged object. This also needs recovery/cleanup handling for an interruption between the file write and metadata commit.

Test: `testRejectedPatientSaveKeepsPreviousAttachmentBytes`. This reproduction exercises the backend service directly; it does not rely on an attachment-editing UI.

## Rerunning the critical reproductions

These reproductions are a historical record of the 2026-10-22 review. The bugs they show have been fixed, and `BugReviewReproductionTests.swift` in this folder no longer compiles against the current source: `BackupService.createEncryptedRestorePoint` and `AppStore.init` have different signatures now. It is not part of the test target and is kept as the evidence the review was written from.

The fixes are covered by regression tests in the test target, in `MedNotesTests/CriticalFixTests.swift`. To run them from the project root:

```bash
xcodebuild \
  -project MedNotes.xcodeproj \
  -scheme MedNotes \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -only-testing:MedNotesTests/CriticalFixTests \
  test
```

Original baseline result, from before the fixes: `/private/tmp/MedNotesReviewBuild/Logs/Test/Test-MedNotes-2026.10.22_22-50-42-+0300.xcresult`.

Reproduction result, also from before the fixes: `/private/tmp/MedNotesReviewBuild/Logs/Test/Test-MedNotes-2026.10.22_22-55-49-+0300.xcresult`. That run also included one small orphan-cleanup test, which was excluded from this critical-only report and the attached test file. All eight retained tests failed and reproduced the findings described above.
