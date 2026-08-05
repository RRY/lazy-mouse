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
        // Das Menü enthält bewusst nur Aktionen: reiner Text wird darin als deaktivierter
        // Eintrag gezeichnet und ist dadurch schlecht lesbar. Batterie und DPI stehen im
        // Symbol beziehungsweise im Einstellungsfenster.
        if model.connected {
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
            // Ein erneuter Verbindungsversuch scheitert zwangsläufig, deshalb führt der
            // Eintrag direkt zur einzigen Stelle, an der sich das beheben lässt.
            // Woran es hakt, steht im Einstellungsfenster.
            Button("Eingabeüberwachung öffnen …") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
                    NSWorkspace.shared.open(url)
                }
            }
        } else {
            Button("Erneut verbinden") { model.connect() }
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
