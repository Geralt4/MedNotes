#!/bin/bash
# Drives MedNotes' real swipe controller with your trackpad and reports what it
# decides for each gesture. Results are written to /tmp/mednotes-swipe-probe.txt
set -e
cd "$(dirname "$0")/../.."
BUILD=$(mktemp -d)
cp MedNotes/UI/Theme/SwipeActions.swift "$BUILD/Swipe.swift"
cat >> "$BUILD/Swipe.swift" <<'SEAM'

// Test seam: `handleScroll` and the gesture state are file-private, so the
// probe reads them through an extension compiled into the same file.
extension SwipeRevealController {
    func probeFeed(_ e: NSEvent) -> NSEvent? { handleScroll(e) }
    var probeAxisIsHorizontal: Bool? {
        guard let a = axis else { return nil }
        return a == .horizontal
    }
    var probeTravelX: CGFloat { travelX }
    var probeTravelY: CGFloat { travelY }
    var probeHasRow: Bool { gestureId != nil }
}
SEAM
cp scripts/swipe-probe/probe2.swift "$BUILD/main.swift"
swiftc -O "$BUILD/main.swift" "$BUILD/Swipe.swift" -o "$BUILD/probe2"
"$BUILD/probe2"
