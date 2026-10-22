#!/usr/bin/env python3
"""Fails a release when an entitlement outside the allowlist is present.

The shipped binary may hold only what its features need: the sandbox,
user-selected read/write files, and Calendar and Reminders access. Anything
else — Apple Events, network clients, full disk access, debugging — is a
policy regression and stops the release.
"""

import plistlib
import sys

ALLOWED = {
    "com.apple.security.app-sandbox",
    "com.apple.security.files.user-selected.read-write",
    "com.apple.security.personal-information.calendars",
    "com.apple.security.personal-information.reminders",
}

# Debug-only entries that must never ship, checked explicitly so the failure
# names the offender instead of just "not in the allowlist".
FORBIDDEN = {
    "com.apple.security.automation.apple-events",
    "com.apple.security.network.client",
    "com.apple.security.network.server",
    "com.apple.security.device.audio-input",
    "com.apple.security.device.camera",
    "com.apple.security.files.downloads.read-write",
    "com.apple.security.files.all",
    "com.apple.security.cs.debugger",
    "com.apple.security.cs.allow-jit",
    "com.apple.security.cs.disable-library-validation",
    "com.apple.security.cs.allow-dyld-environment-variables",
    "com.apple.security.cs.allow-unsigned-executable-memory",
}


def main(path: str) -> int:
    with open(path, "rb") as handle:
        data = plistlib.load(handle)
    entitlements = set(data.keys()) if isinstance(data, dict) else set()

    failures = sorted((entitlements & FORBIDDEN))
    unexpected = sorted(entitlements - ALLOWED - FORBIDDEN)

    if failures:
        print("forbidden entitlements present: " + ", ".join(failures))
    if unexpected:
        print("entitlements outside the allowlist: " + ", ".join(unexpected))
    if failures or unexpected:
        return 1

    print("entitlement allowlist ok: " + ", ".join(sorted(entitlements)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
