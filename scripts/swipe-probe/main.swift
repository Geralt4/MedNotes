import SwiftUI
import AppKit

// Records what this Mac's trackpad actually sends during a left swipe, so the
// swipe-to-delete thresholds in MedNotes/UI/Theme/SwipeActions.swift can be
// set from measurements instead of guesses.
//
//   swift scripts/swipe-probe/main.swift
//
// Swipe left over the window a few times — the way you would to delete a row —
// then press Q. Each gesture prints one line; the summary at the end is the
// part worth pasting back.

final class Recorder {
    struct Gesture {
        var events = 0
        var fingerTravel: CGFloat = 0
        var coastEvents = 0
        var coastTravel: CGFloat = 0
        var releaseVelocity: CGFloat = 0
        var peakVelocity: CGFloat = 0
        var duration: TimeInterval = 0
        var touchTravel: CGFloat?
        var precise = true
        var inverted = false
    }

    private(set) var done: [Gesture] = []
    private var g = Gesture()
    private var live = false
    private var velocity: CGFloat = 0
    private var last: TimeInterval = 0
    private var start: TimeInterval = 0
    private var touchStartX: CGFloat?
    private var touchDeviceWidth: CGFloat = 0

    private func touchX(_ e: NSEvent) -> CGFloat? {
        let touches = e.touches(matching: .touching, in: nil)
        guard !touches.isEmpty else { return nil }
        touchDeviceWidth = touches.first?.deviceSize.width ?? 0
        return touches.map(\.normalizedPosition.x).reduce(0, +) / CGFloat(touches.count)
    }

    func handle(_ e: NSEvent) {
        if !e.momentumPhase.isEmpty {
            guard live else { return }
            if e.momentumPhase.contains(.ended) || e.momentumPhase.contains(.cancelled) {
                finish()
            } else {
                g.coastEvents += 1
                g.coastTravel += e.scrollingDeltaX
            }
            return
        }

        if e.phase.contains(.began) {
            g = Gesture()
            g.precise = e.hasPreciseScrollingDeltas
            g.inverted = e.isDirectionInvertedFromDevice
            velocity = 0
            live = true
            start = e.timestamp
            last = e.timestamp
            touchStartX = touchX(e)
            return
        }

        guard live else { return }

        if e.phase.contains(.changed) {
            let dt = e.timestamp - last
            if dt > 0 {
                let v = e.scrollingDeltaX / dt
                velocity = velocity * 0.6 + v * 0.4
                g.peakVelocity = min(g.peakVelocity, velocity)
            }
            last = e.timestamp
            g.events += 1
            g.fingerTravel += e.scrollingDeltaX
            if let s = touchStartX, let now = touchX(e) {
                g.touchTravel = (now - s) * touchDeviceWidth
            }
            return
        }

        if e.phase.contains(.ended) || e.phase.contains(.cancelled) {
            g.releaseVelocity = velocity
            g.duration = e.timestamp - start
            // A coast may still follow; if it does, `finish` runs at its end.
            if e.timestamp - start >= 0 { pendingRelease = true }
            return
        }
    }

    private var pendingRelease = false

    private func finish() {
        live = false
        pendingRelease = false
        record()
    }

    func flushIfIdle() {
        if pendingRelease && live && g.coastEvents == 0 { finish() }
    }

    private func record() {
        guard g.events > 2, g.fingerTravel < -5 else { return }
        done.append(g)
        let t = g.touchTravel.map { String(format: "%.0fpt", -$0) } ?? "n/a"
        print(String(format:
            "  swipe %2d: fingers %5.0fpt over %2d events in %3.0fms | release %6.0f pt/s (peak %6.0f) | coast %5.0fpt over %2d | touch %@",
            done.count, -g.fingerTravel, g.events, g.duration * 1000,
            -g.releaseVelocity, -g.peakVelocity, -g.coastTravel, g.coastEvents, t))
    }

    func summary() {
        guard !done.isEmpty else {
            print("\nNo swipes recorded — nothing to report.")
            return
        }
        func avg(_ f: (Gesture) -> CGFloat) -> CGFloat {
            done.map(f).reduce(0, +) / CGFloat(done.count)
        }
        let finger = -avg { $0.fingerTravel }
        let coast = -avg { $0.coastTravel }
        let release = -avg { $0.releaseVelocity }
        print("\n================ SUMMARY (\(done.count) swipes) ================")
        print(String(format: "  finger travel      %6.0f pt   (per swipe, average)", finger))
        print(String(format: "  coast travel       %6.0f pt", coast))
        print(String(format: "  reach, 50%% coast    %6.0f pt   <- what the gesture can actually reach",
                     finger + coast * 0.5))
        print(String(format: "  release velocity   %6.0f pt/s", release))
        print(String(format: "  precise deltas     %@", done.last!.precise ? "yes" : "NO (not a trackpad?)"))
        print(String(format: "  direction inverted %@", done.last!.inverted ? "yes (natural scrolling on)" : "no"))
        if let t = done.last!.touchTravel {
            print(String(format: "  finger on glass    %6.0f pt   (absolute, from touch data)", -t))
        } else {
            print("  finger on glass    n/a      (no touch data on these events)")
        }
        print("\n  MedNotes currently commits a delete at 110 pt.")
        print("  Paste this whole summary back and the thresholds get set from it.")
        print("==============================================================")
    }
}

let recorder = Recorder()

struct ProbeView: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "hand.draw").font(.system(size: 34, weight: .light))
            Text("Swipe left here").font(.title3.weight(.semibold))
            Text("Two fingers, the way you would to delete a row.\nDo it 5 or 6 times, then press Q.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(width: 420, height: 260)
    }
}

class D: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    func applicationDidFinishLaunching(_ n: Notification) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "MedNotes swipe probe"
        window.contentView = NSHostingView(rootView: ProbeView())
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.contentView?.allowedTouchTypes = [.indirect]

        NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { e in
            recorder.handle(e)
            return nil                     // keep the window from scrolling
        }
        NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { e in
            if e.charactersIgnoringModifiers?.lowercased() == "q" {
                recorder.summary()
                NSApp.terminate(nil)
            }
            return e
        }
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            recorder.flushIfIdle()
        }
        print("Swipe left over the window. Press Q when done.\n")
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ a: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ n: Notification) { }
}

let app = NSApplication.shared
let d = D()
app.delegate = d
app.setActivationPolicy(.regular)
app.run()
