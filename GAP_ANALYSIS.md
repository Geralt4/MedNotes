# Gap analysis: MedNotes vs the "Obsidian Architecture Reverse-Engineering Report"

Analysis date: 2026-10-27. Code state: commit `8a1d105` plus 11 uncommitted modified files (222 insertions, 39 deletions). Analysis only; no code was changed.

**About the source.** There is no `RESEARCH.md` in the repository. The research is the 34-page PDF *Obsidian Architecture Reverse-Engineering Report* (Downloads folder). It is an architecture recommendation, not a product spec: it describes how Obsidian works, then says what a *medical* reimplementation should copy (the derived-index and link-graph design) and what it should deliberately not copy (file-first persistence, trusted plugins, plaintext at rest, casual merge). I turned it into 69 numbered requirements, R1 to R69 (section 2), each tagged **C** (core: applies to a single-clinician local app) or **X** (extended: multi-user, server or ecosystem). Two items (R27, R67) are Obsidian features the report itself does not want, so they are not scored.

**Evidence labels.** "Verified" means I read the code myself. "Reported" means a reader agent found it while reading and I did not re-check it. Where I could not tell, the text says "unsure".

---

## Update, 2026-10-28: after Phase 1 (link engine v2)

This document is the baseline analysis. Phase 1 of the roadmap (item 4 and parts of items 3 and 5) has since been built; the sections below are left as first written, and this box records what changed. Changed table rows are marked "(Phase 1)".

| Requirement | Baseline | Now | What changed |
|---|---|---|---|
| R13 links extracted by a parser | Conflicts | Done for links | `MedNotes/Support/WikiLinkParser.swift`: hand-written, skips code, comments and escapes; the editor styler reads links from it too. Bold, italic and heading styling in `MarkdownStyler` still use regexes. |
| R15 parse and resolve separate | Partial | Done | `LinkIndex.resolve` (exact normalized key; notes before patients) works on stored `wikilinks` rows. |
| R16 unresolved links first-class | Missing | Done | Unresolved and ambiguous links are stored (`wikilinks.state`) and shown in the note's panel. |
| R17 outgoing/incoming, incremental | Partial | Done | Per-note derivation (`LinkIndex.relink`) plus a cheap global re-resolve after any note or patient change; stale notes found by content hash (`link_sources`). |
| R18 linked and unlinked mentions | Partial | Done | `LinkingService.unlinkedMentions`, skipping code, comments, existing links and partial words. |
| R19 orphans, dead-ends, degree | Missing | Partial | `LinkingService.linkStats`; no screen shows it yet. |
| R21 rename | Partial | Partial | A rename re-resolves every link by text, so old links become unresolved and new ones resolve; the text of other notes is not rewritten (later phase). |

New scores: **Core 42%** (25 / 59: 9 Done, 32 Partial, 16 Missing, 2 Conflicts; was 36%). **Invariants about 56%** (5.0 / 9; was 44%): invariant 1 (derived indexes are rebuilt from the notes, tested by dropping the tables) and invariant 2 (unresolved links are first-class) now score 1. All 67 scored: about 38% (25.5 / 67).

Roadmap items 2 (partly: FTS tag fix not done), 3 (rebuild exists as open-time freshness repair; no explicit command or screen) and 4 are built; items 5 (unlinked mentions and stats built, local graph and panes not), 6 to 15 are not started.

Behaviour changes the owner should know about:
- Links resolve only on an exact title or patient name. The old "unique partial match" is gone; a link such as `[[Ward]]` that used to land on "Ward Rounds" is now unresolved. On the first open after the upgrade a single audit row records, as counts only, how many earlier links no longer resolve.
- A link keeps its target when a second note with the same title is created; only new links see the duplicate, and they are marked ambiguous.
- `note_links` (v2) is no longer read or written. It is kept because dropping a table cannot be undone.
- Verified by the test suite (see section 7). Known gaps carried forward: the two sync-bridge strings in `AppSession.swift:158-159` have no Greek translation (from the uncommitted edits, not from Phase 1).

---

## Update, 2026-10-28 (later): after Phase 2 (metadata layer)

Phase 2 of the roadmap (item 3's rebuild command, the metadata half of item 5, and part of item 9) is built. The Phase 1 box above and the baseline below are left as written.

| Requirement | Before Phase 2 | Now | What changed |
|---|---|---|---|
| R20 per-note metadata: properties, headings, blocks, tags | Partial | Done | `FrontMatterYAML`, `NoteMetadata`, tables `note_properties/note_headings/note_blocks/note_tags/note_aliases` (schema v6), derived with the links. |
| R25 rebuild derived indexes and verify | Partial | Done | `Database.rebuildIndexes()` (Settings › Data › Rebuild Indexes): one transaction, row-count, full-text and foreign-key checks, counts-only audit row. |
| R42 safe read-modify-write of note text | Partial | Done | `FrontMatterEditor` splices only the changed lines; `NoteBodyEditor.editProperty` applies it as one undo step against the live text. |
| R66 typed properties UI | Partial | Done | Inspector › Properties: text, number, checkbox, date, date and time, list; unsupported values read-only. |
| R69 quick switcher, outline, tags pane | Partial | Done | Inspector › Outline, and a Tags menu with counts that filters the notes list. |
| R14 Obsidian syntax | Partial | Partial | Headings, block ids, `#tags`, aliases and `[[Note#Heading]]` checks added; embeds, callouts and `[[Note#^block]]` autocomplete are still not rendered or completed. |
| R29 structured index | Partial | Partial | Properties are now queryable rows; diagnoses and medications are still inside patient JSON. |

New scores: **Core about 47%** (27.5 / 59: 14 Done, 27 Partial, 16 Missing, 2 Conflicts; was 42%). **Invariants unchanged at about 56%.** All 67 scored: about 42%.

Behaviour changes worth knowing:
- Two `---` rules around prose are text everywhere now (preview, list, editor, index); only a block whose lines read as properties is front matter. `...` never closes front matter.
- `[[Plan #2|see]]` now resolves to the note titled "Plan #2" (the alias used to defeat it).
- A `#tag` is `#` at the start of a line or after whitespace followed by letters (any script), digits, `_`, `-`, `/`, with a non-digit; clinical shorthand such as `#NOF` or `bed #3B` indexes as a tag, as in Obsidian.
- Every note is derived again once on the first open after the upgrade (hash and parse; note content untouched). Derivation version is now 3.
- The inspector is a plain column beside the editor, not the system `.inspector`: the system one re-laid out its content at moments that wiped a half-typed accent (`NoteEditorUndoTests`).

Known limits: a `#` inside a quoted flow-list item in front matter makes that entry read-only; an uncommitted property value is lost if the app locks mid-edit; the SwiftUI focus and submit events that commit a property field do not run in the inactive test host, so that one wiring (field to commit) is covered by no test and **has not been checked in a running app yet**. What it decides (`PropertyCommit`), which note it may touch (`PropertyEditRouting`) and the text-view edit itself (`NoteBodyEditor.editProperty`, one undo step) are tested. Only the light appearance of the note view was looked at (off-screen render); dark mode was not verified. A clinical line such as `Note: patient stable` between two `---` lines reads as a property, as in Obsidian. The Links section is open by default, so the unlinked-mentions scan runs a moment after each note selection settles; it is the first thing to make lazy if the notes list grows.

---

## 1. Summary

MedNotes is a native SwiftUI macOS app with a SQLCipher-encrypted SQLite store, FTS5 search, a UUID-keyed `note_links` edge table, a force-directed graph and a good security shell (Keychain-held key, lock and privacy curtain, encrypted attachments and backups, sandbox). That is the "Obsidian-like UX on a local transactional store" half of the report, and on encryption and sandboxing it is ahead of what the report asks for.

It is much further from the report's *clinical-record* half: there are no note revisions, no draft/review/signed lifecycle, no immutable attestation, no encounters, no typed relations, no provenance, no hash-chained or append-enforced audit, no per-record authorization, and no FHIR mapping. The link engine is regex-based, drops unresolved links, and resolves by fuzzy title match at save time.

| Measure | Score | Reasoning |
|---|---|---|
| **The report's ten architectural invariants (pp. 30 to 31)**, 9 scored | **about 44%** (4.0 / 9) | The report's own weighting. Details below. |
| Core requirements (59 scored) | **about 36%** (21 / 59) | Done = 1, Partial = 0.5, Missing and Conflicts = 0. 4 Done, 34 Partial, 18 Missing, 3 Conflicts. |
| Extended requirements (8) | about 6% (0.5 / 8) | Only a Canvas graph renderer. Multi-user, server, FHIR and plugins are absent. |
| All 67 scored | about 32% (21.5 / 67) | Dominated by the Extended items MedNotes does not pursue. |

**Headline: roughly 35 to 45% of the way to the report's target architecture.** If the target is "a single-clinician encrypted notebook with a link graph", the Core figure is the fair one, and most of the missing 64% is the signed-revision and audit-integrity cluster (R6 to R9, R47 to R51), not the Obsidian-style features.

Invariant scoring (report pp. 30 to 31):

| # | Invariant | Score | Why |
|---|---|---|---|
| 1 | Canonical content and derived indexes separate | 0.5 | FTS tables and `note_links` are derived and trigger- or save-maintained, but there is no rebuild routine and the FTS `tags` column indexes raw JSON text (`Schema.swift:189`). |
| 2 | Parsing and resolution separate; unresolved links first-class | 0.5 | `extractAnchors` and `resolve` are separate pure functions, but unresolved links are discarded (`LinkingService.swift:231`). |
| 3 | Outgoing links and backlinks are two views of one model | 1 | `note_links` with `backlinksForNote` and `linksFromNote` (`LinkingService.swift:333, 350`). |
| 4 | Graph visualization is a projection, never canonical | 1 | `GraphData` is built on demand (`buildGraph`, `:369`) and laid out by a pure `GraphLayout`. |
| 5 | Editor rendering is viewport/incremental | 0 | The whole body is restyled on change and left unstyled above 60,000 UTF-16 units (reported, `NoteBodyEditor.swift:209, 215`). |
| 6 | Human text and machine-readable clinical meaning coexist | 0.5 | Rich structured patient fields exist; notes carry no typed meaning. |
| 7 | Signed clinical records are immutable revisions | 0 | No revisions, no signing. |
| 8 | Authorization before search, graph, backlinks leave the service layer | 0 | Only the lock gate (`canUseStore`). |
| 9 | Plugins capability-constrained | n/a | No plugin system, so nothing unsafe either. Not scored. |
| 10 | Audit is an independent append-oriented subsystem | 0.5 | Separate in-DB `audit_logs` plus a privacy-safe `SecurityLog`, but not append-enforced, no hash chain, user id is always `"system"`. |

---

## 2. Requirements checklist

Scope: C = core, X = extended. Status: Done / Partial / Missing / Conflicts. Paths are relative to the repo root; `MedNotes/` is the app folder.

### A. Storage and data model

| ID | Requirement (report page) | Scope | Status | Evidence | Notes |
|---|---|---|---|---|---|
| R1 | Canonical store separate from derived indexes; deleting an index never destroys the record (p6) | C | Partial | `MedNotes/Storage/Schema.swift:146-204` (FTS tables + triggers); `:213` (`note_links`) | Indexes are derived, but there is no "drop and rebuild" routine; only a one-time `patients_fts` rebuild (`Database.swift:428-480`, reported). No test deletes an index and rebuilds it. |
| R2 | Transactional structured SQLite store as canonical record, not Markdown/YAML (p1, p24) | C | Partial | `Database.swift:49-93` (SQLCipher, WAL, pragmas); `Schema.swift:17-45` | Notes, todos and events are columns, but a patient's clinical sub-records are JSON blobs (`medical_json`, `visits_json`, `hospitalizations_json`, `alerts_json` ...), which limits querying and referential integrity. |
| R3 | Stable immutable UUID identity independent of path/title (p10, p19) | C | Partial | `Schema.swift:18, 54, 213-220` (UUID text primary keys; edges keyed by UUID) | Identity is stable. But link *resolution* is by title text (`LinkingService.swift:191-211`). Reported: nested records fall back to a fresh `UUID()` on decode (`Patient.swift:252, 823`). |
| R4 | Entities: Patient, Encounter, ClinicalNote, NoteRevision, Edge, Attachment, AuditEvent, Provenance (p19-20) | C | Partial | `Schema.swift` tables: `patients`, `notes`, `patient_files`, `audit_logs`, `note_links` | Present: Patient, Note, Attachment, audit rows, Edge. Absent: Encounter table, NoteRevision, Provenance. |
| R5 | Encounter entity linked to a patient (p20) | C | Partial | `Schema.swift:35` (`visits_json`), `:91-107` (`calendar_events.patient_id`, `event_type`) | Visits are embedded JSON inside the patient; calendar events link to a patient. No Encounter entity that notes can attach to. |
| R6 | Note revisions: number, author, created_at, content hash, predecessor (p20) | C | Missing | `MedNotes/Models/Core.swift:3-12`; `Schema.swift:53-62` | `notes` holds only the current content. `NoteService.save` just stamps `updatedAt` (`Services.swift:306-326`). |
| R7 | Lifecycle draft → review → signed (p16-17) | C | Missing | `Core.swift:3-12` (no status field) | Searched for status/lifecycle on Note; none. |
| R8 | Signed revisions immutable; corrections as new revision/addendum (p17, p23) | C | Missing | n/a | No immutability enforcement anywhere in the schema or services. |
| R9 | Signed revision records hash, signer, signedAt, signature, snapshot (p23) | C | Missing | n/a | Nothing. |
| R10 | Attachments as files with metadata, checksum, encryption (p20, p28) | C | Partial | `Schema.swift:118-130` (`patient_files`); `MedNotes/Storage/EncryptedFileStore.swift` (reported: XChaCha20-Poly1305 secretstream, opaque IDs); `docs/security.md:12` | Encrypted and checksummed. Reported: digest is BLAKE2b, not SHA-256, and no MIME type column. Attachments belong to patients, not notes. |
| R11 | Markdown text and typed clinical entities coexist (p21) | C | Partial | `Core.swift:3-12` (`mentionedPatients`, `tags`); `note_links` | Notes link to patients and notes; there is no typed clinical meaning in note text (see R22/R23). |
| R12 | WAL journaling (p24) | C | Done | `MedNotes/Storage/Database.swift:79, 82` (`PRAGMA journal_mode = WAL`) | Verified. Note: `rekey` temporarily switches to DELETE mode (`:259`). |

### B. Parsing, links, indexes

| ID | Requirement | Scope | Status | Evidence | Notes |
|---|---|---|---|---|---|
| R13 | Links extracted by a real parser/AST, not regex (p9) (Phase 1) | C | Conflicts | `MedNotes/Services/LinkingService.swift:51` (`NSRegularExpression`); `MedNotes/UI/Notes/MarkdownStyler.swift:73-80` (regex); `MedNotes/UI/Markdown/MarkdownPreview.swift:38` (hand parser) | Verified. The report names regex extraction as the thing to avoid (code blocks, escapes). Links inside code fences would still be extracted. |
| R14 | Obsidian syntax: `[[ ]]`, `#heading`, `#^block`, `![[ ]]`, tags, `%% %%`, callouts, tasks, aliases (p5) | C | Partial | `LinkingService.swift:51`; `MarkdownStyler.swift:73-80`; `MarkdownPreview.swift:91-101` | Supported: `[[wikilink]]`, headings, bold, italic, checklists, front matter. Not supported: heading/block targets, embeds, `%%` comments, callouts, `[[a\|alias]]`. |
| R15 | Parse and resolve are separate; stored edge points at UUID (p9, p21) (Phase 1) | C | Partial | `LinkingService.swift:50` (extract), `:191` (resolve), `:224-238` (`relink`) | Separate pure functions and UUID edges. But resolution is fuzzy: exact title, then a unique *contains* match, notes before patients, first match wins on duplicate titles (`:196-209`). |
| R16 | Unresolved links first-class (p9, p31) (Phase 1) | C | Missing | `LinkingService.swift:231` (`else { continue }`); `Schema.swift:213-220` (no slot) | Verified. Unresolved `[[X]]` is dropped and nothing is stored. (`Database.swift:338-343` deletes edges with both targets NULL, but its comment says that is cleanup after a patient is deleted, not unresolved-link removal.) |
| R17 | Outgoing/incoming indexes as two views of one model; incremental per-note update (p9-10) (Phase 1) | C | Partial | `Schema.swift:222-224` (indexes); `LinkingService.swift:289-331` (`replaceLinks` diffs one note's edges) | Verified. `relink` is called only from `NoteService.save` (`Services.swift:315`). So a link to a note created *later*, or one whose title changes, is not resolved until the source note is saved again. Each relink reads every note title (`:226`). |
| R18 | Backlinks: linked and unlinked mentions (p10) (Phase 1) | C | Partial | `MedNotes/UI/Notes/NoteDetailView.swift:237, 279`; `AppSession.swift:3334` | Linked backlinks shown. No unlinked-mention search. |
| R19 | Orphans, dead-ends, degree queries (p10-11) (Phase 1) | C | Missing | n/a | A repository search for orphan/degree logic found none (only unrelated "orphan attachment" sweeps). |
| R20 | Per-note metadata: properties, headings with offsets, blocks, links, tags (p8-9) | C | Partial | `MarkdownStyler.swift:51` (front matter span); `notes.tags_json` | Front matter is styled and previewed but not parsed into properties. No heading/block index. Tags are a JSON array column, not extracted from `#tags` in text. |
| R21 | Rename handling: update mapping, optionally rewrite text (p10) (Phase 1) | C | Partial | `Schema.swift:215-217` (edges by UUID) | A rename does not break stored edges. Text is never rewritten, and an unresolved or fuzzy link is not re-resolved (see R17). |
| R22 | Typed relations (mentions, diagnosed-with, prescribed ...) (p22) | C | Missing | `Schema.swift:213-220` (no relation column) | Edges are untyped; targets are only note or patient (`LinkingService.swift:8-11`). |
| R23 | Typed link syntax `[[condition:AF\|text]]` (p21) | C | Missing | n/a | Not parsed. |
| R24 | Incremental indexing driven by a revision/event number (p24-25) | C | Missing | n/a | Only `updated_at` timestamps. |
| R25 | Full rebuild of derived indexes plus verification checks (p25) | C | Partial | `Database.swift:499-521` (`integrityCheck`, foreign-key check); `Settings › Data` "Check Now" | Integrity and FK verification exist; rebuilding derived data does not. |
| R26 | Event-driven invalidation / in-process event bus (p13, p24) | C | Partial | `AppSession.swift` epoch counters (reported: lines 180, 189, 232, 246) | Manual epoch counters and notifications, not a bus. |
| R27 | External file edits observed and re-indexed (Obsidian behaviour; p4) | C | N/A, intentional | `docs/adr/0002-encrypted-store.md` (vault mirror retired); no file watcher in the code | The report itself says not to copy file-first persistence. Retiring the mirror is alignment, not a gap. Not scored. |

### C. Search

| ID | Requirement | Scope | Status | Evidence | Notes |
|---|---|---|---|---|---|
| R28 | FTS5 with BM25 ranking, snippets, prefix/phrase (p12, p28) | C | Partial | `Schema.swift:146-204, 288-294`; `Database.swift:1269-1307` | Verified. FTS5 with prefix `MATCH` and triggers. No `bm25()`, no snippets; results ordered by pinned and recency. Tokens are AND-ed prefix terms; no phrase or NEAR. |
| R29 | Structured index: patient, encounter, author, date, type, diagnoses, medications, status (p12) | C | Partial | `Schema.swift:47-51, 85-89, 104-107` | Indexes on patient name, DOB, archived, dates, priority. Diagnoses and medications sit inside JSON blobs and cannot be queried. |
| R30 | Graph index as a third independent index (p12) | C | Partial | `LinkingService.swift:369-418` | The graph is built on demand from tables on each load, not kept as its own index. Acceptable at current scale. |
| R31 | Search operators (file/path/tag/line/block/section/task/property) (p11) | C | Missing | `Schema.swift:296-303` | Plain tokens only. |
| R32 | Authorization applied before search results/snippets/counts leave the service layer (p25, p31) | C | Missing | `Services.swift:263-267, 351-356` | No policy layer. The only gate is "store unlocked" (`AppSession.canUseStore`). |

### D. Graph

| ID | Requirement | Scope | Status | Evidence | Notes |
|---|---|---|---|---|---|
| R33 | Force-directed graph, local depth, attraction/repulsion/distance controls (p11) | C | Partial | `MedNotes/UI/Graph/GraphLayout.swift:18-163`; `GraphView.swift:26-62` (reported) | Verified layout. Zoom, pan, hover focus. No local-graph/depth view and no force controls. |
| R34 | Graph is a projection (visible nodes/edges → layout → renderer), separate from canonical edges (p11, p31) | C | Done | `GraphLayout.swift:13-15`; `LinkingService.swift:33-36`; `MedNotesTests/GraphLayoutTests.swift` | Verified: pure deterministic layout, run off the main actor. |
| R35 | Graph privacy: hidden nodes, degree, labels must not leak (p25) | C | Conflicts | `LinkingService.swift:379-385` (all patients, archived too, names as labels); `GraphView.swift:289-290` (patient labels always drawn) | Verified. No filter or authorization on the graph. Reported: events titles are also labels. |
| R36 | Large-graph renderer (WebGL/Pixi) (p27) | X | Partial | `GraphView.swift:134-135` (SwiftUI Canvas, reported); `GraphLayout.swift:44, 96-123` | Canvas with grid-bucketed repulsion; test lays out 3,000+ nodes in under 2 s (`GraphLayoutTests.swift`). |

### E. Editor and rendering

| ID | Requirement | Scope | Status | Evidence | Notes |
|---|---|---|---|---|---|
| R37 | Source editor with incremental parser; Live Preview via decorations over retained source (p7) | C | Partial | `MarkdownStyler.swift`; `NoteBodyEditor.swift:162-278` (reported) | Attribute styling over the real Markdown text in an `NSTextView`. Markers stay visible (no hiding or widgets). |
| R38 | Viewport-local rendering for large documents (p7, p31) | C | Missing | `NoteBodyEditor.swift:209, 215` (reported) | Whole body is restyled on change; above 60,000 UTF-16 units it is left unstyled. |
| R39 | Reading View: AST → sanitized output, code highlighting, post-processors (p8, p26) | C | Partial | `MarkdownPreview.swift:38-111, 193-201` | Verified. Hand-written block parser plus `AttributedString(markdown:)` inline. No tables, ordered lists, blockquotes, code highlighting, or clickable `[[links]]`; headings only levels 1 to 4 while the styler styles 1 to 6 (`:115` vs `MarkdownStyler.swift:73`). |
| R40 | Transactional editor state, separate from the UI framework (p14) | C | Partial | `NoteBodyEditor.swift:125-130, 144` (reported); `MedNotesTests/NoteEditorUndoTests.swift` | Undo works and is well tested, but is tied to AppKit's `NSTextView` undo manager. |
| R41 | Conformance corpus: source ↔ AST ↔ editor ↔ rendered (p26-27) | C | Partial | `MarkdownStylerTests.swift` (9 tests); `DisplayCopyTests.swift`; `ObsidianCoreTests.swift:383-440` | Unit tests per component; no single corpus run against all representations. |
| R42 | Safe read-modify-write for background changes (p13) | C | Partial | `MedNotes/UI/Patients/PatientDetailView.swift:140-144`; `Database.swift:530-556` (transactions) | Stale-draft attachment guard and `BEGIN IMMEDIATE` transactions. No Vault.process analogue. One reviewed P1 (stale metadata draft) is recorded as still open in `docs/reviews/2026-10-23/verification.md`; the uncommitted diff touches this path. |
| R43 | Deferred/lazy view loading (p14) | C | Partial | Detail views load by selection (reported) | Unsure beyond that. |

### F. Security and audit

| ID | Requirement | Scope | Status | Evidence | Notes |
|---|---|---|---|---|---|
| R44 | Local data-at-rest encryption, not relying on OS disk encryption (p16) | C | Done | `Database.swift:58-63`; `SQLConnection.swift:188-246`; `EncryptedFileStore.swift`; `Support/KeyManager.swift`; `docs/security.md:9-23`; `SecurityTests.swift:42-195` | SQLCipher, authenticated attachments, Keychain key with user presence. Caveat (verified): `SecureStoreCoordinator.lock()` sets key fields to `nil` (`:239-243`); the doc comment says "wipes" but nothing is zeroed, and `Database` keeps its key for the actor's life (`Database.swift:25`). |
| R45 | Authentication of user/service identity (p18) | C | Partial | `KeyManager.swift:110-116` (`.userPresence`); `SecureStoreCoordinator.swift:148-187` | A device-presence gate (Touch ID or password). No user identity. |
| R46 | RBAC + ABAC; effective permission = user ∩ plugin ∩ resource (p15, p18) | X | Missing | n/a | Single-user app. |
| R47 | Append-only AuditEvent subsystem, independent of app logging; who/what/where/when/why (p19, p31) | C | Partial | `Schema.swift:132-144`; `Database.swift:1545-1561`; `Services.swift:3-18`; `MedNotes/Support/SecurityLog.swift` | Verified. Separate in-DB audit table (writes go through `AuditService`) and a separate privacy-safe system log: both match the report's separation. But no trigger blocks `UPDATE` or `DELETE` on `audit_logs`, `userId` is only ever `"system"` (`Core.swift:289`; no other use), and "why" is a free-text `details`. |
| R48 | Audit reads of sensitive data (p19) | C | Missing | `Services.swift:216-245, 255-293` (reported) | Loads, searches and external opens of attachments are not audited. (`SecurityLog` records an external-open event in the system log only.) |
| R49 | Tamper-evident hash chain, anchored by a protected key (p23-24) | C | Missing | `Schema.swift:132-144` | No hash column or chain. |
| R50 | Provenance: how each artifact/revision was created, revised, signed (p19, p22) | C | Missing | n/a | Only the audit row's free-text detail. |
| R51 | Authorization enforced in the service layer, not only UI (p25) | C | Missing | `AppSession.canUseStore` | Lock gate only. |
| R52 | HIPAA Security Rule safeguards; 6-year documentation retention (p18) | C | Partial | `docs/security.md`; `docs/adr/0002-encrypted-store.md` | Encryption, audit, integrity checks, lock. No HIPAA mapping, no retention policy (restore points are pruned to five). See open questions on jurisdiction. |
| R53 | Isolation/hardening guidance (sandbox, CSP-equivalent) (p15) | C | Done | `MedNotes/MedNotes.entitlements`; `scripts/verify_entitlements.py`; `MedNotes.xcodeproj/project.pbxproj` (`ENABLE_HARDENED_RUNTIME = YES`); `MedNotesTests/EntitlementsTests.swift` | Sandbox on, no network-client entitlement, allowlist checked at release. |

### G. Sync and collaboration

| ID | Requirement | Scope | Status | Evidence | Notes |
|---|---|---|---|---|---|
| R54 | Multi-device sync via operation/revision log with optimistic concurrency (p28) | C | Missing | `Schema.swift:253-286` (`sync_destinations`, `sync_object_map`) | The only sync is a bridge to Apple Calendar and Reminders. No operation log; no version column. |
| R55 | Do not silently text-merge attested facts; explicit conflict resolution (p16-17) | C | Conflicts | `MedNotes/Services/AppleCalendarService.swift:25-53`; `AppleRemindersService.swift:69-107` | Remote-wins overwrite on conflict, flagged but not resolved by the user (`RemindersSyncTests.swift:66-77` pins this). This applies to todos and events, not clinical records; there are no attested records to merge yet. Both statements are true. |
| R56 | CRDT only for unsigned draft prose (p17-18) | X | Missing | n/a | Not applicable until there is collaboration. |
| R57 | End-to-end encrypted sync transport (p16) | C | Missing | `docs/security.md:95-96` | MedNotes has no sync transport of its own (no network entitlement). Data that goes to Calendar/Reminders is governed by that account. |
| R58 | Central PostgreSQL for multi-user (p28) | X | Missing | n/a | By design: local-only. |

### H. Interoperability

| ID | Requirement | Scope | Status | Evidence | Notes |
|---|---|---|---|---|---|
| R59 | FHIR mapping layer (Composition, Condition, Observation, MedicationRequest, Provenance, AuditEvent) (p22-23) | X | Missing | n/a | None. |
| R60 | Standards-based import/export possible via stable entities (p23) | C | Partial | `MedNotes/Import/JSONImporter.swift`; `Services/MarkdownExportService.swift`; `Services/BackupService.swift` | JSON import, one-time Markdown export, encrypted backups. No standard interchange format. |

### I. Extensibility

| ID | Requirement | Scope | Status | Evidence | Notes |
|---|---|---|---|---|---|
| R61 | Capability-based plugin sandbox (p14-15) | X | Missing | n/a | No plugin system. The report says *not* to copy Obsidian's trusted in-process model, so there is nothing unsafe here either. |
| R62 | Plugin manifest with declared permissions (p12-13, 15) | X | Missing | n/a | As above. |
| R63 | Stable public app object model with events/commands (p12-13) | X | Missing | n/a | No public API. |

### J. Architecture and UX

| ID | Requirement | Scope | Status | Evidence | Notes |
|---|---|---|---|---|---|
| R64 | Layered architecture: UI → services (Note/Entity/Search/Graph/Auth) → parser/resolver/FTS/policy → canonical store → audit/sync → encrypted storage (p30) | C | Partial | `MedNotes/Services/AppStore.swift`; `Services/Services.swift`; `UI/Notes/AppSession.swift` (3,602 lines) | Actor services over a `Database` actor exist. But `AppSession` is a ~20-responsibility god object that drives stores, sync, backups, locking and navigation directly, and there is no policy/auth layer. |
| R65 | Workspace with panes/leaves/views (p14) | C | Partial | `MedNotes/ContentView.swift:122-145`; `UI/Sidebar/SidebarView.swift` | Sidebar → list → detail. Fixed modules, not panes. |
| R66 | Typed properties UI (text, list, number, checkbox, date, tags, aliases) (p5) | C | Partial | `PatientEditorForm.swift`; `TodoEditorForm.swift`; `Components.swift:553` (`TagEditor`) | Typed fields exist for patients, todos and events; notes only have tags, and front matter is shown raw. |
| R67 | Canvas and Bases views (p5, p13) | C | N/A | n/a | Obsidian features the report does not require. Not scored. |
| R68 | Attachments linked from notes; rename/delete repairs links (p29) | C | Partial | `Services.swift:179-214`; `EncryptedFileStore.swift:246-262` | Attachment lifecycle is carefully managed (orphan sweep, delete with patient), but attachments belong to patients and notes cannot embed or link them. |
| R69 | Quick switcher / outline / tags pane (p1) | C | Partial | `UI/Notes/QuickSwitcherView.swift`; `MedNotesApp.swift:91-95`; `SessionFlowTests.swift:256` | Quick switcher (⌘O) is done. No outline or tags pane. |

---

## 3. Built but not in the research

All confirmed by reading; none of these is mentioned in the report.

- **Security shell beyond the report**: idle/screen/sleep lock, privacy curtain and focus parking (`UI/PrivacyCover.swift`, `UI/FocusParking.swift`, `AppSession.swift:437-765`), save-on-lock of open editors (`OpenEditorDraft.swift`), Keychain recovery flow (`Storage/StoreRecovery.swift`), crash-safe plaintext-to-encrypted migration with journal (`Storage/StoreMigrator.swift`).
- **Backups**: Argon2id v2 archives, device-key restore points, legacy v1 reader, passphrase policy and clipboard clearing (`Services/BackupService.swift`, `Support/BackupArchiveV2.swift`, `LegacyBackupReader.swift`, `BackupPassphrasePolicy.swift`).
- **Apple Calendar and Reminders two-way sync** with consent-gated destinations and a wizard (`Services/Apple*Service.swift`, `SyncDestination*.swift`, `UI/Sync/`).
- **Greek clinical domain**: AMKA validation (`Support/AMKA.swift`), father's-name FTS, Greek localization and the `scripts/check_l10n.py` gate.
- **Clinical record breadth**: conditions, allergies, medications, vitals, procedures, hospitalizations, insurance, emergency contact (`Models/Patient.swift`, `UI/Patients/`).
- **Todos and calendar events** as first-class modules; note templates (SOAP, admission, discharge); pinning; patient archive.
- **Tooling**: dry-run import CLI (`CLI/main.swift`), offscreen render harness (`scripts/render_*.swift`), release pipeline with notarization (`scripts/release.sh`), swipe-to-delete gesture (`UI/Theme/SwipeActions.swift`).
- **Review artifacts**: `docs/reviews/`, and the untracked `BUG_AUDIT.md`, `BUG_FIX_REPORT.md`, `FINAL_VERIFICATION.md`.

---

## 4. Architecture fit

**What can carry the plan as is**
- *Store*: SQLCipher SQLite with WAL, FTS5 and a UUID edge table matches the report's recommended local store. Adding tables (revisions, encounters, provenance, relations) is a normal schema migration; the migration framework (`Database.migrate`, schema version 4) and its tests exist.
- *Derived-index pattern*: the FTS triggers and `note_links` are already "authoritative + derived". Adding a rebuild-and-verify routine is additive.
- *Graph*: layout is already a pure projection with tests, so adding filters or a local-depth view needs no redesign.
- *Security shell*: keys, lock, sandbox, backups. Hash-chaining the audit log can reuse `KeyManager`'s subkey derivation (`Support/KeyManager.swift:52-75`).

**What needs rework**
- *Link engine*: replace regex extraction with a real parser; add a schema slot for unresolved and typed edges (`raw_target`, nullable destination, `relation_type`, source span); move resolution to a resolver that can also run on note create, rename and delete. This is a rewrite of `LinkingService` plus a migration, not a patch.
- *Notes as revisions*: today `notes` is one mutable row. Revisions, lifecycle and signing mean a `note_revisions` table and a change to what "save" means. This touches `NoteService`, `AppSession`, the editor's save/revert flow, backups, the Markdown exporter and the importer.
- *Patient data model*: clinical facts in JSON blobs cannot be indexed, linked as typed entities or given provenance. Diagnoses and medications need to become rows if the report's structured index and typed relations are wanted.
- *Authorization and identity*: nothing exists between UI and `Database`. Even for one user, the report's "policy before results" and a real author identity (needed for signing and audit) need a service-layer gate.
- *`AppSession`*: 3,602 lines mixing locking, sync, backups, import/export, navigation and graph. Every item above routes through it; splitting it first lowers the cost of the rest.

**Stack note.** The report is stack-agnostic and even lists SwiftUI among acceptable UI frameworks (p14), so native Swift is compatible. Its Electron, Yjs, PostgreSQL and plugin-RPC advice is for a multi-user web product and would not fit this app without a change of product scope.

---

## 5. Risks and blockers

**Structural (will slow the remaining work)**
1. **God object** `AppSession.swift` (3,602 lines, verified). Reader-reported duplicated reload sequences across save/delete/archive paths.
2. **Link resolution at save time only** (verified; addressed in Phase 1: links are re-resolved after any note or patient change and repaired on open): `relink` has one caller, `NoteService.save` (`Services.swift:315`). Notes imported, created before their target, or whose targets are renamed keep stale or missing edges until re-saved.
3. **Fuzzy title resolution** (verified; removed in Phase 1: `LinkingService.swift:196-209`): "unique contains match" can silently link `[[Ward]]` to a single note titled "Ward Rounds"; duplicate titles resolve to the first row. For a medical app this is a patient-safety style risk once links carry clinical meaning.
4. **JSON blobs for clinical sub-records** (verified, `Schema.swift:33-41`), which blocks structured queries and typed links.
5. **Graph leaks by design** (verified): all patients, including archived, appear with names as labels.
6. **Audit is not tamper-evident** (verified): no triggers, no chain, `userId = "system"`. Reported: migration copies only the newest 100,000 audit rows (`StoreMigrator.swift:221`) and legacy restore does the same (`BackupService.swift:811`), silently dropping older history.

**State of the working tree and the review reports**
7. **The three untracked audit reports describe an older state than the working tree.** I did not run any tests, so I cannot say these are fixed, but two findings look addressed in the uncommitted diff (`StoreMigrator.swift`, `AppSession.swift` and `scripts/release.sh` are among the 11 modified files):
   - *BUG-002* says `readJournal()` has no production caller. In the current tree `recoverInterruptedMigration()` calls it (`StoreMigrator.swift:117`) and is invoked from `AppSession.swift:1935` and `:2055`. Whether the crash window between swaps is closed is not established by this.
   - *BUG-006* describes a `SKIPPED > 3` count gate. The current `scripts/release.sh:68-77` uses an allowlist of three named CLI tests.
   - `BUG_FIX_REPORT.md` and `FINAL_VERIFICATION.md` list a 5-file diff; the tree shows 11 modified files. The other six have no report entry.
   - Test counts disagree between the three reports (504 passed vs 505 executed). Nothing was run for this analysis.
8. **Open reviewed P1** (reported): `docs/reviews/2026-10-23/verification.md` lists a stale metadata-draft save that can delete attachment objects as still open; `IndependentVerificationTests.swift` is expected to fail. The uncommitted `PatientDetailView.swift` change touches the same area; its status is unknown.
9. **Docs overclaim the migration journal** (reported by the docs reader, partly overtaken by point 7): ADR 0002 and the README say interrupted migration resumes or reverses; `FINAL_VERIFICATION.md` says a kill between swaps leaves a mixed store. ADR 0001 still says "accepted" though ADR 0002 supersedes it. Both ADRs and `scan_dependencies.py` mention CI; no CI configuration exists in the repo.

**Security and correctness details**
10. Key "wipe" only nils fields (verified, `SecureStoreCoordinator.swift:239-243`); the database key lives for the actor's life.
11. Remote-wins conflict handling in both Apple bridges overwrites unsynced local edits (verified `AppleCalendarService.swift:25-53`; flagged, not user-resolved).
12. A failed restore's error text may be cleared by the lock that follows it: `performRestore` sets `errorMessage`, then `lockNow` calls `dismissRecordUI`, which sets `errorMessage = nil` (`AppSession.swift:1700-1701`, `:1000`). Likely, unconfirmed.
13. `BackupService.validateExpectedSchema` trusts triggers from `Schema.v1` only (`BackupService.swift:26-31`). Not a current defect: `Schema.v2` and `v4` define no triggers (verified). It will reject a legitimate trigger the day one is added.
14. FTS `tags` column indexes the raw JSON text of `tags_json` (verified, `Schema.swift:189`), so a search for `backup` matches the brackets and quotes too.

**Reported by readers, not re-verified**
- Plaintext staging DB and plaintext attachment writes possible in the CLI importer (`CLI/main.swift:86-97`; `JSONImporter.swift:46-51`); the live-import mode is unreachable (`CLI/main.swift:50`).
- `KeychainKeyManager.add` sets `kSecAttrAccessControl` from an optional; if creation returns nil the item may be stored without access control (`KeyManager.swift:110-116, 158`). I read the code but did not test the nil path.
- Lossy Reminders priority round trip (`AppleRemindersService.swift:124-130, 397-399`).
- Whole snapshots and legacy archives are held in memory (`BackupArchiveV2.swift:309`, `LegacyBackupReader.swift:114`); BUG-008 (suspected) is the same concern.
- Several silent `try?` fallbacks (`Services.swift:198, 205`; `EncryptedFileStore.swift:166, 226, 235`; `TemplatesSettingsPane.swift:140`; `BackupService.swift:272, 814-817`).
- `AMKA` shown unmasked in list rows (`PatientRowView.swift:56`).
- Test suite: weak catch-all assertions (`catch { XCTAssertTrue(true) }` in `BackendFixTests.swift` at 7 sites), sleep- and wall-clock-based tests, the CLI tests skip under the sandboxed host, and no test pins audit immutability, unlinked mentions, rebuild-from-canonical or graph privacy.

---

## 6. Prioritized roadmap

Sizes: S ≈ days, M ≈ 1 to 2 weeks, L ≈ several weeks. Order follows dependencies: foundations first, then the link engine, then the clinical-record cluster.

| # | Item | Size | Depends on | Closes |
|---|---|---|---|---|
| 1 | **Settle the working tree**: review the 11-file diff, run the suite, update or retire the three untracked reports and the ADR 0001 status; decide the open P1 | S | none | Risks 7 to 9 |
| 2 | **Quick wins on the graph and index**: filter archived patients and make patient labels opt-in; fix the FTS `tags` column to index tag text; add `bm25()` ordering and snippets | S | none | R35, R28, risk 14 |
| 3 | **Derived-index rebuild and verify** command (drop and rebuild FTS + `note_links` from `notes`, compare counts) with tests | S to M | none | R1, R24 (part), R25 |
| 4 | **Link engine v2**: parser-based extraction (code fences, escapes, aliases, `#heading`, `#^block`, embeds); schema v5 with stored unresolved edges, `raw_target`, source span; exact resolution first, ambiguous links surfaced rather than guessed; re-resolve on note create, rename and delete | L | 3 | R13 to R17, R20, R21, risks 2 and 3 |
| 5 | **Link-derived views**: unlinked mentions, orphans, dead-ends, degree, local-depth graph, outline and tags pane | M | 4 | R18, R19, R33, R69 |
| 6 | **Audit hardening**: triggers forbidding `UPDATE`/`DELETE`; a per-row hash chain keyed from `KeyManager`; real author id on every row; audit attachment opens and exports; lift the 100,000-row cap | M | author identity decision (open question) | R47 to R49, risk 6 |
| 7 | **Split `AppSession`** into session/lock, navigation, sync, backup/import services | L | 1 | R64, risk 1 |
| 8 | **Service-layer policy gate**: one place that decides what search, graph and backlinks may return; wire the graph filter through it | M | 7 | R32, R51, R35 |
| 9 | **Note revisions**: `note_revisions` (number, author, hash, predecessor), revision history UI, backup/export/import support | L | 6, 7 | R6, R24 |
| 10 | **Lifecycle and signing**: draft, review, signed; DB-enforced immutability for signed revisions; addenda with reason; signer and timestamp | L | 9 | R7 to R9, R50 |
| 11 | **Structured clinical entities**: move diagnoses and medications out of JSON blobs into rows; add an Encounter table that notes and events attach to; typed relations and typed link syntax (`[[medication:apixaban]]`) | L | 4, 9 | R4, R5, R22, R23, R29, R11 |
| 12 | **Provenance records** tied to revisions | M | 9, 10 | R50 |
| 13 | **Editor and reading view**: incremental/viewport styling, Live Preview markers hidden, Reading View from a real AST with tables, quotes, code highlighting and clickable links; conformance corpus across editor, AST and preview | L | 4 | R37 to R41 |
| 14 | **FHIR export mapping** (Composition, Provenance, AuditEvent first) | L | 9 to 12 | R59, R60 |
| 15 | **Sync/collaboration, server, plugin sandbox, RBAC/ABAC** | L+ | scope decision | R46, R54 to R58, R61 to R63 |

Item 15 should stay unscheduled until the product scope question below is answered. The report's own advice is that these items bring the most complexity and are only worth building for a multi-user product.

---

## 7. Coverage

- **Files read: 163 of 163** inventory files. **Skipped: 0.** See `FILE_COVERAGE.md` for the per-file checklist.
- Method: eight reader agents each read one slice in full and reported per-file line counts and last lines, which I re-counted and compared; all matched. Because most files end in `}`, I also read the following myself and checked the readers' claims on them: `Storage/Schema.swift`, `Services/LinkingService.swift`, `Models/Core.swift`, `Support/SecurityLog.swift`, `UI/Graph/GraphLayout.swift`, `UI/Markdown/MarkdownPreview.swift`, `UI/Notes/MarkdownStyler.swift`, `docs/security.md`, and the audit, search, WAL and `NoteService.save` code in `Storage/Database.swift` and `Services/Services.swift`. I also spot-checked claims in `Storage/SecureStoreCoordinator.swift`, `Support/KeyManager.swift`, `Services/BackupService.swift`, `Services/AppStore.swift`, `UI/Graph/GraphView.swift`, `scripts/release.sh` and `Storage/StoreMigrator.swift`.
- The research PDF was read in full (34 pages).
- **Excluded as not source** (judgment calls marked †):
  - `build/` (build output and 84 preview PNGs), `bin/mednotes-import` (compiled binary), `default.profraw`, `Package.resolved` (lock file), `xcuserdata/`, image assets, `.DS_Store`.
  - † `Recovery/` (14 string and symbol dumps extracted from the old binary, 60,000+ lines): generated, and the README describes them. They could hold information about the lost V1.1 source that I did not look at.
  - † `MedNotes/Localizable.xcstrings` (7,197 lines): Xcode-generated catalog, checked by `scripts/check_l10n.py`, which was read. User-facing wording was not audited.
  - † Five tooling files in dot-directories (local plan notes and a worktree rule): not part of the product.
- **Tests**: the baseline analysis ran none. On 2026-10-27 the full suite passed before any change (507 tests, 0 failures, 4 skipped; one entitlements test took 24 minutes waiting on a macOS Documents-folder permission prompt). After Phase 1, 567 tests ran with 0 failures and the same 4 skips, with that one entitlements test excluded from the run (it reads a repo file, is unrelated to links, and stalls on the permission prompt). After Phase 2 the count was 691 and after Phase 3 it is 772, each with 0 failures, the same 4 skips and the same exclusion. Claims in sections 1 to 6 about runtime behaviour still come from reading code and tests.

---

## Open questions

1. **Scope.** Is MedNotes meant to stay a single-clinician local notebook, or grow into multi-user or multi-device? Items R46, R54 to R63 (13 of 69 requirements) hinge on it.
2. **Identity.** Signing and audit need an author. Is there a single implicit user, a named clinician profile, or accounts? What does "signed" mean here: a recorded attestation, or a cryptographic signature with a key?
3. **Jurisdiction.** The report is framed around HIPAA and FHIR. MedNotes is Greek (AMKA, Greek localization). Should the target compliance frame be GDPR and Greek health-data rules instead, and does the six-year retention in the report apply?
4. **"Audit every read"** (p19) conflicts with a single-user notebook where reads happen on every keystroke-driven search. Which reads count (opening a patient, exporting, opening an attachment, running a search)?
5. **Report-internal tensions.** It asks for friendly human aliases (`[[Patient:John Smith]]`) and also for explicit typed IDs (`[[condition:AF]]`) without saying which is canonical, or what happens when an alias is ambiguous. It recommends a hash chain but admits that it is insufficient without a separately controlled anchor (WORM, remote attestation); a local single-user app has no such second party. It recommends both a local SQLite store and a central PostgreSQL store without describing how they relate.
6. **Notes versus structured facts.** The report wants free text never to be treated as a clinical order (p22). Should `[[medication:...]]` in a note ever create or update a structured medication entry, or only point at one?
7. **Is the PDF the full requirement set?** The research describes Obsidian's architecture, so my requirement list is an interpretation. Features you may want that it does not cover (for example scheduling, billing, templates, reminders) are listed in section 3 as "built but not in the research", not judged.
8. **Obsidian UX parity.** Which Obsidian features do you actually want (Canvas, Bases, properties UI, plugins)? The report treats them as optional, and I did not score R67.
9. **Uncommitted changes.** Should the 11 modified files be treated as the intended current state? This analysis reads the working tree, not `HEAD`.

---

## Update, 2026-10-28 (later still): after Phase 3 (search and graph)

Phase 3 of the roadmap (item 5's graph views and the search half of item 2) is built. The boxes above and the baseline below are left as written.

| Requirement | Before Phase 3 | Now | What changed |
|---|---|---|---|
| R19 orphans, dead-ends, degree | Partial | Done | The graph has an Orphans toggle and sizes nodes by link count (`GraphFilter`, `GraphCanvas`); `linkStats` is still used only by a test. |
| R31 search operators | Missing | Partial | Phrases, `-`, `OR`, grouping, `tag:`, `property:`, `[key:value]`, `patient:`, `linked:` (`SearchQuery`, `SearchEngine`). Not built: `file:`, `path:`, `line:`, `block:`, `section:`, `task:`. |
| R33 force graph, local depth, force controls | Partial | Done | Local graph in the inspector (depth 1 to 3), four force sliders, filters, colour groups, arrows (`GraphLayout.Forces`, `GraphSettingsPanel`, `NoteGraphSection`). Not built: tags or unresolved links as nodes, text fade, link thickness, animation. |
| R28 FTS with ranking, snippets, prefix, phrase | Partial | Partial | Phrases and per-row snippets with the matched words marked are built; there is still no `bm25()` ranking (order is pinned, then newest). |

New scores: **Core about 49%** (29 / 59: 16 Done, 26 Partial, 15 Missing, 2 Conflicts; was 47%). **Invariants unchanged at about 56%.** All 67 scored: about 44%.

What the owner should know:
- **Greek accents.** The full-text index does not fold the Greek tonos: searching `ασθενης` does not find `ασθενής` in a note's text. This is how FTS5's `unicode61` tokenizer works (its diacritic folding covers Latin marks), so it was already true of the plain search. `tag:`, `property:` and `linked:` do fold it (they compare through `WikiLinkParser.normalizedKey`), as does the snippet marking, so the operators and plain words are inconsistent. Fixing it means a custom tokenizer or a folded shadow column: a schema and trigger change that backup restore validation checks byte for byte, so it needs its own step.
- **`linked:`** matches the key a link is written with (including links that resolve to nothing), not the resolved destination's title. Under the Phase 1 rule that a link keeps its target only while its key still names it, the two coincide.
- **Bare words with punctuation** (`C3-C4`, `2024-05-01`) now match as phrases, which is stricter than the old AND of tokens. `OR` is an operator only in capitals; to search for the operating-room abbreviation, quote it.
- A word matches a note through its patient's name, phone, e-mail or AMKA (as before), now one term at a time: `nikos digoxin` finds a note about Nikos that contains "digoxin".
- **Graph settings are stored in the encrypted store** (schema v7 table `app_state`), not in user defaults, because a filter or group is often a patient's name. They leave memory when the app locks, and a change made in the last 0.4 s before a lock is not saved. An older build cannot open a v7 backup.
- Moving a force slider re-lays the graph out from where it was (a warm start), so the picture stays recognisable; leaving the Graph module and coming back does a fresh layout, which can differ from the one that was on screen.
- The Local graph section reads the whole graph only while it is open. Its settings panel is limited to depth, Patients and Events; its filter and groups are stored but have no controls yet.
- Graph privacy filters (hiding patient names, degree and labels) are still not built; they are Phase 7. The graph still shows every patient, archived ones too.

Known limits: the panel's controls (typing in the filter, dragging a slider, adding a group) were rendered off screen and their logic is tested through the session, but nothing here was driven in a running app. Only the light appearance was looked at. The highlight colour test skips itself when the system accent colour is grey.

---

## Update, 2026-10-28 (after Phase 3): Greek accent folding

The Greek-accent limitation recorded in the Phase 3 box is fixed. `ασθενης`, `ΑΣΘΕΝΉΣ` and `ασθενής` are now the same word in the full-text indexes, in `tag:`, `property:` and `linked:` (already folded), and in the todo, event, audit and Quick Open filters, which were accent-sensitive. No requirement changes status; R28 (FTS quality) is better but still lacks ranking.

How: FTS5 cannot do it by itself (its tokenizer keeps the precomposed tonos and `ς`, and SQLite's `lower()` is ASCII-only), so the six full-text triggers store a folded copy (`GreekFold`, one table that generates both the Swift function and the SQL `replace()` chain; a test runs the two against each other) and the typed query is folded the same way. Schema v8 (`8.0-fts-folding`) replaces the triggers and refills both indexes once, in a savepoint; the restore check now trusts only the current trigger text, and an older database restored from a backup is upgraded before it serves a search.

Limits: polytonic Greek is not folded; an older build cannot restore a v8 backup, and running one over a v8 store makes accented searches miss; the one-time refill runs when the store opens (fast at practice scale, and logged).

