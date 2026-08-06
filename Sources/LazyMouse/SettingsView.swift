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
                LabeledContent(LocalizedStringKey("label.status"), value: model.connected ? model.productName : model.statusMessage)
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

            Section(LocalizedStringKey("section.deviceName")) {
                // Erst beim Bestätigen schreiben: sonst ginge pro Tastendruck ein
                // Schreibvorgang ans Gerät.
                TextField(LocalizedStringKey("label.name"), text: $editedName)
                    .onSubmit { model.setFriendlyName(editedName) }
                Text(model.friendlyNameProblem
                     ?? String(format: String(localized: "hint.deviceName"), MouseModel.displayedNameLength))
                    .font(.caption)
                    .foregroundStyle(model.friendlyNameProblem == nil ? Color.secondary : Color.orange)
            }
            .disabled(!model.connected)
            .onAppear { editedName = model.friendlyName }
            .onChange(of: model.friendlyName) { _, new in editedName = new }

            Section(LocalizedStringKey("section.dpiCycle")) {
                Toggle(LocalizedStringKey("label.enabled"), isOn: $model.cycleEnabled)

                Picker(LocalizedStringKey("label.button"), selection: $model.cycleButtonCID) {
                    ForEach(model.availableButtons, id: \.cid) { button in
                        Text(button.name).tag(button.cid)
                    }
                }
                .onChange(of: model.cycleButtonCID) { _, _ in
                    // Umleitung folgt der neuen Auswahl, sonst bliebe die alte Taste umgeleitet.
                    model.applyCycleState()
                }

                TextField(LocalizedStringKey("label.steps"), text: $model.cycleStepsRaw)
                    .onSubmit { model.refresh() }

                // Der zulässige Bereich kommt vom Gerät; Werte daneben lehnt es ab.
                Text(model.cycleStepsProblem
                     ?? {
                         let limits = model.dpiRange.map {
                             String(format: String(localized: "hint.dpiLimits"), $0.min, $0.max, $0.step)
                         } ?? ""
                         return limits + String(localized: "hint.dpiSteps")
                     }())
                    .font(.caption)
                    .foregroundStyle(model.cycleStepsProblem == nil ? Color.secondary : Color.orange)
            }
            // Alles hier drin greift auf die Maus zu und wäre ohne Verbindung wirkungslos.
            .disabled(!model.connected)

            Section(LocalizedStringKey("section.start")) {
                Toggle(LocalizedStringKey("label.launchAtLogin"), isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }
                ))
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

                Toggle(LocalizedStringKey("label.invertWheel"), isOn: Binding(
                    get: { model.verticalInverted },
                    set: { model.setVerticalInverted($0) }
                ))

                Toggle(LocalizedStringKey("label.invertThumb"), isOn: Binding(
                    get: { model.horizontalInverted },
                    set: { model.setHorizontalInverted($0) }
                ))

                // Kein Schalter für die Feinauflösung: das Gerät kennt dafür nur 1 oder 15
                // Schritte je Raste, und 15 wirkt in der Praxis wie 15-fache Geschwindigkeit
                // statt wie feineres Scrollen. Zwischenstufen gibt es nicht (siehe README).
                // Für Versuche bleibt `mxctl scroll hires`.

                Text(LocalizedStringKey("hint.invert"))
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
