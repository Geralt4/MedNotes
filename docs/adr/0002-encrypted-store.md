# ADR 0002 — Encrypted store, locked session, and bounded backups

**Status:** accepted 2026-09-23
**Supersedes:** ADR 0001 (Option A), whose boundaries this replaces
**Context:** security hardening migration

## Context

ADR 0001 relied on FileVault and the sandbox for the live store, left restore
points plaintext, mirrored every note to readable Markdown, and sealed exported
backups as a serialized `FileWrapper` tree. Four problems followed:

1. The database, `Files/`, and every restore point were readable at rest by
   anything that could read the container, including other processes in the
   user's session and forensic tooling.
2. The v1 backup container could represent directory trees, path separators
   and symbolic links, and its PBKDF2 iteration count was attacker-controlled.
3. Calendar and Reminders writes resolved their target by calendar title and
   could write before any explicit consent.
4. The continuous Markdown mirror meant clinical notes were plaintext on disk
   for the whole life of the app.

## Decision

**The store is encrypted, the session is locked, and everything that leaves is
explicit.**

### Keys

- One random 256-bit root key, created during migration, stored in the
  Keychain with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` and a
  `.userPresence` access control (Touch ID or the account password).
- Database, attachment and restore-point keys are derived from it with
  libsodium `crypto_kdf` contexts (`KeyManager`, `StoreKeyContext`). Each
  attachment additionally derives its own stream key from a per-file salt.
- Keys live only in memory while the store is unlocked and are dropped on lock.
  No key is ever written to the store directory.

### Database

- SQLCipher (`SQLCipher.swift`, pinned revision). Every connection is opened
  with a raw 256-bit key, `cipher_memory_security = ON`, `cipher_integrity_check`
  before `Database` exposes data, `temp_store = MEMORY`, `trusted_schema = OFF`
  and `defensive = ON`.
- Schema v4 adds `sync_destinations` and `sync_object_map`; `patient_files`
  gains `storage_id`, `plaintext_length` and `content_digest`.

### Attachments

- `secretstream_xchacha20poly1305` in 1 MiB chunks, with an encrypted true
  length, a random per-file salt, and padding to a 64 KiB boundary.
- Stored under opaque random UUIDs (`Attachments/<storageID>`), never
  patient-derived paths.
- Plaintext exists only in memory. "Open Externally" is the single exception:
  an explicit disclosure, a 0600 temporary file, removed when focus returns,
  the app locks, or it exits.

### Session

- `SecureStoreCoordinator` states: `locked`, `unlocking`, `migrating`, `ready`,
  `failed`. No service is constructed before `ready`.
- Authenticate at launch; obscure the window immediately on resign-active;
  lock on screen or session lock, and after five minutes without an in-app
  keyboard, pointer or window event. Locking cancels sync/search tasks, clears
  displayed records, closes SQLCipher, deletes plaintext temporaries and wipes
  key buffers.
- Encrypted data with a missing Keychain key never starts an empty database;
  the UI offers restore from a portable backup.

### Migration

- A plaintext store is detected by its SQLite header and converted by a
  mandatory wizard: create and test-decrypt a v2 backup, stage an encrypted
  database and attachment tree beside the live one, validate schema, counts,
  foreign keys, digests and a full decrypt pass, then swap atomically.
- A PHI-free `migration.json` journal records only phases and counts so an
  interruption resumes or rolls back deterministically. The original store is
  deleted last. The result states that APFS snapshots or historical backups may
  still hold the plaintext.
- The encrypted format is a one-way upgrade; downgrade requires an exported
  backup.

### Backups

- Format v2 (`BackupArchiveV2`): typed records only — manifest, encrypted
  database snapshot (chunked), attachment metadata, attachment chunks, end
  marker. Paths and symlinks are unrepresentable.
- Argon2id v1.3, 64 MiB, three operations, selected by a fixed profile
  identifier; the profile is validated before the KDF runs.
- Bounded before any work: 4 KiB header, 1 MiB chunk, 100,000 records, 100 GiB
  archive, checked arithmetic, free-space staging.
- The database snapshot is a temporary SQLCipher database keyed from the
  archive key, so no plaintext database is written while backing up.
- v1 archives stay readable with containment: header validated first, PBKDF2
  iterations bounded to 100,000–2,000,000, 1 GiB cap, entry-by-entry extraction
  with `O_NOFOLLOW | O_EXCL`, rejecting separators, depth, non-regular files,
  duplicate names and symlinks.
- Generated passphrases are 24 Crockford Base32 characters, copied to the
  clipboard and cleared after 60 seconds if unchanged. Custom passphrases must
  be NFC and at least 16 characters; policy is enforced in the service, not
  only the UI.

### Calendar and Reminders

- `sync_destinations` stores the bridge, the exact calendar/list identifier,
  the source identifier/title/type, whether MedNotes created it, the consent
  timestamp and the connection state.
- After permission, a wizard requires an explicit destination. New containers
  in an explicitly chosen source are the default; adopting an existing one is
  secondary and shows the record count and fields that leave the app. Because
  EventKit cannot prove a destination is shared, cloud sources require an
  acknowledgment.
- Only the chosen identifiers are used. A missing or changed identifier sets
  "Needs Reconnection" and stops; title matching is gone.
- App-created objects carry an opaque marker; only objects in the chosen
  destination that are mapped or marked are read or written. A missing remote
  object is a conflict, never a silent local delete.
- Sync stays off until a manual pass succeeds and the user enables it, pauses
  while locked, and suspends after a restore until reconfirmed.

### Vault

- The continuous mirror, its preference, watchers and security-scoped bookmark
  are removed. `MarkdownExportService` writes a deliberate one-time export, and
  `VaultReconciliation` classifies an existing mirror (database-only,
  vault-only, divergent) before it is deleted on the user's word.

### Release

- Apple Events automation entitlement removed; only sandbox, user-selected
  read/write, app-scoped security-scoped bookmarks (for the import folder),
  Calendar and Reminders remain.
- `scripts/release.sh` archives with manual Developer ID signing and hardened
  runtime, verifies the signature and entitlement allowlist, builds and signs a
  DMG, notarizes with `notarytool`, staples, validates with `stapler` and
  `spctl`, and publishes a checksum. Any mismatch fails the release.
- The Developer ID signature needs a provisioning profile for the bundle id.
  The profile adds `com.apple.application-identifier` and
  `com.apple.developer.team-identifier`, which the data-protection Keychain
  requires; the verifier checks both and that they name the signing team. No
  `keychain-access-groups` entitlement is needed: the default group is the
  application identifier.

## Consequences

- The app gains two audited dependencies (SQLCipher, swift-sodium), pinned by
  revision in `Package.resolved` and scanned in CI.
- The database key never leaves the Keychain, so a lost Keychain item means the
  data needs a portable backup to recover; the UI says exactly that.
- Losing a backup passphrase loses that backup; there is no escrow.
- FTS continues to work inside SQLCipher; no search feature is lost.
- The CLI stays a system-only, plaintext dry-run tool and never opens the
  encrypted store.

## Open

- Whether to rotate the root key on demand; the KDF contexts make it
  mechanically simple but no UI exists.
- Post-quantum symmetric agility: the file format's version byte is the seam.
