#!/usr/bin/env python3
"""The third-party licence texts MedNotes ships.

`MedNotes/Licenses.txt` is the file the About panel shows and the DMG carries
at its top level. It is made from the licence files of the exact package
versions the project pins (`Package.resolved`), and this script keeps it so:

  scripts/check_licenses.py                 check the file against the checkouts
  scripts/check_licenses.py --write         rewrite it from the checkouts
  scripts/check_licenses.py --dir DIR       check a folder (a mounted DMG)
  scripts/check_licenses.py --dmg FILE.dmg  mount the DMG read-only and check it
  scripts/check_licenses.py --app MedNotes.app   check the copy inside an app

A check fails when the file differs from what the checkouts yield, when a
checkout is not at the pinned revision, when a package is missing, or when a
folder or DMG lacks the file or holds a different one. `scripts/release.sh`
runs it before building the DMG and again on the finished DMG.

Exit status: 0 when everything checks out, 1 otherwise.
"""

from __future__ import annotations

import argparse
import glob
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

# What a licence text must hold, whatever else changes: both packages, both licences.
REQUIRED_PHRASES = ["SQLCipher", "Community Edition Open Source License", "libsodium", "ISC License"]

HEADER = "Third-party licenses shipped with MedNotes\n==========================================\n"
RULE = "-" * 72


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


def derive(checkouts: str, resolved_path: str = RESOLVED) -> str:
    """The text `MedNotes/Licenses.txt` must hold, from the pinned checkouts."""
    pins = pinned_revisions(resolved_path)
    blocks = [HEADER]
    for package in PACKAGES:
        pinned = pins.get(package["identity"])
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
            sodium = _libsodium_revision(folder)
            note = ("Includes libsodium (Clibsodium.xcframework"
                    + (f", built from libsodium revision {sodium}" if sodium else "") + ").")
        blocks.append(
            f"\n{package['name']} {tag} (revision {pinned})\n{package['url']}\n"
            + (f"{note}\n" if note else "") + f"{RULE}\n{text.strip()}\n")
    return "\n".join(blocks).replace("\n\n\n", "\n\n")


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


def check_text(actual: str, expected: str) -> list[str]:
    problems = []
    if actual != expected:
        problems.append("MedNotes/Licenses.txt differs from the licence files of the pinned package versions "
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
    parser.add_argument("--dir", help="check a folder for the licence file")
    parser.add_argument("--dmg", help="mount this DMG read-only and check it")
    parser.add_argument("--app", help="check the copy inside this .app")
    args = parser.parse_args(argv)

    try:
        expected = derive(find_checkouts(args.checkouts))
    except LicenseError as error:
        print(f"licence check failed: {error}", file=sys.stderr)
        return 1

    if args.write:
        with open(LICENSES_FILE, "w", encoding="utf-8") as handle:
            handle.write(expected)
        print(f"wrote {os.path.relpath(LICENSES_FILE, REPO)}")
        return 0

    problems: list[str] = []
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
