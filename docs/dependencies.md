# Third-party components and their licenses

MedNotes has two external dependencies, both pinned by exact revision in
`Package.resolved`. Each brings code of its own and code it bundles, so this
file lists every component compiled into the app, its license, and whether its
notice ships (in the About panel and at the top of the DMG, as `Licenses.txt`).

| Package | Version | Revision | Why |
|---|---|---|---|
| [SQLCipher.swift](https://github.com/sqlcipher/SQLCipher.swift) | 4.19.0 | `39f212458aeb88e33bdac2200a793a3f0d55d32b` | SQLCipher build of SQLite: page encryption, HMAC verification, memory sanitisation. Ships as a downloaded binary framework (`SQLCipher.framework`). |
| [swift-sodium](https://github.com/jedisct1/swift-sodium) | 0.11.0 | `cfd195c76882aa9b997560ca7cb95d72fbf5db00` | Argon2id, XChaCha20-Poly1305 secretstream, KDF, secure memory, through libsodium (`Clibsodium.xcframework`, a static library built from libsodium revision `8cda270b3b18ca103c57085752cece1ebbf5abee`, which reports version 1.0.22). |

## Audit: what is compiled into the app

Last audited 2026-11-02 against the versions above. The app embeds
`SQLCipher.framework` and a framework holding swift-sodium with libsodium linked
statically. Nothing else third-party is compiled in: the repository vendors no
framework, library or C-family source file, and the command-line importer
(`scripts/build_cli.sh`) links only the system `libsqlite3`, never the two
packages, and is not in the DMG.

| Component | Version | License | Notice ships? |
|---|---|---|---|
| SQLCipher (Zetetic LLC) | 4.19.0 | "Community Edition Open Source License" (BSD-style, requires attribution) | **Yes**, from `SQLCipher.swift/LICENSE.md` (up to its SQLite README). The same words as `LICENSE.md` of `sqlcipher/sqlcipher` at tag v4.19.0, which lists no third-party code |
| SQLite, inside SQLCipher | 3.53.4 (from the framework's `sqlite3.h`) | Public domain | Not required. The SQLCipher section says so and links sqlite.org/copyright.html |
| Apple CommonCrypto (SQLCipher's crypto provider; the framework links `Security.framework`) | the system's | Apple's, part of macOS | Not distributed with the app. No OpenSSL or libtomcrypt is compiled in |
| swift-sodium (Frank Denis) | 0.11.0 | ISC, "Copyright (c) 2014-2026, Frank Denis" | **Yes**, from `swift-sodium/LICENSE` |
| libsodium (Frank Denis) | 1.0.22, revision `8cda270b…` | ISC, "Copyright (c) 2013-2026 Frank Denis" | **Yes**, `LICENSE` of the libsodium source at that revision, word for word (identical at the `1.0.22-RELEASE` tag) |
| libsodium's SHA-256 and SHA-512 (`crypto_hash/*/cp`), PBKDF2-SHA256 and scrypt (`crypto_pwhash/scryptsalsa208sha256`) | as libsodium | BSD-2-Clause by Colin Percival (2005–2009) and Alexander Peslyak (2012–2013); `scrypt_platform.c` and `crypto_scrypt-common.c` carry Peslyak's shorter permission without the numbered conditions | **Yes**, the five distinct notices of the nine files, word for word, under "Code bundled in libsodium under BSD-style terms". The license requires binary distributions to reproduce them |
| libsodium's Argon2 reference code (Dinu, Khovratovich) and hash-string encoder (Thomas Pornin) | as libsodium | CC0 1.0 | Not required (a dedication, no conditions) |
| libsodium's BLAKE2 reference code (Samuel Neves) | as libsodium | CC0, OpenSSL license or Apache-2.0 "at your choosing"; CC0 is taken | Not required |
| libsodium's reference Salsa20, ChaCha20 and HSalsa20 (D. J. Bernstein) | as libsodium | Public domain | Not required |
| libsodium's other files (ed25519/curve25519 ref10, sandy2x, Poly1305, AEAD, …) | as libsodium | No license text of their own; covered by libsodium's ISC | Covered by the libsodium notice |

The libsodium source is not in either package (only its compiled library and
headers are), so its notices were taken from the official repository
(`github.com/jedisct1/libsodium`) at revision `8cda270b3b18ca103c57085752cece1ebbf5abee`.
That revision is 86 commits after `1.0.21-RELEASE` and is not itself a tag; both
it and `1.0.22-RELEASE` declare version 1.0.22 and have the same `LICENSE`.
Every file in its `src/` tree that mentions a license with conditions
(Redistribution, Permission to use/is hereby granted, Apache, GPL/LGPL/MPL,
SPDX) is one of the nine BSD files above; the rest are the dedications listed.

## Where the license texts are

`MedNotes/Licenses.txt` holds them, one section per notice, each under a header
that names the component, its version and its revision:

- SQLCipher.swift and swift-sodium: the packages' own license files, copied
  from the checkouts at the pinned revisions (SQLCipher's up to the line
  `# Begin SQLite README.md`; the rest of that file is SQLite's README);
- libsodium, and the code it bundles under BSD-style terms: from the libsodium
  source, as above.

That one file is what ships, in two places:

- **The app.** It is a bundle resource (`Contents/Resources/Licenses.txt`), and
  the About panel (MedNotes › About MedNotes) shows it in its credits, under
  "Open-source licenses", next to the version and the build number.
- **The DMG.** `Licenses.txt` sits at the DMG's top level, next to the app.

## Checks

`python3 scripts/check_licenses.py` (also run by `scripts/release.sh`) fails
when:

- `MedNotes/Licenses.txt` differs from what the pinned checkouts and the pinned
  libsodium notices yield;
- a checkout is not at the pinned revision, or a package is missing;
- the libsodium notices are missing or differ from the audited text (their
  SHA-256 is pinned in the script, so a release checks them without the
  libsodium source);
- the libsodium inside swift-sodium (revision and version) or the SQLite inside
  SQLCipher is not the audited one: a new version is a new audit;
- the repository tracks a framework, library or C-family source file (vendored
  code with no notice);
- on a release: the built app, or the finished DMG (mounted read-only), lacks
  the file or holds a different one.

To prove the libsodium text again, or after a dependency update, check out
libsodium at the audited revision and run:

    python3 scripts/check_licenses.py --libsodium-source <libsodium checkout>

That reads the notices word for word from the source, fails on any file in it
that carries a license this script does not ship, and fails when the committed
text differs. Add `--write` to rewrite `Licenses.txt` from it. After a
dependency update, read what the new version bundles, update `AUDIT`,
`BSD_NOTICE_FILES` and `PINNED_SHA256` in the script and the table above, then
review the diff of `Licenses.txt`.

`python3 -I scripts/test_check_licenses.py` tests the check, including real
DMGs; `LIBSODIUM_SOURCE=<checkout>` adds the comparison with the real source.

`python3 scripts/scan_dependencies.py` (run before a release) fails the build
when:

- `Package.resolved` contains any package other than the two above;
- either revision drifts from the pinned value;
- the resolved files are missing.

It prints the pinned inventory for the release log.
