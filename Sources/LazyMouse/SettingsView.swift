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
                        Text(LocalizedStringKey("hint.permissionRestart"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button(LocalizedStringKey("action.openInputMonitoring")) {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    } else {
                        Button(LocalizedStringKey("action.reconnect")) { model.connect() }
                    }
                }
            }

            Section(LocalizedStringKey("section.device")) {
                // Ersetzt das frühere Statusfeld: das zeigte denselben Namen nochmals, den
                // der Abschnitt darunter schon zum Bearbeiten anbot. Ob eine Verbindung
                // besteht, steht bei Problemen ohnehin oben im Fenster.
                TextField(LocalizedStringKey("label.designation"), text: $editedName)
                    .onSubmit { model.setFriendlyName(editedName) }
                    .onChange(of: editedName) { _, new in
                        // Das Gerät kürzt zu lange Namen stillschweigend; die Grenze gehört
                        // deshalb schon ins Eingabefeld.
                        if new.count > model.friendlyNameMaxLength {
                            editedName = String(new.prefix(model.friendlyNameMaxLength))
                        }
                    }
                    .help(String(format: String(localized: "hint.deviceName"),
                                 model.friendlyNameMaxLength, MouseModel.displayedNameLength))
                // Nur Probleme stehen auf der Maske: eine Fehlermeldung, die man erst durch
                // Zeigen findet, wäre keine.
                if let problem = model.friendlyNameProblem {
                    Text(problem)
                        .font(.caption)
                        .foregroundStyle(Color.orange)
                }

                if let percent = model.batteryPercent {
                    LabeledContent(LocalizedStringKey("label.battery"),
                                   value: String(format: String(localized: model.charging ? "value.batteryCharging" : "value.battery"), percent))
                }
                if let dpi = model.currentDPI {
                    LabeledContent(LocalizedStringKey("label.currentDPI"), value: "\(dpi)")
                }
                if let host = model.hostChannel {
                    LabeledContent(LocalizedStringKey("label.channel"), value: String(format: String(localized: "value.channel"), host.channel, host.total))
                }
                if let firmware = model.firmwareVersion {
                    LabeledContent(LocalizedStringKey("label.firmware"), value: firmware)
                }
                if let serial = model.serialNumber {
                    LabeledContent(LocalizedStringKey("label.serial"), value: serial)
                        .textSelection(.enabled)
                }
            }
            .disabled(!model.connected)
            .onAppear { editedName = model.friendlyName }
            .onChange(of: model.friendlyName) { _, new in editedName = new }


            Section(LocalizedStringKey("section.dpiCycle")) {
                // Schalter und Tastenauswahl in einem: die Auswahl "Deaktiviert" ersetzt
                // den früheren Ein/Aus-Schalter, der ohne gewählte Taste ohnehin nichts tat.
                Picker(LocalizedStringKey("label.button"), selection: Binding(
                    get: { model.cycleEnabled ? model.cycleButtonCID : 0 },
                    set: { selection in
                        guard selection != 0 else {
                            model.cycleEnabled = false
                            return
                        }
                        // Erst die Taste, dann einschalten: das Setzen der Taste gibt die
                        // vorherige frei, das Einschalten leitet die neue um.
                        if model.cycleButtonCID != selection { model.cycleButtonCID = selection }
                        if !model.cycleEnabled { model.cycleEnabled = true }
                    }
                )) {
                    Text(LocalizedStringKey("label.disabled")).tag(0)
                    ForEach(model.availableButtons, id: \.cid) { button in
                        Text(button.name).tag(button.cid)
                    }
                }
                .help(LocalizedStringKey("hint.cycleEnabled"))

                TextField(LocalizedStringKey("label.steps"), text: $model.cycleStepsRaw)
                    .onSubmit { model.refresh() }
                    // Der zulässige Bereich kommt vom Gerät; Werte daneben lehnt es ab.
                    .help({
                        let limits = model.dpiRange.map {
                            String(format: String(localized: "hint.dpiLimits"), $0.min, $0.max, $0.step)
                        } ?? ""
                        return limits + String(localized: "hint.dpiSteps")
                    }())

                if let problem = model.cycleStepsProblem {
                    Text(problem)
                        .font(.caption)
                        .foregroundStyle(Color.orange)
                }
            }
            // Alles hier drin greift auf die Maus zu und wäre ohne Verbindung wirkungslos.
            .disabled(!model.connected)

            Section(LocalizedStringKey("section.start")) {
                Toggle(LocalizedStringKey("label.launchAtLogin"), isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }
                ))
                .help(LocalizedStringKey("hint.launchAtLogin"))
                if let problem = model.launchAtLoginProblem {
                    HStack(spacing: 6) {
                        Text(problem)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button(LocalizedStringKey("action.open")) { LoginItem.openLoginItemsSettings() }
                            .buttonStyle(.link)
                    }
                }
            }

            Section(LocalizedStringKey("section.wheel")) {
                Picker(LocalizedStringKey("label.mode"), selection: Binding(
                    get: { model.scrollMode ?? .ratchet },
                    set: { model.setScrollMode($0) }
                )) {
                    Text(LocalizedStringKey("label.ratchet")).tag(SmartShiftFeature.Mode.ratchet)
                    Text(LocalizedStringKey("label.freespin")).tag(SmartShiftFeature.Mode.freespin)
                }
                .pickerStyle(.segmented)
                .help(LocalizedStringKey("hint.wheelMode"))

                Toggle(LocalizedStringKey("label.invertWheel"), isOn: Binding(
                    get: { model.verticalInverted },
                    set: { model.setVerticalInverted($0) }
                ))
                .help(LocalizedStringKey("hint.invert"))

                Toggle(LocalizedStringKey("label.invertThumb"), isOn: Binding(
                    get: { model.horizontalInverted },
                    set: { model.setHorizontalInverted($0) }
                ))
                .help(LocalizedStringKey("hint.invert"))

                // Kein Schalter für die Feinauflösung: das Gerät kennt dafür nur 1 oder 15
                // Schritte je Raste, und 15 wirkt in der Praxis wie 15-fache Geschwindigkeit
                // statt wie feineres Scrollen. Zwischenstufen gibt es nicht (siehe README).
                // Für Versuche bleibt `mxctl scroll hires`.

            }
            .disabled(!model.connected)
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }
}
