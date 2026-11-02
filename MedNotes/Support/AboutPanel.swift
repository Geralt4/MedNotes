import AppKit

/// The standard About panel, with the third-party licenses in its credits and
/// the build number next to the version.
///
/// The panel shows "Version 2.0 (123)" from the two version strings it is
/// given, and a scrolling credits area: here, the licenses of the packages the
/// app ships, from `Licenses.txt` (made from the pinned package versions and
/// checked by `scripts/check_licenses.py`).
enum AboutPanel {
    static let licensesResource = "Licenses"

    /// The text of `Licenses.txt` in `bundle`, or nil if the bundle lacks it.
    static func licenseText(bundle: Bundle = .main) -> String? {
        guard let url = bundle.url(forResource: licensesResource, withExtension: "txt") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// The credits: a heading, then the license texts in a fixed-width font.
    static func credits(bundle: Bundle = .main) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let heading = String(localized: "Open-source licenses")
        result.append(NSAttributedString(
            string: heading + "\n\n",
            attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize),
                         .foregroundColor: NSColor.labelColor]))
        let body = licenseText(bundle: bundle) ?? ""
        result.append(NSAttributedString(
            string: body,
            attributes: [.font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
                         .foregroundColor: NSColor.labelColor]))
        return result
    }

    /// What the panel is given: the version, the build next to it, the credits.
    static func options(bundle: Bundle = .main) -> [NSApplication.AboutPanelOptionKey: Any] {
        var options: [NSApplication.AboutPanelOptionKey: Any] = [.credits: credits(bundle: bundle)]
        if let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
            options[.applicationVersion] = version
        }
        if let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String {
            options[.version] = build
        }
        return options
    }

    @MainActor
    static func show() {
        NSApp.orderFrontStandardAboutPanel(options: options())
        NSApp.activate(ignoringOtherApps: true)
    }
}
