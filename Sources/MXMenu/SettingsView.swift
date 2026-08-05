import SwiftUI
import HIDPPKit

struct SettingsView: View {
    @ObservedObject var model: MouseModel

    /// Die programmierbaren Tasten der MX Master 3S. Die Control-IDs stammen aus
    /// `mxctl buttons list`; nur umleitbare Tasten sind sinnvoll wählbar.
    private static let selectableButtons: [(cid: Int, name: String)] = [
        (0x00C3, "Daumentaste (Gesten)"),
        (0x00C4, "Taste am Scrollrad (Rasterung)"),
        (0x0053, "Zurück"),
        (0x0056, "Vorwärts"),
        (0x0052, "Mittlere Taste")
    ]

    var body: some View {
        Form {
            Section("Gerät") {
                LabeledContent("Status", value: model.connected ? model.productName : model.statusMessage)
                if let percent = model.batteryPercent {
                    LabeledContent("Batterie", value: "\(percent)%\(model.charging ? " (lädt)" : "")")
                }
                if let dpi = model.currentDPI {
                    LabeledContent("Aktuelle DPI", value: "\(dpi)")
                }
            }

            Section("DPI-Umschaltung per Taste") {
                Toggle("Aktiviert", isOn: $model.cycleEnabled)

                Picker("Taste", selection: $model.cycleButtonCID) {
                    ForEach(Self.selectableButtons, id: \.cid) { button in
                        Text(button.name).tag(button.cid)
                    }
                }
                .onChange(of: model.cycleButtonCID) { _, _ in
                    // Umleitung folgt der neuen Auswahl, sonst bliebe die alte Taste umgeleitet.
                    model.applyCycleState()
                }

                TextField("Stufen", text: $model.cycleStepsRaw)
                    .onSubmit { model.refresh() }

                Text("Kommagetrennte DPI-Werte, mindestens zwei. Solange die Umschaltung aktiv ist, "
                     + "löst die gewählte Taste ihre normale Funktion nicht mehr aus.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Start") {
                Toggle("Beim Anmelden starten", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }
                ))
                if let problem = model.launchAtLoginProblem {
                    HStack(spacing: 6) {
                        Text(problem)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Öffnen") { LoginItem.openLoginItemsSettings() }
                            .buttonStyle(.link)
                    }
                }
            }

            Section("Scrollrad") {
                Picker("Modus", selection: Binding(
                    get: { model.scrollMode ?? .ratchet },
                    set: { model.setScrollMode($0) }
                )) {
                    Text("Gerastert").tag(SmartShiftFeature.Mode.ratchet)
                    Text("Freilauf").tag(SmartShiftFeature.Mode.freespin)
                }
                .pickerStyle(.segmented)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }
}
