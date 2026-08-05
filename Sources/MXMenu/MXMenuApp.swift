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

        Settings {
            SettingsView(model: model)
        }
    }
}

struct MenuContent: View {
    @ObservedObject var model: MouseModel

    var body: some View {
        if model.connected {
            Text(model.productName)
            if let percent = model.batteryPercent {
                Text("Batterie: \(percent)%\(model.charging ? " (lädt)" : "")")
            }
            if let dpi = model.currentDPI {
                Text("DPI: \(dpi)")
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
        } else {
            Text(model.statusMessage)
            if model.permissionDenied {
                // Ohne diese Berechtigung liefert IOHIDManagerOpen kIOReturnNotPermitted.
                // Ein erneuter Versuch scheitert zwangsläufig, deshalb wird er hier nicht
                // angeboten; die App muss nach dem Erteilen ohnehin neu starten.
                Button("Eingabeüberwachung öffnen …") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
                        NSWorkspace.shared.open(url)
                    }
                }
            } else {
                Button("Erneut verbinden") { model.connect() }
            }
        }

        Divider()
        Toggle("Beim Anmelden starten", isOn: Binding(
            get: { model.launchAtLogin },
            set: { model.setLaunchAtLogin($0) }
        ))

        Divider()
        Button("Einstellungen …") {
            // SettingsLink funktioniert in der Menü-Darstellung von MenuBarExtra nicht;
            // die Systemaktion öffnet die Settings-Szene dagegen zuverlässig. Ohne
            // vorheriges activate erscheint das Fenster hinter anderen Apps.
            NSApp.activate(ignoringOtherApps: true)
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
        .keyboardShortcut(",", modifiers: .command)
        Button("Beenden") {
            model.releaseButtonOnQuit()
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }
}
