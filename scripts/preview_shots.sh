#!/bin/bash
#
# Review artefacts for the UI polish, against seeded sample data.
#
#   ./scripts/preview_shots.sh            # every path, output under build/preview-shots
#   ./scripts/preview_shots.sh --rows     # offscreen list rows only (no permissions needed)
#   ./scripts/preview_shots.sh --editors  # offscreen record editors and settings panes (no permissions needed)
#   ./scripts/preview_shots.sh --live     # launch the seeded app and capture windows
#   LANG_CODE=el ./scripts/preview_shots.sh --live   # …in Greek, via the app's container
#                                                    # preferences (offscreen renders stay English)
#
# Path (ii), the offscreen renderers, need no TCC grant and always run.
# Path (i) needs Screen Recording (screencapture) and Accessibility (System
# Events); if they are missing it says so and leaves the app running for a human.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

OUT_DIR="${OUT_DIR:-$ROOT_DIR/build/preview-shots}"
# Outside ~/Documents on purpose. The project lives under ~/Documents, and the
# sandboxed test host symbolicates every failed assertion by reading the
# build products; a Debug build's ad-hoc signature changes with each rebuild,
# so with DerivedData in the project folder every failing test after a rebuild
# raises the "access files in your Documents folder" dialog and blocks until
# it is answered (measured 2026-09-12: 1.3 s, 18 s and 91 s stalls).
DERIVED="${DERIVED:-$HOME/Library/Developer/Xcode/DerivedData/MedNotes-local}"
MODE="${1:-all}"

mkdir -p "$OUT_DIR"

render_rows() {
  echo "🖼  Rendering rows offscreen (no permissions required)…"
  local host="$ROOT_DIR/build/render-rows"
  mkdir -p "$(dirname "$host")"
  # Same trick as scripts/build_cli.sh: compile a source subset directly.
  # MedNotesApp.swift is excluded because this host supplies its own @main.
  # -DDEBUG is required: SampleData and the preview APIs are DEBUG-only.
  local sources=()
  while IFS= read -r file; do sources+=("$file"); done < <(
    find MedNotes -name '*.swift' ! -name 'MedNotesApp.swift' | sort)
  swiftc -DDEBUG -parse-as-library \
    "${sources[@]}" scripts/render_rows.swift \
    -framework SwiftUI -framework AppKit -framework EventKit \
    $(preview_package_flags) \
    -lsqlite3 -o "$host"
  "$host" "$OUT_DIR"
}

# The render hosts compile the app sources directly, so they need the same
# pinned packages the Xcode build resolves. Points at the DerivedData products
# of a completed build; run `xcodebuild build` first if this fails.
preview_package_flags() {
  local derived="${PREVIEW_DERIVED_DATA:-${DERIVED:-$HOME/Library/Developer/Xcode/DerivedData/MedNotes-local}}"
  local products="$derived/Build/Products/Debug"
  local sodium="$derived/SourcePackages/checkouts/swift-sodium/Clibsodium.xcframework/macos-arm64_arm64e_x86_64"
  # Sodium and its C shim are SwiftPM static products built with profile
  # instrumentation in this DerivedData; link the clang profile runtime too.
  local profile_rt
  profile_rt="$(find /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/clang \
    -name 'libclang_rt.profile_osx.a' 2>/dev/null | sort | tail -1)"
  echo "-I $products -F $products -Xcc -DSQLITE_HAS_CODEC -I $sodium/Headers -F $sodium $sodium/libsodium.a $products/Sodium.o $products/_Clibsodium.o $profile_rt"
}

render_editors() {
  echo "🖼  Rendering editors and settings panes offscreen (no permissions required)…"
  local host="$ROOT_DIR/build/render-editors"
  mkdir -p "$(dirname "$host")"
  # A stale host would render yesterday's editors after a failed compile.
  rm -f "$host"
  local sources=()
  while IFS= read -r file; do sources+=("$file"); done < <(
    find MedNotes -name '*.swift' ! -name 'MedNotesApp.swift' | sort)
  swiftc -DDEBUG -parse-as-library \
    "${sources[@]}" scripts/render_editors.swift \
    -framework SwiftUI -framework AppKit -framework EventKit \
    $(preview_package_flags) \
    -lsqlite3 -o "$host"
  "$host" "$OUT_DIR"
}

quit_running_app() {
  # A second seeded instance resetting the preview directory under a live one is
  # the cross-process form of deleting an open SQLite file. One at a time.
  #
  # Only seeded instances count, and they are ended by process id: a name match
  # or `tell application "MedNotes" to quit` would also take the installed app
  # you are using, or an XCTest host, which is named MedNotes too.
  local pids pid
  pids="$(pgrep -f -- '--preview-seed' || true)"
  [ -n "$pids" ] || return 0
  for pid in $pids; do
    kill -TERM "$pid" >/dev/null 2>&1 || true
  done
  for _ in $(seq 1 20); do
    pgrep -f -- '--preview-seed' >/dev/null 2>&1 || return 0
    sleep 0.25
  done
  echo "⚠️  A seeded MedNotes is still running; quit it and retry." >&2
  return 1
}

# A live capture may set the app's language in its container preferences.
# Remove it on every exit path, including the early one that leaves the app
# running when Screen Recording is missing. Only a value this run wrote is
# removed: a language you had set there is never touched (see live_capture).
LANGUAGE_WRITTEN=""
restore_app_language() {
  local prefs="$1"
  if [ -n "$LANGUAGE_WRITTEN" ]; then
    defaults delete "$prefs" AppleLanguages >/dev/null 2>&1 || true
    LANGUAGE_WRITTEN=""
  fi
}

live_capture() {
  echo "🏗  Building Debug…"
  xcodebuild -project MedNotes.xcodeproj -scheme MedNotes \
    -configuration Debug -derivedDataPath "$DERIVED" build >/dev/null

  local app
  app="$(find "$DERIVED/Build/Products/Debug" -maxdepth 1 -name 'MedNotes.app' | head -1)"
  [ -n "$app" ] || { echo "❌ MedNotes.app not found under $DERIVED" >&2; return 1; }

  # One appearance only: the current system one.
  #
  # Forcing the appearance per process with `--args -AppleInterfaceStyle Dark`
  # was the plan's approach and does not work here — measured, twice: the app
  # launches and stays alive but creates no window at all (1 window without the
  # argument, 0 with it). The remaining ways to get a live dark shot both flip
  # the appearance for the whole machine, which is not this script's to do, so
  # dark review comes from `--rows`, which renders both schemes offscreen.
  local appearance
  appearance="$(defaults read -g AppleInterfaceStyle 2>/dev/null | tr '[:upper:]' '[:lower:]' || echo light)"

  for _ in 1; do
    quit_running_app || return 1
    echo "🚀 Launching seeded instance (system appearance: ${appearance})…"
    # --preview-seed=fresh so each run starts from identical content.
    #
    # A language is set through the app's own preferences in its container,
    # not `--args -AppleLanguages`: launched with that argument the app stays
    # alive but never creates a window (measured; the same failure the
    # appearance argument showed). The key is removed again after the run.
    local suffix=""
    local prefs="$HOME/Library/Containers/com.johnteam.MedNotes/Data/Library/Preferences/com.johnteam.MedNotes"
    if [ -n "${LANG_CODE:-}" ]; then
      if defaults read "$prefs" AppleLanguages >/dev/null 2>&1; then
        echo "❌ MedNotes' preferences already set AppleLanguages; not overwriting it." >&2
        echo "   Remove it (defaults delete \"$prefs\" AppleLanguages) or run without LANG_CODE." >&2
        return 1
      fi
      defaults write "$prefs" AppleLanguages -array "$LANG_CODE"
      LANGUAGE_WRITTEN=1
      suffix="-${LANG_CODE}"
    fi
    open -n "$app" --args --preview-seed=fresh

    local pid=""
    for _ in $(seq 1 30); do
      pid="$(pgrep -f -- '--preview-seed' | head -1 || true)"
      [ -n "$pid" ] && break
      sleep 0.5
    done
    [ -n "$pid" ] || { echo "⚠️  seeded process never appeared; skipping ${appearance}." >&2; continue; }

    # Poll for the window rather than sleeping a guessed interval: the first
    # launch after a build is markedly slower than the second.
    local wid=""
    for _ in $(seq 1 30); do
      wid="$(window_id_for_pid "$pid")"
      [ -n "$wid" ] && break
      sleep 0.5
    done
    [ -n "$wid" ] || { echo "⚠️  no on-screen window for pid $pid; skipping ${appearance}." >&2; continue; }
    # Let the seed land and the first list render before capturing.
    sleep 2

    # The launch window needs no System Events at all: the sidebar is visible
    # immediately, which is where the badge treatment shows.
    if ! screencapture -x -o -l"$wid" "$OUT_DIR/launch-${appearance}${suffix}.png" 2>/dev/null; then
      echo "⚠️  screencapture failed — Screen Recording is probably not granted." >&2
      echo "    The seeded app is running; review it by eye, or use --rows." >&2
      restore_app_language "$prefs"
      return 0
    fi
    echo "   captured launch-${appearance}${suffix}.png"

    # Per-module shots need Accessibility, which is a separate grant from Screen
    # Recording and commonly absent. Losing it costs the module walk, not the run.
    #
    # Keystrokes go to whichever app is frontmost, and `tell application
    # "MedNotes" to activate` does not reliably front a DerivedData build — a
    # walk once typed into Safari. So the process is fronted through System
    # Events and checked before every keystroke; ⌘1–5 and ⌘N are the same in
    # every language, which keeps LANG_CODE runs walkable.
    for index in 1 2 3 4 5; do
      if ! front_mednotes; then
        echo "ℹ️  MedNotes could not be brought to the front — grant Accessibility to"
        echo "   this terminal in System Settings › Privacy & Security › Accessibility"
        echo "   for per-module shots, or click through the running app by hand."
        break
      fi
      osascript -e "tell application \"System Events\" to keystroke \"$index\" using command down" >/dev/null 2>&1 || break
      sleep 1
      wid="$(window_id_for_pid "$pid")"
      [ -n "$wid" ] || continue
      screencapture -x -o -l"$wid" "$OUT_DIR/module-${index}-${appearance}${suffix}.png" 2>/dev/null \
        && echo "   captured module-${index}-${appearance}${suffix}.png"
      # A fresh record in each module that has one, so the editors are
      # reviewed too; left untouched, it is discarded when the walk moves on.
      [ "$index" -le 4 ] || continue
      front_mednotes || break
      osascript -e 'tell application "System Events" to keystroke "n" using command down' >/dev/null 2>&1 || break
      sleep 1.5
      wid="$(window_id_for_pid "$pid")"
      [ -n "$wid" ] || continue
      screencapture -x -o -l"$wid" "$OUT_DIR/module-${index}-new-${appearance}${suffix}.png" 2>/dev/null \
        && echo "   captured module-${index}-new-${appearance}${suffix}.png"
    done
  done
  quit_running_app || true
  restore_app_language "$prefs"
}

# Fronts the running MedNotes through its process and confirms it, so a
# keystroke can never land in another app.
front_mednotes() {
  osascript -e 'tell application "System Events" to set frontmost of process "MedNotes" to true' \
    >/dev/null 2>&1 || return 1
  sleep 0.4
  local front
  front="$(osascript -e 'tell application "System Events" to get name of first application process whose frontmost is true' 2>/dev/null)"
  [ "$front" = "MedNotes" ]
}

# The window is found by owning PID: without Screen Recording, window *titles*
# are redacted for other processes, so matching on "SAMPLE DATA" would fail in
# exactly the case where the fallback matters.
window_id_for_pid() {
  osascript -l JavaScript -e "
    ObjC.import('CoreGraphics');
    // CGWindowListCopyWindowInfo hands back a CFArrayRef that JXA will not
    // bridge on its own; castRefToObject is what makes it indexable.
    const ref = \$.CGWindowListCopyWindowInfo(
      \$.kCGWindowListOptionOnScreenOnly | \$.kCGWindowListExcludeDesktopElements, 0);
    const windows = ObjC.deepUnwrap(ObjC.castRefToObject(ref));
    let found = '';
    for (let i = 0; i < windows.length; i++) {
      const w = windows[i];
      if (w.kCGWindowOwnerPID === $1 && w.kCGWindowLayer === 0) {
        found = String(w.kCGWindowNumber);
        break;
      }
    }
    found;
  " 2>/dev/null
}

case "$MODE" in
  --rows)    render_rows ;;
  --editors) render_editors ;;
  --live)    live_capture ;;
  all)       render_rows; render_editors; live_capture ;;
  *)         echo "usage: $0 [--rows|--editors|--live]" >&2; exit 2 ;;
esac

echo "📁 Artefacts in $OUT_DIR"
