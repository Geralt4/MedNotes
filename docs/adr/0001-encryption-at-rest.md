# ADR 0001 — Encryption at rest

**Status:** accepted 2026-09-09 (owner review pending on the open points)
**Context:** the real-data readiness plan, Step 2

## Context

MedNotes stores clinical records for a single clinician on one Mac. Everything
lives inside the app's sandbox container:

```
~/Library/Containers/com.johnteam.MedNotes/Data/Library/Application Support/com.johnteam.MedNotes/
├── mednotes.db      SQLite (patients, notes, todos, events, audit log, FTS)
├── Files/           patient attachments, one folder per patient
├── Vault/           Markdown mirror of every note, YAML front-matter (Obsidian)
└── Backups/         restore points made before a restore or an import
```

Three facts drive the decision:

1. The store is authoritative and searchable. Full-text search over notes and
   patients runs inside SQLite (FTS5).
2. The vault mirror is plaintext by design. It exists so Obsidian can open the
   notes; it therefore exposes every clinical note as a readable file.
3. Backups leave the container. `BackupService.createBackup(name:to:)` copies
   the database and `Files/` to any folder the user picks — the one path by
   which the data reaches a USB stick, a shared drive or iCloud.

The project's stated constraint is no external dependencies (system
libsqlite3 only).

## Options

**A. FileVault plus the sandbox container as the at-rest boundary; encrypt
everything that leaves it.**
The disk is encrypted by macOS; the container is readable only by the app
and the user. Backups become a single encrypted archive (AES-256-GCM from
CryptoKit, key derived from a passphrase with PBKDF2-HMAC-SHA256 from
CommonCrypto, both system frameworks). The vault mirror becomes an opt-in
setting, off by default, with a plain warning. No new dependency; search and
FTS unchanged.

**B. SQLCipher.**
Encrypts the database file itself with a key held in the Keychain; FTS keeps
working inside the encrypted database. Adds the first external dependency
(a replacement SQLite build), and still leaves `Files/`, `Vault/` and the
backups to be handled separately.

**C. Field-level encryption in the app.**
Encrypt sensitive columns with CryptoKit before they reach SQLite. Breaks
full-text search and every `LIKE`/`ORDER BY` over those columns; the notes
module is built on search.

## Decision

**Option A.**

- The database, `Files/` and `Backups/` inside the container are protected
  by FileVault and the sandbox. The README states that FileVault must be on;
  a sandboxed app has no API to verify it, so this is documented, not checked.
- **Backups are encrypted archives.** Format `mednotesbackup`, version 1:
  a fixed header (magic, version, PBKDF2 salt, iteration count, AES-GCM
  nonce) followed by the sealed box of a `FileWrapper` serialisation of the
  plaintext backup directory (`manifest.json`, `mednotes.db`, `Files/`).
  Restore verifies the authentication tag and the manifest before any file
  in the container is touched, and keeps the existing restore-point step.
  A wrong passphrase fails before the store is opened. The passphrase is
  entered per backup and never stored.
- **The vault mirror is opt-in**, off by default. While off, `mirror()` and
  `reconcile()` are no-ops and startup neither imports from nor rewrites the
  folder. Turning it on restores today's behaviour; turning it off leaves the
  existing files in place and says so.
- **Restore points** written before a restore or a legacy import stay in the
  plaintext directory format inside `Backups/`, where the boundary is the
  container.

## Consequences

- Nothing readable leaves the container without a passphrase; a lost
  passphrase is a lost backup, which the dialog says in as many words.
- Obsidian users must switch the mirror on deliberately and accept the
  plaintext folder.
- The archive is built in memory. Attachments of several hundred megabytes
  will need a streaming variant; the header carries a version for that.
- Option B remains the escalation if a policy requires per-file encryption
  of the database itself. The archive format and the settings surface do not
  change under B.

## Open

- Passphrase policy: per backup (chosen here) versus one key kept in the
  Keychain and unlocked by the login session.
- Whether the vault mirror belongs in a clinical build at all, or only in a
  personal-notes configuration.
