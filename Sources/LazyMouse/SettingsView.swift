import SwiftUI
import HIDPPKit

struct SettingsView: View {
    @ObservedObject var model: MouseModel

    /// Eingabepuffer für den Gerätenamen, damit nicht jeder Tastendruck ans Gerät geht.
    @State private var editedName = ""

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

            Section("Gerätename") {
                // Erst beim Bestätigen schreiben: sonst ginge pro Tastendruck ein
                // Schreibvorgang ans Gerät.
                TextField("Name", text: $editedName)
                    .onSubmit { model.setFriendlyName(editedName) }
                Text(model.friendlyNameProblem
                     ?? "Mit Return bestätigen, nur ASCII-Zeichen. macOS übernimmt den Namen "
                     + "erst beim nächsten Verbinden und zeigt davon die ersten "
                     + "\(MouseModel.displayedNameLength) Zeichen.")
                    .font(.caption)
                    .foregroundStyle(model.friendlyNameProblem == nil ? Color.secondary : Color.orange)
            }
            .disabled(!model.connected)
            .onAppear { editedName = model.friendlyName }
            .onChange(of: model.friendlyName) { _, new in editedName = new }

            Section("DPI-Umschaltung per Taste") {
                Toggle("Aktiviert", isOn: $model.cycleEnabled)

                Picker("Taste", selection: $model.cycleButtonCID) {
                    ForEach(model.availableButtons, id: \.cid) { button in
                        Text(button.name).tag(button.cid)
                    }
                }
                .onChange(of: model.cycleButtonCID) { _, _ in
                    // Umleitung folgt der neuen Auswahl, sonst bliebe die alte Taste umgeleitet.
                    model.applyCycleState()
                }

                TextField("Stufen", text: $model.cycleStepsRaw)
                    .onSubmit { model.refresh() }

                // Der zulässige Bereich kommt vom Gerät; Werte daneben lehnt es ab.
                Text(model.cycleStepsProblem
                     ?? {
                         let limits = model.dpiRange.map {
                             "Erlaubt sind \($0.min) bis \($0.max) in Schritten von \($0.step). "
                         } ?? ""
                         return limits + "Kommagetrennte Werte, mindestens zwei. Solange die "
                             + "Umschaltung aktiv ist, löst die gewählte Taste ihre normale "
                             + "Funktion nicht mehr aus."
                     }())
                    .font(.caption)
                    .foregroundStyle(model.cycleStepsProblem == nil ? Color.secondary : Color.orange)
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

                // Kein Schalter für die Feinauflösung: das Gerät kennt dafür nur 1 oder 15
                // Schritte je Raste, und 15 wirkt in der Praxis wie 15-fache Geschwindigkeit
                // statt wie feineres Scrollen. Zwischenstufen gibt es nicht (siehe README).
                // Für Versuche bleibt `mxctl scroll hires`.

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
