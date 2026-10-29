#!/usr/bin/env python3
"""Fails a release when an entitlement outside the allowlist is present.

The shipped binary may hold only what its features need: the sandbox,
user-selected read/write files, app-scoped bookmarks (so the chosen import
folder is remembered), and Calendar and Reminders access. Anything
else — Apple Events, network clients, full disk access, debugging — is a
policy regression and stops the release.

It must also carry the two identity entitlements the provisioning profile
adds: without them the data-protection Keychain refuses every call with
errSecMissingEntitlement (-34018), and the app cannot hold its device key.
Those are strings that name the signing team, so the team is passed in.
"""

import plistlib
import sys

ALLOWED = {
    "com.apple.security.app-sandbox",
    "com.apple.security.files.user-selected.read-write",
    "com.apple.security.files.bookmarks.app-scope",
    "com.apple.security.personal-information.calendars",
    "com.apple.security.personal-information.reminders",
}

# Added by the provisioning profile, not written in the entitlements file. Both
# are required, and their values must name the team that signed the app.
BUNDLE_ID = "com.johnteam.MedNotes"


def identity_entitlements(team: str) -> dict:
    return {
        "com.apple.application-identifier": f"{team}.{BUNDLE_ID}",
        "com.apple.developer.team-identifier": team,
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


def main(path: str, team: str) -> int:
    with open(path, "rb") as handle:
        data = plistlib.load(handle)
    if not isinstance(data, dict):
        data = {}
    entitlements = set(data.keys())
    identity = identity_entitlements(team)

    failures = sorted((entitlements & FORBIDDEN))
    unexpected = sorted(entitlements - ALLOWED - FORBIDDEN - set(identity))
    missing = sorted(k for k in ALLOWED if data.get(k) is not True)
    missing += sorted(k for k, v in identity.items() if data.get(k) != v)

    if failures:
        print("forbidden entitlements present: " + ", ".join(failures))
    if unexpected:
        print("entitlements outside the allowlist: " + ", ".join(unexpected))
    if missing:
        print("required entitlements missing: " + ", ".join(missing))
    if failures or unexpected or missing:
        return 1

    print("entitlement allowlist ok: " + ", ".join(sorted(entitlements)))
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print(f"usage: {sys.argv[0]} <entitlements.plist> <team-id>", file=sys.stderr)
        sys.exit(2)
    sys.exit(main(sys.argv[1], sys.argv[2]))
