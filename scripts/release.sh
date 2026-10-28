#!/bin/bash
# Builds, signs, notarizes and publishes a Developer ID release of MedNotes.
#
# The team identifier is never committed: provide it through the environment
# (or an untracked Local.xcconfig) so the repository stays free of
# signing-account details. Everything else about the release is deterministic:
# a signed app with hardened runtime and library validation, a signed DMG, a
# stapled notarization ticket, and a published SHA-256 checksum.
#
# Required environment:
#   MEDNOTES_TEAM_ID          Developer ID team identifier
#   MEDNOTES_SIGN_IDENTITY    e.g. "Developer ID Application: Jane Doe (ABCDE12345)"
#   MEDNOTES_NOTARY_PROFILE   keychain profile created with
#                             `xcrun notarytool store-credentials`
#
# Usage:
#   scripts/release.sh 2.0.1
#
# Any mismatch in signature, entitlements or notarization fails the run and
# leaves the artifacts in build/release for inspection.

set -euo pipefail

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
  echo "usage: $0 <version>" >&2
  exit 2
fi

: "${MEDNOTES_TEAM_ID:?set MEDNOTES_TEAM_ID}"
: "${MEDNOTES_SIGN_IDENTITY:?set MEDNOTES_SIGN_IDENTITY}"
: "${MEDNOTES_NOTARY_PROFILE:?set MEDNOTES_NOTARY_PROFILE}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

OUT="build/release"
DERIVED="$HOME/Library/Developer/Xcode/DerivedData/MedNotes-release"
ARCHIVE="$OUT/MedNotes.xcarchive"
EXPORT_DIR="$OUT/export"
APP="$EXPORT_DIR/MedNotes.app"
DMG="$OUT/MedNotes-$VERSION.dmg"

rm -rf "$OUT"
mkdir -p "$OUT"

step() { printf '\n== %s\n' "$1"; }

step "Verify the pinned dependency inventory"
python3 scripts/scan_dependencies.py

step "Gate on the security test suite"
# Only the named CLI tests may skip in a sandboxed test host.
xcodebuild \
  -project MedNotes.xcodeproj \
  -scheme MedNotes \
  -derivedDataPath "$DERIVED" \
  test | tee "$OUT/tests.log"
if ! grep -q '\*\* TEST SUCCEEDED \*\*' "$OUT/tests.log"; then
  echo "tests did not pass; refusing to release" >&2
  exit 1
fi
python3 - "$OUT/tests.log" <<'PY'
import re
import sys

allowed = {
    "testCLISafetyRefusesBackupsFolder",
    "testCLISourceRequiresPath",
    "testCLIDryRunOnEmptySource",
}
with open(sys.argv[1], encoding="utf-8", errors="replace") as log:
    for line in log:
        if re.match(r"^Test Case .* skipped", line, re.IGNORECASE):
            match = re.match(r"^Test Case '-\[MedNotesTests\.CLIDryRunTests (\w+)\]' skipped", line, re.IGNORECASE)
            if not match or match.group(1) not in allowed:
                print("unexpected skipped test; refusing to release: " + line.strip(), file=sys.stderr)
                sys.exit(1)
PY

step "Archive (Release, hardened runtime)"
# The version the caller names is the version the app must report, not only
# the name of the DMG.
xcodebuild \
  -project MedNotes.xcodeproj \
  -scheme MedNotes \
  -configuration Release \
  -derivedDataPath "$DERIVED" \
  -archivePath "$ARCHIVE" \
  MARKETING_VERSION="$VERSION" \
  DEVELOPMENT_TEAM="$MEDNOTES_TEAM_ID" \
  CODE_SIGN_IDENTITY="$MEDNOTES_SIGN_IDENTITY" \
  CODE_SIGN_STYLE=Manual \
  ENABLE_HARDENED_RUNTIME=YES \
  OTHER_CODE_SIGN_FLAGS="--options=runtime" \
  archive

step "Export the signed app"
cat > "$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$MEDNOTES_TEAM_ID</string>
  <key>signingStyle</key><string>manual</string>
  <key>destination</key><string>export</string>
</dict>
</plist>
PLIST
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$OUT/ExportOptions.plist"

step "Verify the app signature and entitlement allowlist"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dv --verbose=4 "$APP" 2>&1 | tee "$OUT/codesign.txt"
ENTITLEMENTS="$(codesign -d --entitlements :- "$APP" 2>/dev/null || true)"
printf '%s' "$ENTITLEMENTS" > "$OUT/entitlements.plist"
python3 scripts/verify_entitlements.py "$OUT/entitlements.plist"

step "Build the DMG"
STAGE="$OUT/dmg-root"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "MedNotes $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
codesign --force --sign "$MEDNOTES_SIGN_IDENTITY" "$DMG"

step "Notarize and staple"
xcrun notarytool submit "$DMG" --keychain-profile "$MEDNOTES_NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature -v "$DMG"

step "Publish the checksum"
shasum -a 256 "$DMG" | tee "$DMG.sha256"

step "Release ready"
echo "$DMG"
