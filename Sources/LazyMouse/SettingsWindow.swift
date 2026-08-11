import AppKit
import SwiftUI

/// Manages the settings window itself instead of using SwiftUI's `Settings` scene.
///
/// The Settings scene cannot be opened reliably from a MenuBarExtra in menu style:
/// `SettingsLink` is not rendered in a working state there, and the widely used detour via
/// the undocumented `showSettingsWindow:` selector depends on the macOS version. An own
/// NSWindow is independent of both.
@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()

    private var window: NSWindow?

    private init() {}

    func show(model: MouseModel) {
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView(model: model))
            let created = NSWindow(contentViewController: hosting)
            created.title = "Einstellungen"
            created.styleMask = [.titled, .closable]
            // Without this macOS releases the window on close, and a second call would
            // reach into a dead reference.
            created.isReleasedWhenClosed = false
            created.center()
            window = created
        }
        // The window is the only place where battery and DPI can be read — values refreshed
        // once a minute could well be stale here.
        model.refresh()
        // A pure menu bar app is not active; without this the window would appear behind.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
