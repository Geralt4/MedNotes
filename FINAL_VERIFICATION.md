# Final verification of BUG_AUDIT.md and BUG_FIX_REPORT.md

**Date:** 2026-10-27
**Scope:** the uncommitted working-tree diff (5 files, +34/−6) against `8a1d105`, and the eight audit findings.
**Constraints honoured:** no application code modified, nothing committed or pushed. All builds used derived data under the session scratchpad. All mutation and probe work ran in a private copy of the tree (`…/scratchpad/copy`), never in the repository. `git status` before and after the full test run was identical.

## Overall assessment

**The changes are safe to retain.** The only application-code change (BUG-003) is small, follows the pattern the normal save path already uses, and I verified it independently. The docs change (BUG-007) is correct. The deferred findings were left untouched and I confirm the report's claim that they remain open. I found no regression introduced by the diff, and no finding that was falsely reported as fixed.

Retaining the diff does not make the product safe. **BUG-001 and BUG-002 (both HIGH) are still unfixed.** BUG-004, BUG-005, BUG-006 and BUG-008 are also still open.

## Summary table

| Bug | Audit severity | Reported | My status | Evidence type |
|---|---|---|---|---|
| BUG-001 | HIGH | Deferred | **Confirmed, unfixed** (reproduced) | Executed probe |
| BUG-002 | HIGH | Deferred | **Confirmed by source, unfixed**; likelihood lower than the audit implies | Source only |
| BUG-003 | MEDIUM | Fixed | **Fix verified** | Mutation test and full suite |
| BUG-004 | MEDIUM | Deferred | **Confirmed by source, unfixed** | Source only |
| BUG-005 | MEDIUM | Deferred | **Confirmed by source, unfixed**; scope slightly wider than stated | Source only |
| BUG-006 | MEDIUM | Needs investigation | **Reproduced against the gate's logic; mischaracterised** (environment-dependent, not just stale) | Executed (log and grep) |
| BUG-007 | LOW | Fixed | **Fix verified**, one adjacent doc claim unverifiable | Executed |
| BUG-008 | MEDIUM | Needs investigation | **Not validated** (no measurement) | Source only |

## Verified fixes

### BUG-003 — lock-time patient save omits known attachment IDs — VERIFIED FIXED

**What changed:** `OpenEditorDraft.patient` gains `knownFileIDs: Set<UUID>?`. `PatientDetailView` fills it from `original.files` when it registers the lock callback. `AppSession.saveDrafts` passes it to `patients.save(_, knownFileIDs:)`. The ordinary save path (`PatientDetailView.saveDraft`, `PatientDetailView.swift:143`) computes the identical value.

**Independent evidence:**
1. *Mutation test.* In the private copy I reverted only the lock-flush call to the pre-fix `store.patients.save(patient)`, keeping everything else. `testLockingStalePatientDraftPreservesNewAttachment` **failed with two assertion failures** (`SecurityTests.swift:2337` and `:2339`, the metadata and content checks). With the fix, in the real tree, it **passed**. So the new test does discriminate the bug.
2. *Full suite on the real tree.* `xcodebuild … test` with my own derived-data path: **505 executed, 4 skipped, 0 failures, `** TEST SUCCEEDED **`**. That matches the fix report's numbers.
3. *Guard semantics.* I read `Database.requireCurrentAttachmentReferences` (`Database.swift:620`). It throws `StaleAttachmentError` when the stored rows contain an ID that is in neither `known` nor the draft's own files. `PatientService.save` always passes a non-nil `attachmentReferences` array, even an empty one, so the check runs for the lock path once `knownFileIDs` is supplied. Before the fix `known` was nil, the "unknown row" check was skipped, and `syncPatientFiles` deleted the newer row. The cause and fix match the audit.
4. *Other call sites.* Of all patient-save calls, the remaining ones without known IDs are `newPatient()` (a brand-new record, no stored files), `SampleData`, and `PatientService.setArchived` (`Services.swift:286`), which loads the current record from the database immediately before saving it, so it cannot be stale. Importers and restores pass nil by design. The editor save, the `onDisappear` autosave and the lock flush now all pass known IDs. I found no remaining editor write path that bypasses the guard.
5. *Compile and enum change.* The only other users of `.patient(…)` as an `OpenEditorDraft` are the lock flush and the one existing test, which the diff updates. The build and full suite compile cleanly.

**Not independently validated:**
- The SwiftUI closure in `PatientDetailView.onAppear`. No test drives the real view, so the `original → knownFileIDs` capture is verified by reading and by equivalence to `saveDraft`, not by execution. The fix report says the same, and I agree.
- That the user sees the "edits could not be saved" alert after unlock. The test does not assert `errorMessage`.

**Residual risk (behaviour change, not a defect):** a stale draft that previously "saved" at lock, destroying a newer attachment, is now rejected. The stale field edits are therefore **dropped** at lock and the user gets a generic alert. This is the correct trade-off (silent, irreversible loss of ciphertext versus recoverable text edits), and it matches what the ordinary editor does on a stale save. It is still a behaviour change worth knowing about. The alert text does not say which record was affected.

### BUG-007 — dependency doc points to a nonexistent script — VERIFIED FIXED

- `scripts/scan_dependencies.sh` does not exist and never did (`git log --all` shows no such file). Running it fails: "no such file or directory".
- `python3 scripts/scan_dependencies.py` exits 0 and prints the two pinned packages (sqlcipher.swift and swift-sodium at the documented revisions).
- README and `release.sh` already use the `.py` path, so the doc now agrees with them.

**Unverifiable, left as is:** the same sentence says the scan runs "in CI". The repo has no CI configuration (no `.github`), so that claim is unsupported. It is pre-existing, out of the fix's scope, and harmless. Separately, a stale worktree copy of the old wording exists under a local tooling dot-directory. It is untracked and not part of the product.

## Confirmed but unfixed findings

### BUG-001 — restore validator accepts planted triggers (HIGH) — CONFIRMED, REPRODUCED

I wrote my own probe in the private copy, independent of the audit's. It created a database through `Database.testDatabase`, called `validateExpectedSchema()` (passes), added `CREATE TRIGGER audit_probe_fts_insert AFTER INSERT ON notes BEGIN DELETE FROM patients; END`, and called `validateExpectedSchema()` again. **It did not throw.** After a note insert, the printed patient count was **0** (`PROBE-001 patients after note insert: 0`). The source cause is `BackupService.swift:~23–37`, which checks only `hasSuffix("_fts_insert|delete|update")`.

- The classification is correct. The validator is also reached from `StoreRecovery.swift:112` and from two `validateStagedDatabase` callers, so more than one restore path is affected.
- **Caveat on exploitability:** the attacker must get the user to restore an archive crafted and sealed by the attacker. I did not build a complete sealed archive. HIGH is defensible for a medical-records app, but the real-world precondition is user interaction with an untrusted backup.
- The fix report's decision to defer is reasonable (security-sensitive schema comparison), but it leaves the vulnerability fully open.

### BUG-002 — migration crash between swaps not recovered (HIGH) — CONFIRMED BY SOURCE

- `readJournal()` has **no production caller**. Repo-wide search finds only its definition and one test reference (`SecurityTests.swift:396`). Startup never consults the journal.
- `swapInEncryptedDatabase` and `swapInAttachments` are two separate renames (`StoreMigrator.swift:259–260`). A process kill or power loss between them leaves a mixed store, as the audit says. I did not execute that crash.
- **Corrections to the audit:** (a) The window is two filesystem renames wide, so likelihood is low. The severity is driven by impact (attachments unreachable, plaintext remnants), not frequency. (b) The audit says a throw after a swap is not restored by `rollbackStaging()`. That is only partly right. A failure *inside* the swap block is handled by `restorePlaintextStore()` (`StoreMigrator.swift:330`). `rollbackStaging()` runs only for errors after the swap completed. In `runMigration` the order is `migrate` → `finishCleanup` → `finishMigration` → `AppStore(...)`. `finishCleanup` deletes `Plaintext.old.db` and `Plaintext.old.Attachments`, so a throw from `finishMigration` or the `AppStore` initialiser leaves the encrypted store installed with the plaintext originals already gone, and `rollbackStaging()` then removes the journal. That is a separate, unexamined risk (not executed).
- Deferral is reasonable. This is a design change, and the report's "not reproduced" statement is accurate.

### BUG-004 — restore free-space precheck ignores padding (MEDIUM) — CONFIRMED BY SOURCE

`requireFreeSpace(bytes: archiveSize * 2)` is at `BackupService.swift:~332`. `EncryptedFileStore.store` pads every payload to a 64 KiB boundary, and the zero-byte attachment path still stores. Up to 100,000 records are allowed, so about 5.5–6 GiB of staging output can follow a tiny archive. No large fixture was run (neither by the audit nor by me). Deferral is justified.

### BUG-005 — failed remote delete hidden, item resurrected (MEDIUM) — CONFIRMED BY SOURCE

- `removeTodo` and `removeEvent` delete locally, then call `try? deleteRemote`. The pull path (`AppleRemindersService.swift:~448–469`) turns any marker-owned remote item with no local row into a creation. There is no tombstone or outbox anywhere in the code (searched).
- **Wider than the audit states:** the remote delete is also silently skipped, with no error at all, whenever `state != .granted` or `mayWrite(destination)` is false (`AppSession.swift:~2672–2675, ~2857–2860`). A user who deletes a todo while access is denied or the destination is not writable could see it return on a later sync. I did not execute this.
- No live EventKit failure was induced by anyone. The report's deferral is reasonable.

### BUG-006 — release gate rejects the skip count (MEDIUM) — REPRODUCED, BUT MISCHARACTERISED

- The audit's mechanism is real. I applied the script's exact pattern (`grep -ci '^Test Case .* skipped'`) to my own full-suite log and got **4**, which is greater than the gate's limit of 3. So `scripts/release.sh` would refuse on this machine despite `** TEST SUCCEEDED **`.
- **The audit's framing ("stale numeric threshold") is incomplete.** The skips are environment-dependent. Observed here: the three `CLIDryRunTests` (no compiled CLI or a sandboxed host), plus `ExternalCopiesTests.testATestSessionsLockLeavesTheAppsSwipeLogAlone`, which skips only because the app's swipe log already exists on this Mac. Other tests skip when `NSApp.isActive` or when no Lock menu item is found. On a clean release machine the count could be 3, or higher. The gate is therefore brittle and environment-dependent, and the "three documented CLI-only skips" comment is out of date. It is not simply a wrong constant.
- The fix report's decision not to raise the number is correct. Raising it would hide unexpected skips. I did not run `release.sh` (it needs signing credentials).

### BUG-008 — large backups processed in memory (MEDIUM) — NOT VALIDATED

The source shows whole-file `Data` buffers in snapshot creation, extraction and `EncryptedFileStore.store/read` (verified by reading). Nobody has measured peak memory. It is a plausible resource-exhaustion defect, not a confirmed one, and it stays a "suspected" finding.

## Checks I made for regressions and hidden effects

- **Architectural fit:** the fix reuses the existing `knownFileIDs` mechanism and mirrors `saveDraft`. It adds no new state, no new concurrency primitive and no new persistence.
- **Race conditions:** the lock callback reads `@State` bindings at flush time, exactly as before. The stale-draft check runs inside the save transaction (`Database.savePatient` → `transaction { … }`), so it is atomic with the write. I found no new race.
- **Security implications:** none introduced. The change makes the lock path stricter, not looser.
- **Side effects on other draft types:** note, todo and event cases are untouched.
- **Test-file edit:** the existing test was updated only to supply the new associated value (`knownFileIDs: Set(patient.files.map(\.id))`). Its intent is unchanged.
- **Misclassification / missed bugs in directly affected paths:** none found beyond the extensions noted for BUG-002 and BUG-005. No finding is falsely marked fixed.

## What I could not validate

- The SwiftUI editor closure at runtime (BUG-003): verified by reading only.
- The user-visible alert after a rejected lock flush (BUG-003).
- Any real process-kill crash (BUG-002), live EventKit failure (BUG-005), large-archive or constrained-volume restore (BUG-004), or near-limit memory behaviour (BUG-008).
- `release.sh` end to end (BUG-006), and the "run in CI" claim in `docs/dependencies.md` (BUG-007).

## Recommendation

Keep the diff. Before shipping, address BUG-001 first. It has a concrete, reproduced exploit path and a straightforward fix: compare trigger names and SQL against the trusted schema. Then take BUG-002, and make the release gate (BUG-006) check named expected skips instead of a count.
