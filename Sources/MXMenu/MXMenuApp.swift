import SwiftUI
import AppKit
import HIDPPKit

@main
struct MXMenuApp: App {
    @StateObject private var model = MouseModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            // Der Batteriestand steht direkt im Symbol, damit der häufigste Blick
            // in die Menüleiste ohne Klick auskommt. Ein Problem soll ebenso ohne
            // Klick erkennbar sein, deshalb das abweichende Symbol.
            HStack(spacing: 3) {
                Image(systemName: model.connected ? "computermouse" : "exclamationmark.triangle")
                if let percent = model.batteryPercent {
                    Text("\(percent)%")
                }
            }
            // MenuBarExtra zeichnet sein Label nicht neu, wenn sich nur der Inhalt ändert.
            // Die wechselnde Identität erzwingt den Neuaufbau.
            .id("\(model.connected)-\(model.batteryPercent ?? -1)")
        }
        // Kein Settings-Szene: das Fenster verwaltet SettingsWindowController, weil es sich
        // aus einer MenuBarExtra in Menü-Darstellung sonst nicht zuverlässig öffnen lässt.
    }
}

struct MenuContent: View {
    @ObservedObject var model: MouseModel

    var body: some View {
        if model.connected {
            // Als Button statt als Text: reiner Text wird im Menü als deaktivierter
            // Eintrag gezeichnet und damit grau — unabhängig von der gesetzten Textfarbe.
            // Die Zeilen lösen deshalb das Neueinlesen aus, statt nur Attrappe zu sein.
            Button(model.productName) { model.refresh() }
            if let percent = model.batteryPercent {
                Button("Batterie: \(percent)%\(model.charging ? " (lädt)" : "")") { model.refresh() }
            }
            if let dpi = model.currentDPI {
                Button("DPI: \(dpi)") { model.refresh() }
            }
            Divider()

            Menu("DPI") {
                ForEach(model.cycleSteps, id: \.self) { step in
                    Button {
                        model.setDPI(step)
                    } label: {
                        Text(step == model.currentDPI ? "✓ \(step)" : "\(step)")
                    }
                }
            }

            Menu("Scrollrad") {
                Button {
                    model.setScrollMode(.ratchet)
                } label: {
                    Text(model.scrollMode == .ratchet ? "✓ Gerastert" : "Gerastert")
                }
                Button {
                    model.setScrollMode(.freespin)
                } label: {
                    Text(model.scrollMode == .freespin ? "✓ Freilauf" : "Freilauf")
                }
            }

            Toggle("DPI-Taste aktiv", isOn: $model.cycleEnabled)
        } else if model.permissionDenied {
            // Ohne diese Berechtigung liefert IOHIDManagerOpen kIOReturnNotPermitted.
            // Ein erneuter Verbindungsversuch scheitert zwangsläufig, deshalb führt die
            // Zeile direkt zur einzigen Stelle, an der sich das beheben lässt.
            Button("Kein Zugriff — Eingabeüberwachung öffnen …") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
                    NSWorkspace.shared.open(url)
                }
            }
        } else {
            Button("\(model.statusMessage) — erneut verbinden") { model.connect() }
        }

        Divider()
        Toggle("Beim Anmelden starten", isOn: Binding(
            get: { model.launchAtLogin },
            set: { model.setLaunchAtLogin($0) }
        ))

        Divider()
        Button("Einstellungen …") {
            SettingsWindowController.shared.show(model: model)
        }
        .keyboardShortcut(",", modifiers: .command)
        Button("Beenden") {
            model.releaseButtonOnQuit()
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }
}
