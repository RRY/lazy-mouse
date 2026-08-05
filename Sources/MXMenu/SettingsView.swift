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
            if !model.connected {
                Section {
                    // Ohne Gerätezugriff bleiben alle folgenden Einstellungen wirkungslos;
                    // der Grund gehört deshalb an den Anfang, nicht ans Ende.
                    Label(model.statusMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    if model.permissionDenied {
                        Text("Nach dem Erteilen muss die App neu gestartet werden.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Eingabeüberwachung öffnen …") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    } else {
                        Button("Erneut verbinden") { model.connect() }
                    }
                }
            }

            Section("Gerät") {
                LabeledContent("Status", value: model.connected ? model.productName : model.statusMessage)
                if let percent = model.batteryPercent {
                    LabeledContent("Batterie", value: "\(percent)%\(model.charging ? " (lädt)" : "")")
                }
                if let dpi = model.currentDPI {
                    LabeledContent("Aktuelle DPI", value: "\(dpi)")
                }
                if let host = model.hostChannel {
                    LabeledContent("Kanal", value: "\(host.channel) von \(host.total)")
                }
                if let firmware = model.firmwareVersion {
                    LabeledContent("Firmware", value: firmware)
                }
                if let serial = model.serialNumber {
                    LabeledContent("Seriennummer", value: serial)
                        .textSelection(.enabled)
                }
            }

            // Kein Feld für den Gerätenamen: änderbar ist nur ein geräteinternes Feld
            // (0x0007), das nirgends in macOS auftaucht — der in den Bluetooth-Einstellungen
            // gezeigte Name (0x0005) ist schreibgeschützt. Wer das Feld dennoch setzen will,
            // nimmt `mxctl name`.

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
            // Alles hier drin greift auf die Maus zu und wäre ohne Verbindung wirkungslos.
            .disabled(!model.connected)

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

                Toggle("Scrollrichtung umkehren", isOn: Binding(
                    get: { model.verticalInverted },
                    set: { model.setVerticalInverted($0) }
                ))

                Toggle("Daumenrad umkehren", isOn: Binding(
                    get: { model.horizontalInverted },
                    set: { model.setHorizontalInverted($0) }
                ))

                Text("Die Umkehrung wirkt im Gerät und kommt zur Scrollrichtung aus den "
                     + "Systemeinstellungen hinzu — beide zusammen heben sich auf.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(!model.connected)
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }
}
