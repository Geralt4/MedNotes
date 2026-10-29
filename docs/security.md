# MedNotes security guarantees

This document states what MedNotes protects, what it deliberately discloses,
and what it does not defend against. It is the user-facing companion to
`docs/adr/0002-encrypted-store.md`.

## What is protected

| Surface | Protection |
|---|---|
| Database | SQLCipher, raw 256-bit key from the Keychain, HMAC-verified pages |
| Attachments | `secretstream_xchacha20poly1305`, opaque storage IDs, authenticated chunks |
| Restore points | v2 archive under the device restore key |
| Portable backups | v2 archive under an Argon2id-derived passphrase key |
| Session | Locked on inactivity, screen lock, display or system sleep, user switching and on request |
| Logs | Generic events and opaque identifiers only |

One random root key is created at migration and held in the macOS Keychain with
`kSecAttrAccessibleWhenUnlockedThisDeviceOnly` and a user-presence requirement
(Touch ID or the account password). The database, attachment and restore-point
keys are derived from it with libsodium's KDF, so a single unlock covers the
whole store. Keys are never written beside the data and are dropped from memory
when the store locks.

The key lives in the data-protection Keychain, which only answers an app that
carries an application identifier from a provisioning profile. A build signed
without one (ad hoc, or Developer ID with no profile) is refused with
`errSecMissingEntitlement` and cannot create or read the key. The release script
requires the profile and `scripts/verify_entitlements.py` checks the signed app
for it.

The store locks after five minutes without activity, when the screen locks
(Lock Screen, or a screen saver or display sleep once the login password is
required), when the displays or the Mac go to sleep, when you switch to
another user, and on request (MedNotes › Lock MedNotes, ⌃⌘L). Locking closes
the database, clears every displayed record and wipes the keys; only Touch ID
or the account password opens it again. A lock
that arrives while an unlock is still loading records wins. Switching to
another app or hiding MedNotes does not lock the store: a curtain covers the
window until the app is active again. The curtain hides the window from
VoiceOver and other apps with Accessibility access as well, and keyboard focus
leaves the covered content until it lifts; the passphrase fields of the
encryption and recovery screens keep theirs.

A lock first saves the record being edited, into the store it is about to
close (a new record left untouched is discarded, as closing its editor would),
then dismisses every sheet and alert, clears the search fields and the quick
switcher, and covers the Activity and Settings windows. Unlocking reopens the
record that was selected. MedNotes launched in the background, such as a login
item, starts behind the curtain.

Only a Keychain answer of "no such item" (or an item that can never be a key)
counts as a lost key. A cancelled or refused Touch ID or password prompt, or a
keychain that is still locked, leaves MedNotes locked with the reason on the
lock screen; Unlock tries again, and recovery is never offered for it. Each
unlock reads the key once, so it asks for Touch ID once.

If the Keychain item is really lost, MedNotes does not start an empty store: it
shows a recovery screen that restores a portable backup with a brand-new device
key. Recovery refuses while the Keychain still holds a usable key, so a healthy
store is never replaced by an older backup. It reads the whole backup and
validates it (passphrase, integrity, schema, and the restored database under the
new key) before it changes anything, so a wrong passphrase or a damaged backup
leaves the store and the Keychain as they were. The unreadable old files are
then moved aside, the restored ones moved in, and the new key is stored last;
if the Keychain refuses it, the old files go back. The old bytes are removed
only once the key is stored. The chosen backup file is left where it is.

The app is sandboxed. It has no network client entitlement and makes no network
connections; there is no telemetry.

## Deliberate disclosures

Data leaves MedNotes in exactly four ways, each one explicit:

1. **Calendar and Reminders.** After a destination wizard, the fields named in
   the wizard (title, notes, dates, completion, priority) travel to the chosen
   calendar or list and then wherever that account synchronises. EventKit
   cannot prove whether a destination is shared, so a cloud source requires an
   acknowledgment that its participants may receive the data. Nothing is
   written before consent, and a destination that disappears stops the bridge
   instead of matching by name.
2. **Markdown export.** "Export Markdown Vault…" writes plaintext notes to a
   folder you choose. The result is readable by anything with access to that
   folder; the export is one-time and leaves no watcher or bookmark behind.
3. **Open Externally.** Opening an attachment in another application writes a
   `0600` temporary copy and hands it over. The copy is removed when the store
   locks and when MedNotes quits; one left behind by a crash is removed at the
   next launch. Losing focus does not remove it: the application it was handed
   to takes focus as it opens the copy, and must still be able to read it.
4. **Backups.** A portable backup is encrypted with its passphrase. Losing the
   passphrase loses the backup; there is no recovery and no escrow.

## What is not defended against

- **A compromised macOS account.** Malware running as you, while the store is
  unlocked, can read what the app can read. The five-minute idle lock narrows
  the window, it does not close it.
- **Historical copies.** APFS snapshots, Time Machine and other backups taken
  while the store was plaintext still hold plaintext. Enabling FileVault and
  rotating or deleting those backups is the remedy.
- **The other end of a sync.** Once data reaches Calendar or Reminders it is
  subject to that account's protections, not MedNotes's.
- **Physical access with your password.** Touch ID and the account password are
  the gate; an attacker who has them has the store.

## Operational recommendations

- Keep FileVault on.
- Keep the generated backup passphrases; store them where clinical data is
  already permitted to be stored.
- Review the destination each bridge writes to occasionally, and reconnect if
  the connection state reads "Needs Reconnection".
- Delete the retired plaintext Markdown mirror after reviewing it, and be aware
  that snapshots may retain it.
