import AppKit
import SwiftUI

/// Verwaltet das Einstellungsfenster selbst, statt SwiftUIs `Settings`-Szene zu nutzen.
///
/// Aus einer MenuBarExtra in Menü-Darstellung lässt sich die Settings-Szene nicht
/// zuverlässig öffnen: `SettingsLink` wird dort nicht funktionsfähig gerendert, und der
/// verbreitete Umweg über den undokumentierten Selektor `showSettingsWindow:` hängt von der
/// macOS-Version ab. Ein eigenes NSWindow ist unabhängig davon.
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
            // Ohne das gibt macOS das Fenster beim Schließen frei; ein zweiter Aufruf
            // würde dann auf eine tote Referenz zugreifen.
            created.isReleasedWhenClosed = false
            created.center()
            window = created
        }
        // Eine reine Menüleisten-App ist nicht aktiv; ohne das erschiene das Fenster hinten.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
