import SwiftUI
import AppKit

enum Chrome {
    enum Space { static let xxs: CGFloat = 2 }
    enum Radius { static let badge: CGFloat = 7 }
}

let controller = SwipeRevealController()
let ids = (0..<8).map { _ in UUID() }
var log: [String] = []
var outcomes: [String] = []

func emit(_ line: String) { print(line); log.append(line) }

struct ProbeRow: View {
    let index: Int
    var body: some View {
        HStack {
            Text("Swipe left on any of these rows").font(.headline).lineLimit(1)
            Spacer()
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

struct ProbeView: View {
    var body: some View {
        VStack(spacing: 0) {
            Text("Point at a row, swipe left as if deleting. 5-6 times, then press Q.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).padding(10)
            List(selection: .constant(UUID?.none)) {
                ForEach(Array(ids.enumerated()), id: \.element) { i, id in
                    ProbeRow(index: i)
                        .swipeToDelete(id: id, label: "Delete")
                        .tag(id)
                }
            }
            .listStyle(.sidebar)
            .swipeToDeleteContainer(controller) { _ in outcomes.append("DELETE") }
        }
        .frame(width: 420, height: 380)
    }
}

final class Watch {
    var n = 0
    var firstEvents: [String] = []
    var live = false

    func note(_ e: NSEvent) {
        guard e.momentumPhase.isEmpty else { return }
        if e.phase.contains(.began) {
            live = true; firstEvents = []
            return
        }
        guard live else { return }
        if e.phase.contains(.changed), firstEvents.count < 3 {
            firstEvents.append(String(format: "dx%+.0f/dy%+.0f", e.scrollingDeltaX, e.scrollingDeltaY))
        }
        if e.phase.contains(.ended) || e.phase.contains(.cancelled) {
            live = false
            n += 1
            let axis = controller.probeAxisIsHorizontal
            let axisText = axis == nil ? "NONE " : (axis! ? "HORIZ" : "VERT ")
            let outcome = outcomes.count > n - 1 ? "DELETED" :
                          (controller.activeId != nil ? "opened " : "nothing")
            emit(String(format: "  swipe %d: axis %@ | travel x%.0f y%.0f | row %@ | -> %@   first events: %@",
                        n, axisText, controller.probeTravelX, controller.probeTravelY,
                        controller.probeHasRow ? "yes" : "NO ", outcome,
                        firstEvents.joined(separator: " ")))
        }
    }
}
let watch = Watch()

class D: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    func applicationDidFinishLaunching(_ n: Notification) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 380),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "MedNotes swipe probe 2"
        window.contentView = NSHostingView(rootView: ProbeView())
        window.center(); window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Runs after the controller's own monitor, so it observes the decision.
        NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { e in
            DispatchQueue.main.async { watch.note(e) }
            return e
        }
        NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { e in
            if e.charactersIgnoringModifiers?.lowercased() == "q" {
                emit("\n================ RESULT ================")
                let deletes = outcomes.filter { $0 == "DELETE" }.count
                emit("  swipes: \(watch.n)   deletes: \(deletes)")
                emit(deletes >= max(1, watch.n - 1)
                     ? "  VERDICT: full swipe deletes reliably."
                     : "  VERDICT: still failing — the lines above say why.")
                emit("========================================")
                try? log.joined(separator: "\n")
                    .write(toFile: "/tmp/mednotes-swipe-probe.txt", atomically: true, encoding: .utf8)
                print("\n(saved to /tmp/mednotes-swipe-probe.txt)")
                NSApp.terminate(nil)
            }
            return e
        }
        print("Point at a row and swipe left. Press Q when done.\n")
    }
}
let app = NSApplication.shared
let d = D(); app.delegate = d; app.setActivationPolicy(.regular); app.run()
