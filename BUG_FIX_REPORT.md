# Bug fix report

The audit was reviewed against the current source. High-severity findings were left untouched as requested. The prior audit's test results are historical; the checks below distinguish new evidence from the audit's evidence. No commit or push was made.

## Findings

### BUG-001 — Deferred (HIGH)

No files modified for this finding. The schema validator's suffix-based trigger acceptance and its use before restore installation are consistent with the audit. The prior audit's isolated trigger execution probe was not rerun. Exact schema verification is a security-sensitive change reserved for human review; the restore vulnerability remains.

### BUG-002 — Deferred (HIGH)

No files modified for this finding. The reported sequential swaps and missing startup journal recovery warrant human review. The crash boundary was not reproduced in this work; attachment availability and plaintext remnants remain at risk.

### BUG-003 — Fixed

Modified `MedNotes/UI/Notes/OpenEditorDraft.swift`, `MedNotes/UI/Patients/PatientDetailView.swift`, `MedNotes/UI/Notes/AppSession.swift`, and `MedNotesTests/SecurityTests.swift`. The editor now captures its original attachment IDs in the lock draft and the lock flush passes them to the existing stale-draft guard, just as normal saves do.

New test `SecurityTests.testLockingStalePatientDraftPreservesNewAttachment` saves an attachment after capturing a stale patient draft, registers that draft, locks, unlocks, and checks both metadata and contents. Before the fix it failed both assertions; after the fix it passed. When a stale save is rejected, the existing lock error message reports unsaved edits; the attachment survives, but the stale field edit is not merged. The test registers a draft directly rather than driving the SwiftUI editor, so it does not independently test the view's closure at runtime.

### BUG-004 — Deferred (MEDIUM)

No files modified for this finding. Source confirms the restore precheck uses twice the archive size, and encrypted file storage pads even an empty attachment to a 64 KiB block. A large fixture or constrained-volume restore was not run. A safe aggregate preflight needs to account for multiple volumes, snapshot conversion, restore points and installation overhead, as well as archive streaming; changing just the multiplier would be speculative. Disk exhaustion remains possible.

### BUG-005 — Deferred (MEDIUM)

No files modified for this finding. Source confirms local deletion precedes a `try?` remote delete for both integrations, and the audit identifies the pull path that can recreate surviving remote items. No live EventKit failure was induced. Durable retry or tombstone reconciliation requires cross-system state and broader design; merely displaying an error would not prevent resurrection. The issue remains.

### BUG-006 — Requires further investigation (MEDIUM)

No files modified for this finding. The release script rejects more than three log lines matching skipped test cases. The audit reports four skips in its full test run; this would trigger the numeric condition if those four appeared in the script's log format. This run also produced four matching skips: the three CLI tests and `ExternalCopiesTests.testATestSessionsLockLeavesTheAppsSwipeLogAlone`, which skips when the app swipe log already exists. The release command uses a different destination configuration, and the release pipeline was not run. An allowlist must identify which skips and reasons are acceptable in the actual release environment; raising the threshold would hide unexpected skips. The gate remains unchanged.

### BUG-007 — Fixed

Modified `docs/dependencies.md` to specify `python3 scripts/scan_dependencies.py`. The former `.sh` path does not exist; running the replacement from the repository root succeeded and reported the two pinned dependencies.

### BUG-008 — Requires further investigation (MEDIUM)

No files modified for this finding. Source confirms whole snapshot and attachment buffers and large declared limits, but no near-limit memory measurement was made and a safe cap cannot be inferred from these facts alone. Streaming or limits would change supported behavior and require profiling and design. Resource exhaustion remains possible.

## Verification

- Targeted lock regression: failed before the change (missing metadata and data), passed after it.
- `python3 scripts/scan_dependencies.py`: passed.
- `git diff --check`: passed.
- The Xcode test build compiles the app and tests and runs the project's CLI source typecheck. No separate repository lint configuration was found.
- Full suite: `xcodebuild -project MedNotes.xcodeproj -scheme MedNotes -destination "platform=macOS" -derivedDataPath /private/tmp/MedNotesAuditDerivedData -parallel-testing-enabled NO test` succeeded: 505 tests executed, 4 skipped, 0 failures. This includes the existing lock and stale-attachment tests. Log: `/private/tmp/MedNotesFixTests.log`.
- An initial sandboxed Xcode run could not access Swift/Xcode caches; the test was rerun with approved access.

The report itself is a new file, `BUG_FIX_REPORT.md`. The pre-existing untracked `BUG_AUDIT.md` and `.DS_Store` were not modified.
