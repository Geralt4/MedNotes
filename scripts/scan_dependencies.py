#!/usr/bin/env python3
"""Verifies the pinned dependency inventory in Package.resolved.

Fails when a package outside the recorded allowlist is resolved, or when a
pinned revision drifts. `scripts/release.sh` runs this.
"""

import json
import os
import sys

ALLOWED = {
    "sqlcipher.swift": "39f212458aeb88e33bdac2200a793a3f0d55d32b",
    "swift-sodium": "cfd195c76882aa9b997560ca7cb95d72fbf5db00",
}

RESOLVED_PATHS = [
    "MedNotes.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved",
    ".swiftpm/xcode/Package.resolved",
    "Package.resolved",
]


def load(path):
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


def main():
    resolved = None
    for candidate in RESOLVED_PATHS:
        if os.path.exists(candidate):
            resolved = candidate
            break
    if resolved is None:
        print("no Package.resolved found; run a build first", file=sys.stderr)
        return 1

    data = load(resolved)
    pins = data.get("pins", [])
    failures = []
    seen = {}

    for pin in pins:
        identity = pin.get("identity") or pin.get("package", "")
        state = pin.get("state", {})
        revision = state.get("revision", "")
        seen[identity] = revision
        if identity not in ALLOWED:
            failures.append(f"unexpected package: {identity}")
            continue
        if revision != ALLOWED[identity]:
            failures.append(
                f"{identity} revision drift: {revision} != {ALLOWED[identity]}")

    for identity, revision in ALLOWED.items():
        if identity not in seen:
            failures.append(f"pinned package missing: {identity} @ {revision}")

    if failures:
        for failure in failures:
            print(failure, file=sys.stderr)
        return 1

    print(f"dependency inventory ok ({resolved}):")
    for identity in sorted(seen):
        print(f"  {identity} @ {seen[identity]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
