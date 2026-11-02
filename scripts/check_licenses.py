#!/usr/bin/env python3
"""The third-party licence texts MedNotes ships.

`MedNotes/Licenses.txt` is the file the About panel shows and the DMG carries
at its top level. It holds the notice of every third-party component compiled
into the app (docs/dependencies.md lists them):

  SQLCipher.swift    its licence file, from the checkout at the pinned revision
  swift-sodium       its licence file, from the checkout at the pinned revision
  libsodium          its LICENSE, word for word from libsodium's source at the
                     revision swift-sodium's binary was built from
  code in libsodium  the notices of the files it bundles under BSD-style terms
                     (SHA-256, SHA-512, PBKDF2, scrypt), word for word

The two packages carry libsodium only as a compiled framework, so its notices
cannot come from the checkouts. They come from a libsodium source tree at the
audited revision (--libsodium-source), and the committed text is pinned by its
SHA-256 here, so a release checks them without the source.

  scripts/check_licenses.py                 check the file against the checkouts
  scripts/check_licenses.py --write         rewrite it from the checkouts
  scripts/check_licenses.py --libsodium-source DIR
                                            ... and against libsodium's source
  scripts/check_licenses.py --dir DIR       check a folder (a mounted DMG)
  scripts/check_licenses.py --dmg FILE.dmg  mount the DMG read-only and check it
  scripts/check_licenses.py --app MedNotes.app   check the copy inside an app

A check fails when the file differs from what the checkouts yield, when a
checkout is not at the pinned revision, when a package is missing, when a
libsodium notice is missing or differs from the audited text, when the bundled
libsodium or SQLite is not the audited version, when third-party code is tracked in the repository without being accounted for,
or when a folder or DMG lacks the file or holds a different one. With the libsodium source it also fails on
any file that carries a licence this script does not ship. `scripts/release.sh`
runs it before building the DMG and again on the finished DMG.

Exit status: 0 when everything checks out, 1 otherwise.
"""

from __future__ import annotations

import argparse
import glob
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
import time

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LICENSES_FILE = os.path.join(REPO, "MedNotes", "Licenses.txt")
RESOLVED = os.path.join(
    REPO, "MedNotes.xcodeproj", "project.xcworkspace", "xcshareddata", "swiftpm", "Package.resolved")
DMG_FILE_NAME = "Licenses.txt"
APP_RESOURCE = os.path.join("Contents", "Resources", "Licenses.txt")

# identity in Package.resolved, folder in the checkouts, licence file, display name,
# and the line after which a licence file stops being the licence.
PACKAGES = [
    {
        "identity": "sqlcipher.swift",
        "folder": "SQLCipher.swift",
        "file": "LICENSE.md",
        "name": "SQLCipher.swift",
        "url": "https://github.com/sqlcipher/SQLCipher.swift",
        "note": "SQLCipher, built on SQLite, which is in the public domain (https://sqlite.org/copyright.html).",
        # The file continues with SQLite's own README, which is not a licence.
        "stop": "# Begin SQLite README.md",
    },
    {
        "identity": "swift-sodium",
        "folder": "swift-sodium",
        "file": "LICENSE",
        "name": "swift-sodium",
        "url": "https://github.com/jedisct1/swift-sodium",
        "note": None,  # filled in from the package's README (the libsodium revision)
        "stop": None,
    },
]

# What the audit of 2026-11 found compiled into the app, and the versions it was
# made against. A newer libsodium or SQLite is a new audit: update these with
# docs/dependencies.md, after reading what the new version bundles.
AUDIT = {
    "libsodium_revision": "8cda270b3b18ca103c57085752cece1ebbf5abee",
    "libsodium_version": "1.0.22",
    "sqlite_version": "3.53.4",
}
LIBSODIUM_URL = "https://github.com/jedisct1/libsodium"

# libsodium's files that carry a BSD-style notice (Colin Percival's SHA-256,
# SHA-512 and PBKDF2, Alexander Peslyak's and Colin Percival's scrypt), relative
# to src/libsodium. Their notices ship, word for word. Every other file with a
# notice in libsodium's source is a dedication to the public domain or CC0
# (Argon2, BLAKE2, D. J. Bernstein's reference ciphers, Thomas Pornin's encoder),
# which asks for nothing; the audit below fails on any other kind.
BSD_NOTICE_FILES = [
    "crypto_hash/sha256/cp/hash_sha256_cp.c",
    "crypto_hash/sha512/cp/hash_sha512_cp.c",
    "crypto_pwhash/scryptsalsa208sha256/pbkdf2-sha256.h",
    "crypto_pwhash/scryptsalsa208sha256/pbkdf2-sha256.c",
    "crypto_pwhash/scryptsalsa208sha256/crypto_scrypt.h",
    "crypto_pwhash/scryptsalsa208sha256/nosse/pwhash_scryptsalsa208sha256_nosse.c",
    "crypto_pwhash/scryptsalsa208sha256/sse/pwhash_scryptsalsa208sha256_sse.c",
    "crypto_pwhash/scryptsalsa208sha256/crypto_scrypt-common.c",
    "crypto_pwhash/scryptsalsa208sha256/scrypt_platform.c",
]
# Phrases that mark a licence with conditions. A file with one that is not
# listed above would need its notice shipped too.
CONDITION_PHRASES = [
    "Redistribution and use", "Permission to use, copy, modify", "Permission is hereby granted",
    "Licensed under the Apache", "GNU General Public", "GNU Lesser", "Mozilla Public", "SPDX-License-Identifier",
]
# Nothing is vendored: the only third-party code is what the two packages bring.
# A tracked framework, library or C-family source file would be a component this
# script has not been told about, so it fails until the file is listed (with its
# notice) in docs/dependencies.md and added to VENDORED_ALLOWED.
VENDORED_SUFFIXES = (".xcframework", ".framework", ".a", ".dylib", ".c", ".cc", ".cpp", ".h", ".m", ".mm", ".S")
VENDORED_ALLOWED: list[str] = []

# SHA-256 of each libsodium notice as audited (the text as it stands in Licenses.txt).
PINNED_SHA256 = {
    "libsodium": "b2ed9fc9e420c8e70d93d84c42c050cf874e088ad7d63a6a1cbf3857bb787fa8",
    "libsodium-bsd": "48bcd005f793787bcb379d16bf7fdb82fde4d447ca3f4a2e85c9e0fcd06a1313",
}

# What a licence text must hold, whatever else changes: every component's notice.
REQUIRED_PHRASES = [
    "SQLCipher", "Community Edition Open Source License", "ZETETIC LLC",
    "swift-sodium", "libsodium", "ISC License", "Frank Denis",
    "Colin Percival", "Alexander Peslyak", "Redistributions in binary form must reproduce",
]

HEADER = "Third-party licenses shipped with MedNotes\n==========================================\n"
RULE = "-" * 72
DELIM = "=" * 72
LIBSODIUM_TITLE = f"libsodium {AUDIT['libsodium_version']} (revision {AUDIT['libsodium_revision']})"
LIBSODIUM_BSD_TITLE = "Code bundled in libsodium under BSD-style terms"


class LicenseError(Exception):
    pass


def pinned_revisions(resolved_path: str = RESOLVED) -> dict[str, str]:
    with open(resolved_path, encoding="utf-8") as handle:
        data = json.load(handle)
    return {pin["identity"]: pin["state"]["revision"] for pin in data.get("pins", [])}


def _git(folder: str, *args: str) -> str:
    result = subprocess.run(["git", "-C", folder, *args], capture_output=True, text=True)
    if result.returncode != 0:
        raise LicenseError(f"git {' '.join(args)} failed in {folder}: {result.stderr.strip()}")
    return result.stdout.strip()


def _libsodium_revision(folder: str) -> str | None:
    readme = os.path.join(folder, "README.md")
    if not os.path.exists(readme):
        return None
    with open(readme, encoding="utf-8") as handle:
        match = re.search(r"revision `([0-9a-f]{40})` of libsodium", handle.read())
    return match.group(1) if match else None


def _first(pattern: str) -> str | None:
    found = sorted(glob.glob(pattern))
    return found[0] if found else None


def check_bundled_versions(checkouts: str, audit: dict[str, str] = AUDIT) -> None:
    """The libsodium and SQLite inside the packages are the audited ones.

    The packages ship them compiled, so the version is read from the headers
    that come with the binaries (the sodium/version.h of Clibsodium.xcframework,
    the sqlite3.h of the SQLCipher framework the build downloaded) and the
    libsodium revision from swift-sodium's README.
    """
    sodium_folder = os.path.join(checkouts, "swift-sodium")
    revision = _libsodium_revision(sodium_folder)
    if revision != audit["libsodium_revision"]:
        raise LicenseError(
            f"swift-sodium's binary is built from libsodium revision {revision or 'unknown'}, "
            f"but the audited one is {audit['libsodium_revision']}; audit what it bundles first "
            "(docs/dependencies.md), then update AUDIT in scripts/check_licenses.py")
    version_h = _first(os.path.join(sodium_folder, "Clibsodium.xcframework", "*", "Headers", "Clibsodium", "sodium", "version.h"))
    if version_h is None:
        raise LicenseError("swift-sodium has no Clibsodium.xcframework headers to read the libsodium version from")
    with open(version_h, encoding="utf-8") as handle:
        match = re.search(r'#define\s+SODIUM_VERSION_STRING\s+"([^"]+)"', handle.read())
    if not match or match.group(1) != audit["libsodium_version"]:
        raise LicenseError(
            f"the bundled libsodium is {match.group(1) if match else 'unknown'}, "
            f"but the audited version is {audit['libsodium_version']}")
    sqlite_h = _first(os.path.join(
        os.path.dirname(checkouts), "artifacts", "sqlcipher.swift", "SQLCipher", "SQLCipher.xcframework",
        "*", "SQLCipher.framework", "Headers", "sqlite3.h"))
    if sqlite_h is None:
        raise LicenseError("the SQLCipher framework is not downloaded here (build once, then check again), "
                           "so the SQLite version inside it cannot be read")
    with open(sqlite_h, encoding="utf-8") as handle:
        match = re.search(r'#define\s+SQLITE_VERSION\s+"([^"]+)"', handle.read())
    if not match or match.group(1) != audit["sqlite_version"]:
        raise LicenseError(
            f"the SQLite inside SQLCipher is {match.group(1) if match else 'unknown'}, "
            f"but the audited version is {audit['sqlite_version']}")


def _first_comment(text: str) -> str | None:
    match = re.match(r"\s*(/\*.*?\*/)", text, re.S)
    return match.group(1) if match else None


def audit_libsodium_source(root: str) -> list[str]:
    """Files of libsodium's source that carry a licence with conditions, and are not shipped."""
    problems = []
    listed = {os.path.join(root, "src", "libsodium", name) for name in BSD_NOTICE_FILES}
    for folder, _, names in os.walk(os.path.join(root, "src")):
        for name in sorted(names):
            if not name.endswith((".c", ".h", ".S", ".s", ".inc")):
                continue
            path = os.path.join(folder, name)
            with open(path, encoding="utf-8", errors="replace") as handle:
                text = handle.read()
            has_conditions = any(phrase in text for phrase in CONDITION_PHRASES)
            unmarked_copyright = bool(re.search("copyright", text, re.I) and not re.search("CC0|ublic domain", text))
            if path in listed:
                if not has_conditions:
                    problems.append(f"{os.path.relpath(path, root)} is listed but carries no BSD-style notice")
            elif has_conditions or unmarked_copyright:
                problems.append(f"{os.path.relpath(path, root)} carries a licence this script does not ship")
    for name in BSD_NOTICE_FILES:
        if not os.path.exists(os.path.join(root, "src", "libsodium", name)):
            problems.append(f"src/libsodium/{name} is not in the libsodium source")
    return problems


def libsodium_bodies_from_source(root: str, revision: str = AUDIT["libsodium_revision"]) -> dict[str, str]:
    """The libsodium notices, word for word from a libsodium source tree at the audited revision."""
    head = _git(root, "rev-parse", "HEAD")
    if head != revision:
        raise LicenseError(f"the libsodium source is at {head[:12]}, but the audited revision is {revision[:12]}")
    problems = audit_libsodium_source(root)
    if problems:
        raise LicenseError("; ".join(problems))
    with open(os.path.join(root, "LICENSE"), encoding="utf-8") as handle:
        isc = handle.read().strip()
    groups: dict[str, list[str]] = {}
    for name in BSD_NOTICE_FILES:
        with open(os.path.join(root, "src", "libsodium", name), encoding="utf-8") as handle:
            comment = _first_comment(handle.read())
        if comment is None or not any(phrase in comment for phrase in CONDITION_PHRASES):
            raise LicenseError(f"{name} no longer opens with its notice")
        groups.setdefault(comment, []).append(name)
    bsd = "\n\n".join(f"Files: {', '.join(names)}\n{comment}" for comment, names in groups.items())
    return {"libsodium": isc, "libsodium-bsd": bsd}


def _sha256(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def verify_bodies(bodies: dict[str, str], pins: dict[str, str] = PINNED_SHA256) -> None:
    for key, expected in pins.items():
        text = bodies.get(key)
        if text is None:
            raise LicenseError(f"the {key} notice is missing from the licence text")
        if _sha256(text) != expected:
            raise LicenseError(
                f"the {key} notice differs from the audited text (SHA-256 {_sha256(text)[:12]}, "
                f"audited {expected[:12]}); regenerate it with --libsodium-source or restore it")


def parse_sections(text: str) -> list[tuple[str, str]]:
    """(title, body) of each section of the licence file."""
    sections = []
    for part in text.split("\n" + DELIM + "\n")[1:]:
        head, rule, body = part.partition("\n" + RULE + "\n")
        if not rule:
            raise LicenseError("a section of the licence text has no body")
        sections.append((head.split("\n", 1)[0], body.strip()))
    return sections


def libsodium_bodies_from_text(text: str) -> dict[str, str]:
    titles = dict(parse_sections(text))
    bodies = {}
    if LIBSODIUM_TITLE in titles:
        bodies["libsodium"] = titles[LIBSODIUM_TITLE]
    if LIBSODIUM_BSD_TITLE in titles:
        bodies["libsodium-bsd"] = titles[LIBSODIUM_BSD_TITLE]
    return bodies


def _section(title: str, url: str, note: str | None, body: str) -> str:
    if DELIM in body:
        raise LicenseError(f"the text under “{title}” holds the section separator")
    return f"\n{DELIM}\n{title}\n{url}\n" + (f"{note}\n" if note else "") + f"{RULE}\n{body.strip()}\n"


def derive(checkouts: str, resolved_path: str = RESOLVED, libsodium_bodies: dict[str, str] | None = None,
           audit: dict[str, str] = AUDIT, pins: dict[str, str] = PINNED_SHA256) -> str:
    """The text `MedNotes/Licenses.txt` must hold.

    SQLCipher.swift and swift-sodium come from the pinned checkouts; libsodium's
    notices from `libsodium_bodies`, which must match their audited hashes.
    """
    pinned_packages = pinned_revisions(resolved_path)
    blocks = [HEADER]
    for package in PACKAGES:
        pinned = pinned_packages.get(package["identity"])
        if pinned is None:
            raise LicenseError(f"{package['identity']} is not pinned in Package.resolved")
        folder = os.path.join(checkouts, package["folder"])
        if not os.path.isdir(folder):
            raise LicenseError(f"no checkout of {package['folder']} in {checkouts}")
        head = _git(folder, "rev-parse", "HEAD")
        if head != pinned:
            raise LicenseError(
                f"{package['folder']} is checked out at {head[:12]}, but Package.resolved pins {pinned[:12]}")
        tags = _git(folder, "tag", "--points-at", "HEAD").split()
        tag = tags[0] if tags else "untagged"
        license_path = os.path.join(folder, package["file"])
        if not os.path.exists(license_path):
            raise LicenseError(f"{package['folder']} has no {package['file']}")
        with open(license_path, encoding="utf-8") as handle:
            text = handle.read()
        if package["stop"]:
            if package["stop"] not in text:
                raise LicenseError(f"{package['file']} of {package['folder']} no longer has its expected end")
            text = text.split(package["stop"])[0]
        note = package["note"]
        if package["identity"] == "swift-sodium":
            note = ("Includes libsodium (Clibsodium.xcframework, built from libsodium revision "
                    f"{audit['libsodium_revision']}); its notices follow.")
        blocks.append(_section(f"{package['name']} {tag} (revision {pinned})", package["url"], note, text))
    check_bundled_versions(checkouts, audit)
    bodies = libsodium_bodies or {}
    verify_bodies(bodies, pins)
    blocks.append(_section(
        f"libsodium {audit['libsodium_version']} (revision {audit['libsodium_revision']})",
        LIBSODIUM_URL, "LICENSE, from the libsodium source at that revision.", bodies["libsodium"]))
    blocks.append(_section(
        LIBSODIUM_BSD_TITLE, LIBSODIUM_URL + "/tree/" + audit["libsodium_revision"] + "/src/libsodium",
        "The notices of the files libsodium bundles from other authors under BSD-style terms "
        "(SHA-256, SHA-512, PBKDF2, scrypt). The Argon2, BLAKE2 and hash-string code and the reference "
        "ciphers in libsodium are public domain or CC0 and ask for nothing.", bodies["libsodium-bsd"]))
    return "".join(blocks)


def find_checkouts(explicit: str | None = None) -> str:
    candidates = [explicit] if explicit else sorted(
        glob.glob(os.path.expanduser("~/Library/Developer/Xcode/DerivedData/MedNotes-*/SourcePackages/checkouts")))
    pins = pinned_revisions()
    for candidate in candidates:
        if candidate and os.path.isdir(candidate):
            try:
                if all(_git(os.path.join(candidate, p["folder"]), "rev-parse", "HEAD") == pins.get(p["identity"])
                       for p in PACKAGES):
                    return candidate
            except LicenseError:
                continue
    raise LicenseError("no checkout of the pinned SQLCipher.swift and swift-sodium revisions was found; "
                       "run a build first or pass --checkouts")


def vendored_files(repo: str = REPO, allowed: list[str] = VENDORED_ALLOWED) -> list[str]:
    """Tracked files that look like third-party code compiled into the app, and are not accounted for."""
    tracked = _git(repo, "ls-files").splitlines()
    return [name for name in tracked
            if name not in allowed and (name.endswith(VENDORED_SUFFIXES)
                                        or any(part.endswith((".xcframework", ".framework")) for part in name.split("/")))]


def check_text(actual: str, expected: str) -> list[str]:
    problems = []
    if actual != expected:
        problems.append("MedNotes/Licenses.txt differs from the notices of the pinned package versions "
                        "(run scripts/check_licenses.py --write after updating a dependency)")
    for phrase in REQUIRED_PHRASES:
        if phrase not in actual:
            problems.append(f"“{phrase}” is not in the licence text")
    return problems


def check_folder(folder: str, expected: str, relative: str = DMG_FILE_NAME) -> list[str]:
    path = os.path.join(folder, relative)
    if not os.path.exists(path):
        return [f"{relative} is missing from {folder}"]
    with open(path, encoding="utf-8") as handle:
        actual = handle.read()
    problems = []
    if actual != expected:
        problems.append(f"{relative} in {folder} is not the licence text of this release")
    for phrase in REQUIRED_PHRASES:
        if phrase not in actual:
            problems.append(f"“{phrase}” is not in {relative}")
    return problems


def _detach(mount: str) -> bool:
    """Detaches a mounted image, retrying and then forcing; True when it is gone."""
    for attempt in range(4):
        args = ["hdiutil", "detach", mount, "-quiet"] + (["-force"] if attempt == 3 else [])
        subprocess.run(args, capture_output=True)
        if not os.path.ismount(mount):
            return True
        time.sleep(1)
    return not os.path.ismount(mount)


def check_dmg(dmg: str, expected: str) -> list[str]:
    if not os.path.exists(dmg):
        return [f"{dmg} does not exist"]
    mount = tempfile.mkdtemp(prefix="mednotes-dmg-check-")
    attach = subprocess.run(
        ["hdiutil", "attach", "-readonly", "-nobrowse", "-noverify", "-noautoopen", "-mountpoint", mount, dmg],
        capture_output=True, text=True)
    if attach.returncode != 0:
        os.rmdir(mount)
        return [f"could not mount {dmg}: {attach.stderr.strip()}"]
    try:
        problems = check_folder(mount, expected)
    finally:
        detached = _detach(mount)
    if detached:
        try:
            os.rmdir(mount)
        except OSError:
            pass
    else:
        problems.append(f"the DMG is still mounted at {mount}; detach it before going on")
    return problems


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--checkouts", help="SourcePackages/checkouts folder (default: found under DerivedData)")
    parser.add_argument("--write", action="store_true", help="rewrite MedNotes/Licenses.txt from the checkouts")
    parser.add_argument("--libsodium-source",
                        help="a libsodium source tree at the audited revision: take the libsodium notices from it")
    parser.add_argument("--dir", help="check a folder for the licence file")
    parser.add_argument("--dmg", help="mount this DMG read-only and check it")
    parser.add_argument("--app", help="check the copy inside this .app")
    args = parser.parse_args(argv)

    try:
        if args.libsodium_source:
            bodies = libsodium_bodies_from_source(args.libsodium_source)
        elif os.path.exists(LICENSES_FILE):
            with open(LICENSES_FILE, encoding="utf-8") as handle:
                bodies = libsodium_bodies_from_text(handle.read())
        else:
            bodies = {}
        expected = derive(find_checkouts(args.checkouts), libsodium_bodies=bodies)
    except LicenseError as error:
        print(f"licence check failed: {error}", file=sys.stderr)
        return 1

    if args.write:
        with open(LICENSES_FILE, "w", encoding="utf-8") as handle:
            handle.write(expected)
        print(f"wrote {os.path.relpath(LICENSES_FILE, REPO)}")
        return 0

    problems: list[str] = []
    for name in vendored_files():
        problems.append(f"{name} looks like vendored third-party code, which has no notice here "
                        "(add it to docs/dependencies.md and VENDORED_ALLOWED with its notice)")
    if os.path.exists(LICENSES_FILE):
        with open(LICENSES_FILE, encoding="utf-8") as handle:
            problems += check_text(handle.read(), expected)
    else:
        problems.append("MedNotes/Licenses.txt does not exist")
    if args.dir:
        problems += check_folder(args.dir, expected)
    if args.app:
        problems += check_folder(args.app, expected, APP_RESOURCE)
    if args.dmg:
        problems += check_dmg(args.dmg, expected)

    if problems:
        for problem in problems:
            print(f"refusing to release: {problem}", file=sys.stderr)
        return 1
    print("licence texts ok")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
