# Pinned dependency licenses

MedNotes ships two external dependencies. Both are pinned by exact revision in
`Package.resolved`; this file records what they are and under what terms.

| Package | Revision | License | Why |
|---|---|---|---|
| [SQLCipher.swift](https://github.com/sqlcipher/SQLCipher.swift) | `39f212458aeb88e33bdac2200a793a3f0d55d32b` | BSD-style (SQLCipher / Zetetic) | SQLCipher build of SQLite: page encryption, HMAC verification, memory sanitisation |
| [swift-sodium](https://github.com/jedisct1/swift-sodium) | `cfd195c76882aa9b997560ca7cb95d72fbf5db00` | ISC (libsodium) | Argon2id, XChaCha20-Poly1305 secretstream, KDF, secure memory primitives |

Both licenses require attribution and reproduction of their license text in
applications and documentation. The full license texts are carried in the
packages and reproduced in the app's About panel and the release DMG.

## Scanning

`scripts/scan_dependencies.sh` (run in CI and before a release) fails the build
when:

- `Package.resolved` contains any package other than the two above;
- either revision drifts from the pinned value;
- the resolved files are missing.

It prints the pinned inventory for the release log.
