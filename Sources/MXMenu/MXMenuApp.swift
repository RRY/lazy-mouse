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
            // in die Menüleiste ohne Klick auskommt.
            HStack(spacing: 3) {
                Image(systemName: "computermouse")
                if let percent = model.batteryPercent {
                    Text("\(percent)%")
                }
            }
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

            Divider()
            Button("Aktualisieren") { model.refresh() }
        } else {
            Text(model.statusMessage)
            Button("Erneut verbinden") { model.connect() }
        }

        Divider()
        SettingsLink { Text("Einstellungen …") }
            .keyboardShortcut(",", modifiers: .command)
        Button("Beenden") {
            model.releaseButtonOnQuit()
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }
}
