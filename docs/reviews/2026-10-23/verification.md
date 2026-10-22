# Verification of the critical fixes — 2026-10-23

The original reproduction cases pass. **One new P1 attachment data-loss regression remains**, reproduced independently against the updated implementation.

Only verification artifacts were added to the workspace. All experiments used synthetic records, temporary roots, and in-memory test keys.

## Remaining P1: saving an older draft deletes both attachment versions

Locations: [Services.swift:57](/Users/giannismanologlou/Documents/MedNotes/MedNotes/Services/Services.swift:57), [Services.swift:110](/Users/giannismanologlou/Documents/MedNotes/MedNotes/Services/Services.swift:110), and [Services.swift:133](/Users/giannismanologlou/Documents/MedNotes/MedNotes/Services/Services.swift:133).

Reproduced through `PatientService.save`:

1. Save a patient with an attachment containing `ORIGINAL`.
2. Load the persisted patient and keep two copies of that draft. Both have metadata referencing storage object A and no inline file bytes.
3. In the first draft, replace the attachment content with `REPLACED` and save. This correctly creates object B, updates the database to B, and removes A. Reading the attachment returns `REPLACED`.
4. In the second, older draft, change only the patient's first name and save. The save returns successfully.
5. Read the patient's attachment again. The database now references deleted object A. The attachment directory is empty: cleanup also deleted B. Reading throws `This file is not an encrypted MedNotes attachment.`

The fresh-ID change fixes the originally reported failed-save overwrite, but metadata-only saves still trust the draft's storage IDs. When an older draft restores the obsolete reference, post-commit cleanup sees the current attachment as unreferenced and deletes it. Both copies of the content are then absent from the live attachment store. This occurs sequentially; no timing race is needed.

**Proposed fix:** Keep storage references under the storage layer's control. A metadata-only patient save should preserve the current attachment version by file ID, or reject the stale draft through a revision check performed in the same database transaction as the update. A true content replacement should continue writing a fresh immutable object. Coordinate reference updates and garbage collection so a successful save cannot commit a reference to a deleted object. Add the reproduction as a regression test, including the assertions that the latest bytes remain readable and the attachment store retains its live object.

Test: [IndependentVerificationTests.swift:18](/Users/giannismanologlou/Documents/MedNotes/docs/reviews/2026-10-23/IndependentVerificationTests.swift:18), `testSavingOlderMetadataDraftDoesNotLoseReplacedAttachment`.

Confirmed failures:

```text
Successful demographic save committed a reference to deleted ciphertext
Saving the older draft deleted both the original and replacement attachment objects
Successful stale-draft save lost the committed attachment:
This file is not an encrypted MedNotes attachment.
```

This is a backend service reproduction, as was the original rejected-save finding.

## Verification results

The full current suite completed with **448 passed, 3 skipped, 0 failed**.

| Original finding | Verification outcome |
| --- | --- |
| Restore points decrypt with a public literal | Fixed in the tested cases: the public literal and unrelated keys fail; the restore key reads the snapshot. Legacy points are resealed and remain readable with the restore key. |
| Multi-file extraction, missing-key recovery, and failed rollback | Original cases pass. Injected late install failure preserves the original records and both attachments. An additional independent test restored and recovered five files, including three empty files and one file larger than a stream chunk, with exact byte comparisons. |
| Pre-migration backup cannot restore | Original case passes. Tests also pass for legacy plaintext attachments, full restore verification, and compatibility with older archives containing plaintext inner snapshots. |
| Legacy import drops inline file bytes | Actual session import passes after locking and reopening. Re-import and failed-batch attachment cleanup tests also pass. |
| Rejected patient save overwrites committed bytes | Duplicate-AMKA rejection now preserves the original file bytes. The new successful stale-draft data-loss case above remains. |

Independent tests in a temporary project: **one passed, one failed**. The failing test was rerun with an explicit assertion that both attachment objects were gone; all three failure assertions reproduced.

Production source in the temporary project was compared with the workspace after testing and matched.

## Rerunning the independent tests

From the project root:

```bash
review_root=$(mktemp -d /private/tmp/mednotes-verification.XXXXXX)
cp -R MedNotes MedNotesTests MedNotes.xcodeproj CLI scripts "$review_root/"
cp docs/reviews/2026-10-23/IndependentVerificationTests.swift "$review_root/MedNotesTests/"
xcodebuild \
  -project "$review_root/MedNotes.xcodeproj" \
  -scheme MedNotes \
  -destination 'platform=macOS' \
  -derivedDataPath "$review_root/DerivedData" \
  -parallel-testing-enabled NO \
  -only-testing:MedNotesTests/IndependentVerificationTests \
  test
```

Expected on the reviewed code: the mixed empty/multi-chunk backup test passes; the older-draft attachment test fails.

Full-suite result: `/private/tmp/MedNotesVerifyBuild/Logs/Test/Test-MedNotes-2026.10.23_01-01-13-+0300.xcresult`.

Independent run: `/private/tmp/MedNotesVerifyBuild/Logs/Test/Test-MedNotes-2026.10.23_01-03-26-+0300.xcresult`.

Failure confirmation log: `/private/tmp/mednotes-verify-stale-draft.log`.
