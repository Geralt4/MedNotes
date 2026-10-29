# MedNotes 2.0 (rebuild)

Clean-room rebuild of the MedNotes backend. The original V1.1 source was lost;
this project was reconstructed from the compiled app binary and the surviving
iCloud data.

## Status

Backend and UI verified by the test suite, plus offscreen renders of every
editor and Settings pane, and live runs of the seeded app in English and
Greek. The security hardening migration (see `docs/adr/0002-encrypted-store.md`)
landed 2026-09-23: the store is SQLCipher-encrypted, attachments use
authenticated streaming, backups are a bounded v2 format, and Calendar and
Reminders require an explicit destination before any write.

- Models decode the original JSON store byte-for-byte (fixtures taken from real data)
- SQLCipher store with all V1.1 bugs fixed; key from the Keychain, no plaintext DB
- One-shot JSON importer (idempotent, tested against real fixtures)
- Services: patients, notes, todos, calendar events, audit, backups
- `DataRoot` (Application Support layout) + `SecureStoreCoordinator` (lock/unlock/migrate)
- Portable backups (`mednotesbackup` v2) and encrypted restore points; restore
  points are listed with their sizes in Settings › Data, deletable, and pruned
  to the newest five after every creation
- Attachments encrypted under opaque storage IDs (`Attachments/<uuid>`),
  metadata in `patient_files`
- Native 3-column macOS UI (sidebar modules → list → detail)
- `bin/mednotes-import` CLI for dry-run imports (unsandboxed, plaintext and
  system-only); built only by `scripts/build_cli.sh` from a hand-listed subset
  of sources, which the test target typechecks on every build
  (`scripts/build_cli.sh --check`)

## Security

- **Encrypted store.** SQLCipher with a raw 256-bit key derived from a
  Keychain item protected by Touch ID or the account password
  (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly` + `.userPresence`). The
  database, attachments and restore points each use a libsodium-KDF-derived
  subkey; `cipher_integrity_check` runs before any data is exposed.
- **Locked session.** Lock on inactivity (five minutes), screen lock, display
  or system sleep, fast user switching, and on request (MedNotes › Lock
  MedNotes, ⌃⌘L; `AppSession.SystemLockEvent` covers the system events,
  observed on NSWorkspace's own notification center and the distributed one,
  never `NotificationCenter.default`). Resigning active only raises the
  privacy curtain over the open store. Locking closes SQLCipher, clears
  displayed records, cancels sync and search, and wipes key buffers; a lock
  that arrives during an unlock wins.
- **Crash-safe migration.** A plaintext store is detected by its SQLite header
  and converted by a mandatory wizard: a verified v2 backup first, staged
  encrypted database and attachments, full validation, then an atomic swap.
  A PHI-free journal makes interruption resumable or reversible. A missing
  device key is recovery, never a fresh store: `StoreRecovery` installs a
  portable backup under a new key.
- **Bounded backups.** v2 archives are typed record streams (no paths or
  symlinks), Argon2id v1.3 with a fixed profile, and hard limits checked before
  any allocation. v1 archives stay readable with containment (bounded PBKDF2,
  1 GiB cap, no-follow extraction).
- **Explicit sync destinations.** Calendar and Reminders choose an exact
  destination in a wizard; identifiers are authoritative and a missing one
  stops the bridge. Title matching is gone, app-created objects carry an opaque
  marker, and a missing remote object is a conflict rather than a silent
  delete.
- **Deliberate exports only.** The continuous Markdown mirror is retired. "One
  time Export Markdown Vault…" writes plaintext to a folder you choose, and an
  existing mirror is reconciled before deletion.

`docs/security.md` states the guarantees and the deliberate disclosures;
`docs/adr/0002-encrypted-store.md` is the decision record.

## Release

`scripts/release.sh <version>` archives with a manual Developer ID signature
and hardened runtime, verifies the signature and the entitlement allowlist
(`scripts/verify_entitlements.py`), builds and signs a DMG, notarizes with
`notarytool`, staples and validates with `stapler`/`spctl`, and publishes a
SHA-256 checksum. The team identifier comes from the environment
(`MEDNOTES_TEAM_ID`) and is never committed, and neither is the name of the
Developer ID provisioning profile (`MEDNOTES_PROFILE_NAME`). The profile is what
grants the app its application-identifier entitlement; the release stops if the
signed app lacks it or names another team. Dependency revisions are checked
by `scripts/scan_dependencies.py` and recorded in `docs/dependencies.md`.

## Notes core & Apple sync

- **Wiki-links**: type `[[` in a note → autocomplete over the whole store
  (titles first, then bodies, then patients; `AppSession.linkCandidates`),
  not just the filtered list. Links are read by one hand-written parser
  (`WikiLinkParser`: `[[Note]]`, `[[Note|alias]]`, `[[Note#Heading]]`,
  `[[Note#^block]]`, `[[#Heading]]`, `![[embed]]`; code, comments and escaped
  brackets are skipped) and stored, resolved or not, in the derived tables
  `wikilinks` and `link_sources` (`LinkIndex`). A link resolves only to an
  exact title or patient name (case, accents and final sigma ignored); it
  never guesses. An unresolved link stays in the note and resolves when a
  note with that title appears; a working link keeps its target when a
  duplicate title is created; several candidates make it *ambiguous*. The
  panel under a note lists outgoing links, links that lead nowhere (click to
  create the note), backlinks and unlinked mentions. The tables are derived
  from note text and rebuilt on open for any note whose text changed
  (`link_sources` holds a hash), so restoring, importing or upgrading needs no
  special step. `note_links` is the superseded v2 table, kept and ignored.
  **Graph module** (Canvas constellation; list view for a11y)
- **Note metadata** (derived from the note text, rebuilt on open, never a
  second source of truth): the YAML front matter becomes typed **properties**
  (text, number, checkbox, date, date and time, list; `tags`, `aliases` and
  `cssclasses` are lists), read by a small hand-written parser
  (`FrontMatterYAML`) that edits only the lines it changes and leaves anything
  it does not fully understand (nested maps, block scalars, duplicate or quoted
  keys) byte-for-byte and read-only. Front matter is a `---` first line and a
  later `---` line with properties between them; two rules around prose are
  ordinary text. `#tags` (any script, nested with `/`), headings and `^block`
  ids are read by `NoteMetadata`. A note's tags are the union of its tag field,
  its `#tags` and its `tags:` property; nothing is rewritten. `aliases:` feed
  the `[[` autocomplete (`[[Title|alias]]`) and unlinked mentions but never
  change what a link resolves to.
- **Inspector** (right of the note, ⌥⌘I): Properties (typed fields; each edit is
  one undo step in the note's text), Outline (click a heading to jump there)
  and Links. The notes list has a Tags menu with counts that narrows the list
  together with the search text.
- **Settings › Data › Rebuild Indexes**: rebuilds search, links, tags and
  properties from the notes in one transaction and checks the result; notes,
  patients and every other table are untouched (`Database.rebuildIndexes`).
- **Notes search**: the notes list understands words (each a prefix),
  `"exact phrases"`, `-exclusion`, `OR` (capitals), `( )` grouping, and
  `tag:`, `property:key`, `property:key:value` / `[key:value]`, `patient:` and
  `linked:` (a pasted `[[Title]]` works too). Half-typed text never errors:
  only letters and digits reach the full-text index (`SearchQuery`,
  `Database.notesMatching`). Each row shows the line that matched with the
  words marked (`SearchSnippet`); a note found through a patient, tag or
  property keeps its ordinary preview. Quick Open and `[[` completion keep the
  plain word search. Order is pinned first, then newest; there is no relevance
  ranking. Greek is folded everywhere a search looks: accents, capitals and the
  final sigma do not matter (`ασθενης`, `ΑΣΘΕΝΉΣ` and `ασθενής` are one word),
  in the full-text indexes, in `tag:`, `property:` and `linked:`, and in the
  todo, event and Quick Open filters. Polytonic Greek (`Ἀθῆναι`) is not
  folded.
- **Graph**: a settings panel (toolbar, right of the canvas) with Filters (a
  search in the same syntax, Patients, Events, Orphans), Groups (colour the
  notes a search finds, up to eight), Display (arrows, size by links) and Forces
  (centre, repel, link force, link distance). The note inspector has a **Local
  graph** (closed by default; depth 1 to 3 around the open note, with the same
  nodes listed under it). The settings are kept in the encrypted store
  (`app_state`, schema v7), not in user defaults, because a filter or group is
  often a patient's name; they leave memory when the app locks.
- **Quick Open ⌘O**: single overlay searching notes/patients/todos/events
- **Markdown export**: a deliberate one-time "Export Markdown Vault…" action in
  Settings › Data writes plaintext `{noteId}.md` files (YAML front-matter) to a
  folder you choose. The continuous mirror is retired; an existing `Vault/` is
  classified against the database (database-only / vault-only / divergent)
  before deletion (`MarkdownExportService`, `VaultReconciliation`)
- **Markdown preview**: edit/preview toggle; headings/lists/checklists/code via
  native `AttributedString(markdown:)`, no dependencies
- **Clinical templates**: SOAP / Admission / Discharge Summary seeded into
  `note_templates` (INSERT OR IGNORE — user edits preserved); toolbar picker;
  `{{date}} {{time}} {{patient}}` substitution; edited, reset and extended
  with custom templates in Settings › Templates
- **Apple Calendar two-way sync** (`AppleCalendarService`): a destination the
  user confirms in a wizard (a new "MedNotes" calendar in a chosen account, or
  an existing calendar); push dirty rows, pull external drift with
  content-based last-writer-wins (`CalendarSyncCore.decide`, conflicts logged +
  surfaced); debounced `EKEventStoreChanged`; sync pill + "Sync Now" (⌘⇧R)
- **Apple Reminders two-way sync** (`AppleRemindersService`): the same
  destination wizard for a reminders list; a todo's title, notes, due day,
  completion and priority travel, the patient link and tags never leave
  MedNotes; the same content-based last-writer-wins
  (`ReminderSyncCore.decide`, conflicts surfaced) and change-driven pull; sync
  pill in the Todos toolbar + "Sync Now" (⌘⇧T).
  Automatic passes of either bridge never raise the permission dialog; only
  Sync Now does, and each bridge's automatic passes can be switched off in
  Settings › Sync ("Keep in sync automatically"), leaving Sync Now as the
  only path while deletes still remove the synced copy at once
- Schema v2 additive migration (`migrations` row `2.0-vault-links`),
  `calendar_events` gains `ek_event_identifier/sync_status/last_sync_date`;
  v1 databases upgrade in place preserving all rows
- Schema v3 additive migration (`migrations` row `3.0-reminders-sync`):
  `todo_items` gains `updated_at`, backfilled from `created_at`
- Schema v4 additive migration (`migrations` row `4.0-encrypted-store`):
  `sync_destinations` and `sync_object_map`, plus `patient_files` encryption
  metadata (`storage_id`, `plaintext_length`, `content_digest`)
- Schema v7 additive migration (`migrations` row `7.0-app-state`): `app_state`
  (key, JSON value, updated_at) for small named settings; not derived, so Rebuild
  Indexes leaves it alone, and a backup carries it with the rest of the database
- Schema v8 additive migration (`migrations` row `8.0-fts-folding`): the six
  full-text triggers are replaced so the indexes hold a folded copy of the
  text (`GreekFold`, one table shared by Swift and SQL) and both indexes are
  refilled once, in one savepoint. A restored older database is upgraded the
  same way before it serves a search. An older build cannot restore a v8
  backup, and running one over a v8 store searches accented words less well.
- Neither bridge writes before a destination is confirmed, and a missing or
  changed destination stops the bridge rather than matching by title

## What was fixed vs V1.1

| V1.1 bug | Fix here |
|---|---|
| Dual-write JSON+SQL split-brain (12 vs 5 divergent todos) | One store (SQLite). JSON is import-only |
| `PRAGMA foreign_keys` never enforced | Enabled on every connection; FK tests assert it |
| `todo_items.patient_id` had no FK | FK with `ON DELETE SET NULL` |
| Stale stored `is_overdue` / `is_due_today` / `age` | Computed at read time in Swift |
| Hardcoded `'2025-11-08...'` timestamp defaults | `strftime('now')` defaults |
| Comma-counting triggers (`[]` → count 1) | Counts computed in Swift |
| UPDATE triggers rewriting the same row | No same-row triggers; FTS triggers use the rowid protocol |
| `note_ids`/`task_ids` JSON duplicating junction data | `patient_notes` junction only |
| `patient_files.file_data` BLOBs in iCloud DB | Encrypted `Attachments/<storageID>` on disk; metadata only in the DB |
| FTS delete via `WHERE id = ?` on UNINDEXED column | `WHERE rowid = OLD.rowid` |
| `notes.isPinned` dropped by SQL schema | `is_pinned` column |
| Silent SQL→JSON fallback hid failures | Errors throw |

## Layout

- `MedNotes/Models/` — Patient, Note, TodoItem, CalendarEvent + nested medical types
- `MedNotes/Storage/` — SQLConnection (SQLCipher), Schema v1–v4, Database actor,
  KeyManager, SecureStoreCoordinator, EncryptedFileStore, StoreMigrator
- `MedNotes/Import/` — JSONImporter (reads the legacy iCloud folder layout)
- `MedNotes/Services/` — Audit, Patient, Note, Todo, CalendarEvent, Backup,
  SyncDestination and MarkdownExport services
- `MedNotes/UI/` — Sidebar, lists, detail editors, theme tokens/components;
  `UI/Settings/` (the Settings window's panes), `UI/Sync/` (the toolbar sync
  pill shared by Todos and Calendar)
- `MedNotesTests/Fixtures/` — real JSON from the surviving data (patient, note, todos, event)

## Building

```
xcodebuild -project MedNotes.xcodeproj -scheme MedNotes build
xcodebuild -project MedNotes.xcodeproj -scheme MedNotes test
```

macOS 14+ (Sonoma) is the deployment target; two pieces of polish are macOS 26
only and degrade to no-ops below it. Swift 5 mode. Two pinned external
dependencies: SQLCipher (`SQLCipher.swift`, BSD) and swift-sodium (ISC);
system CryptoKit and CommonCrypto remain for the legacy v1 reader. Revisions
are recorded in `docs/dependencies.md` and checked by
`scripts/scan_dependencies.py`. The CLI stays dependency-free: it typechecks
against system modules only and never opens the encrypted store.

### Signing

Out of the box the app is signed ad hoc (`Config/Signing.xcconfig`). That is
enough to build and run the tests, but an ad-hoc app cannot use the
data-protection Keychain: every call fails with `errSecMissingEntitlement`
(-34018), so it can only run against the preview or test key managers. To run
the app on a real store, copy `Config/Local.xcconfig.example` to
`Config/Local.xcconfig` (git ignores it), put your team in it, and build with
automatic signing (`-allowProvisioningUpdates` on the command line). Xcode then
makes the development profile that carries the application identifier.
`KeychainEntitlementTests` is skipped on an ad-hoc build and, on a team-signed
one, adds and removes a real Keychain item.

Keep DerivedData outside `~/Documents` (Xcode's default location is fine).
The project folder is under `~/Documents`, and the sandboxed test host
symbolicates every failed assertion by reading the build products; a Debug
build's ad-hoc signature changes with each rebuild, so with DerivedData inside
the project every failing test after a rebuild raises macOS's "access files in
your Documents folder" dialog and blocks until it is answered. A passing run
never touches it, which is why the stall looked random. The project's old
`build/DerivedData` has been removed, and nothing in the repository writes
DerivedData there.

## Data notes

- The legacy iCloud folder (`iCloud Drive/Documents/MedNotes`) is untouched.
  Live contents: 0 patients, 0 notes, 12 todos, 172 calendar events (all JSON).
- The 467 patients in `Backups/` are test data and are NOT imported by default.
- Legacy events referencing missing patients import with `patient_id` NULL
  (warning logged) instead of being dropped or violating FKs.

## UI

Three-column `NavigationSplitView`: sidebar modules (Notes / Patients / Todos / Calendar
with counts), searchable source lists, grouped-form detail editors. Teal accent and
app icon live in `MedNotes/Assets.xcassets`. Shortcuts: ⌘N new, ⌘1–5 modules
(Notes / Patients / Todos / Calendar / Graph), ⌘O quick open, ⌘⌫ archive or delete,
⌘⇧P pin, ⌘. toggle todo, ⌘⇧R sync calendar, ⌘⇧T sync reminders, ⌘S save,
⌘, settings, ⌃⌘L lock.

- **Editors.** Every record editor is a grouped form of labelled, bezeled inputs,
  two to a row where values are short (`PatientEditorForm`, `TodoEditorForm`,
  `EventEditorForm`, driven by bindings). A new record opens with the keyboard in
  its first field; a record created and left untouched is discarded again, so an
  abandoned "+" leaves no row behind. The patient editor validates AMKA (length,
  encoded birth date, Luhn check digit) as advice only, offers the birth date the
  number encodes, and names another patient already holding the same AMKA.
- **Patients archive rather than delete.** Every Delete affordance archives; the
  Archived filter in the patient list is where a record is restored or, with a
  second confirmation, deleted for good.
- **Backups and import.** File › Back Up… writes a passphrase-encrypted archive
  (`.mednotesbackup`); File › Restore from Backup… checks it before touching the
  store and keeps a restore point; File › Import Legacy Data… dry-runs the old
  iCloud folder into a scratch store, shows the report, then imports after a
  restore point. The newest five restore points are kept and older ones
  pruned (audited); Settings › Data lists them with sizes and deletes on
  request. Window › Activity shows the audit trail, including the settings
  changes, integrity checks and restore point housekeeping.
- **Settings (⌘,).** A tabbed window (`MedNotes/UI/Settings/`), one tab per
  concern. *General*: which module the window opens on (fixed, or where you
  left off) and the security posture (store state, the idle-lock interval, and
  the ways data leaves the app). *Templates*: the clinical templates
  behind the note editor's insert menu — built-ins edited in place and reset
  to their shipped copy, custom ones added, duplicated and deleted, with the
  record editors' rules (Save / Revert, autosave on moving on, an untouched
  "+" discarded), and "New notes start from" to seed every new note with a
  template (a seeded note left untouched is still discarded). *Sync*: the
  Apple Calendar and Reminders
  bridges — connection state, the confirmed destination, a Connect / Sync Now
  button, a "Keep in sync automatically" switch per bridge, the last pass's
  summary, and what leaves the container once a bridge is on. *Data*: where the
  store lives and its record counts, the last encrypted backup (orange once it
  is a month old or missing), the encrypted restore points with their sizes
  (deletable; the newest five are kept after every import or restore), the
  one-time "Export Markdown Vault…" action and the retired mirror's
  reconciliation report, and an on-demand integrity check (SQLite's check plus
  every record link, logged to the audit trail; the same check runs quietly at
  launch and raises a banner only when it fails). The panes take values and
  closures, never the session, so they render offscreen and in
  `MedNotesTests/SettingsRenderTests` like the editors do; the preferences
  themselves are covered by `MedNotesTests/SettingsTests`.

## Data safety

See `docs/security.md` and `docs/adr/0002-encrypted-store.md`. The database,
attachments and restore points are encrypted with a device key in the Keychain
that requires Touch ID or your account password; the app locks after five
minutes without activity, when the screen locks or the Mac sleeps, when you
switch users, and on request (MedNotes › Lock MedNotes, ⌃⌘L). Everything that leaves the
container does so deliberately: a portable backup encrypted with a passphrase
that MedNotes never stores (a lost passphrase is a lost backup), records sent
to a Calendar or Reminders destination you confirm, a Markdown export you run,
or an attachment you open in another app. Neither bridge writes anything before
its destination is confirmed, and each has a "Keep in sync automatically"
switch in Settings › Sync: off, only Sync Now moves data. A restored backup
suspends both bridges until you reconnect them. Keep FileVault on as well.

## Editor render tests

`MedNotesTests/EditorRenderTests` hosts the editors in-process and asserts that
every labelled field exists and the bitmap is not blank.

## Localization

UI wording goes through `MedNotes/Localizable.xcstrings`; data (names, tags,
values) renders verbatim. Greek entries are drafted and await review of the
clinical terms; English is the development language.

## Next steps

1. Review the Greek draft in the strings catalog (condition statuses, allergy
   severities, event types, the AMKA messages, and the security, migration and
   destination-wizard strings added on 2026-09-23).
2. Confirm height and weight units (labelled cm and kg).
3. Add a UI-test target so the accessibility identifiers
   (`SettingsIdentifiers`) can be exercised through XCUITest; the in-process
   harness deliberately never walks the accessibility tree.
4. Root-key rotation: the KDF contexts make it mechanical, but there is no UI
   or reason yet.