# Pinned dependency licenses

MedNotes ships two external dependencies. Both are pinned by exact revision in
`Package.resolved`; this file records what they are and under what terms.

| Package | Version | Revision | License | Why |
|---|---|---|---|---|
| [SQLCipher.swift](https://github.com/sqlcipher/SQLCipher.swift) | 4.19.0 | `39f212458aeb88e33bdac2200a793a3f0d55d32b` | BSD-style ("Community Edition Open Source License", Zetetic LLC); SQLite itself is in the public domain | SQLCipher build of SQLite: page encryption, HMAC verification, memory sanitisation |
| [swift-sodium](https://github.com/jedisct1/swift-sodium) | 0.11.0 | `cfd195c76882aa9b997560ca7cb95d72fbf5db00` | ISC (Frank Denis) | Argon2id, XChaCha20-Poly1305 secretstream, KDF, secure memory primitives, through libsodium (`Clibsodium.xcframework`, built from libsodium revision `8cda270b3b18ca103c57085752cece1ebbf5abee`) |

Both licenses require attribution and reproduction of their license text in
applications and documentation.

## Where the license texts are

`MedNotes/Licenses.txt` holds them, one block per package, each under a header
that names the package, its version and its revision. The blocks are the
packages' own license files, copied word for word from the checkouts at the
pinned revisions:

- SQLCipher.swift: `LICENSE.md`, up to the line `# Begin SQLite README.md`
  (the rest of that file is SQLite's README, not a license);
- swift-sodium: `LICENSE`. The package carries libsodium only as a binary
  framework and has no separate libsodium license file, so this is the license
  the package ships for it.

That one file is what ships, in two places:

- **The app.** It is a bundle resource (`Contents/Resources/Licenses.txt`), and
  the About panel (MedNotes › About MedNotes) shows it in its credits, under
  "Open-source licenses", next to the version and the build number.
- **The DMG.** `Licenses.txt` sits at the DMG's top level, next to the app.

## Checks

`python3 scripts/check_licenses.py` (also run by `scripts/release.sh`) fails
when:

- `MedNotes/Licenses.txt` differs from what the pinned checkouts yield;
- a checkout is not at the pinned revision, or a package is missing;
- the text lacks either package's license;
- on a release: the built app, or the finished DMG (mounted read-only), lacks
  the file or holds a different one.

After updating a dependency, run `python3 scripts/check_licenses.py --write`
and review the diff. `python3 -I scripts/test_check_licenses.py` tests the
check, including real DMGs.

`python3 scripts/scan_dependencies.py` (run before a release) fails the build
when:

- `Package.resolved` contains any package other than the two above;
- either revision drifts from the pinned value;
- the resolved files are missing.

It prints the pinned inventory for the release log.
