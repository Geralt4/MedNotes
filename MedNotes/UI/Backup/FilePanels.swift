import AppKit
import UniformTypeIdentifiers

/// What an open or save panel asks the user for, as plain values: a test
/// reads what the app would have shown without creating a panel.
struct FilePanelRequest: Equatable {
    enum Kind: Equatable {
        /// A new file, named `suggestedName` to begin with: Back Up's archive.
        case save(suggestedName: String)
        /// One existing file of one of `types`: the archive to restore.
        case file(types: [UTType])
        /// One folder: where the Markdown export goes (`canCreate`), or the
        /// legacy data to import.
        case folder(canCreate: Bool)
    }

    var kind: Kind
    var message: String
    /// Where the panel opens, when not where it last did.
    var directoryURL: URL? = nil
}

/// The open and save panels `AppSession` shows. Only `AppSession.choose(_:)`
/// calls `run`; see there for why it must not be called from a task.
///
/// Tests pass their own. In the sandboxed app another process (the
/// powerbox) draws a real panel on whatever screen is in front, and even
/// creating one starts that process.
@MainActor
protocol FilePanels: AnyObject {
    /// Shows the panel application-modally and returns the chosen URL, or nil
    /// when the user cancels. Returns only once the panel has closed, as
    /// `runModal()` does.
    func run(_ request: FilePanelRequest) -> URL?
    /// Closes the panel `run` is showing, as its Cancel button would. Does
    /// nothing when none is up.
    func cancelRunning()
}

/// The part of a panel `AppKitFilePanels` drives. NSSavePanel, and with it
/// NSOpenPanel, has all of it; a test passes a stand-in, since even creating
/// a real panel starts the powerbox.
@MainActor
protocol ModalFilePanel: AnyObject {
    var url: URL? { get }
    func runModal() -> NSApplication.ModalResponse
    func cancel(_ sender: Any?)
}

extension NSSavePanel: ModalFilePanel {}

/// NSSavePanel and NSOpenPanel, application-modal as they always were.
@MainActor
final class AppKitFilePanels: FilePanels {
    private let makePanel: ((FilePanelRequest) -> ModalFilePanel)?
    private var running: ModalFilePanel?

    /// `makePanel` is for tests: it returns a stand-in, never a real panel.
    init(makePanel: ((FilePanelRequest) -> ModalFilePanel)? = nil) {
        self.makePanel = makePanel
    }

    func run(_ request: FilePanelRequest) -> URL? {
        let panel: ModalFilePanel
        if let makePanel {
            panel = makePanel(request)
        } else {
            // A test that forgot to pass its own panels must not put a real
            // one on the tester's screen.
            guard !AppSession.isTestHost else { return nil }
            panel = Self.panel(for: request)
        }
        running = panel
        defer { running = nil }
        return panel.runModal() == .OK ? panel.url : nil
    }

    func cancelRunning() {
        guard let panel = running else { return }
        // The Cancel button's action: it ends the modal session, and
        // `runModal` returns `.cancel` once its loop unwinds.
        panel.cancel(nil)
        // The session stays the panel's until then, so this repeats the same
        // request. It keeps the promise that a lock never leaves a panel
        // modal, should one ever ignore its Cancel.
        if let window = panel as? NSWindow, NSApp.modalWindow === window {
            NSApp.stopModal(withCode: .cancel)
        }
    }

    private static func panel(for request: FilePanelRequest) -> NSSavePanel {
        let panel: NSSavePanel
        switch request.kind {
        case .save(let suggestedName):
            panel = NSSavePanel()
            panel.canCreateDirectories = true
            panel.allowsOtherFileTypes = true
            panel.nameFieldStringValue = suggestedName
        case .file(let types):
            let open = NSOpenPanel()
            open.canChooseDirectories = false
            open.allowsMultipleSelection = false
            open.allowedContentTypes = types
            panel = open
        case .folder(let canCreate):
            let open = NSOpenPanel()
            open.canChooseDirectories = true
            open.canChooseFiles = false
            open.allowsMultipleSelection = false
            open.canCreateDirectories = canCreate
            panel = open
        }
        panel.message = request.message
        if let directoryURL = request.directoryURL {
            panel.directoryURL = directoryURL
        }
        return panel
    }
}
