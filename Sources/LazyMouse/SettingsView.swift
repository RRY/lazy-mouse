import SwiftUI
import HIDPPKit

struct SettingsView: View {
    @ObservedObject var model: MouseModel

    /// Input buffer for the device name, so not every keystroke reaches the device.
    @State private var editedName = ""

    var body: some View {
        Form {
            if !model.connected {
                Section {
                    // Without device access every setting below is without effect, so the
                    // reason belongs at the top rather than the bottom.
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
                // Replaces the former status field: that showed the same name the section
                // below already offered for editing. Whether a connection exists is stated at
                // the top of the window anyway whenever something is wrong.
                TextField(LocalizedStringKey("label.designation"), text: $editedName)
                    .onSubmit { model.setFriendlyName(editedName) }
                    .onChange(of: editedName) { _, new in
                        // The device truncates overlong names silently, so the limit belongs
                        // in the input field already.
                        if new.count > model.friendlyNameMaxLength {
                            editedName = String(new.prefix(model.friendlyNameMaxLength))
                        }
                    }
                    .help(String(format: String(localized: "hint.deviceName"),
                                 model.friendlyNameMaxLength, MouseModel.displayedNameLength))
                // Only problems appear on the form: an error message you have to hover for
                // would not be one.
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
                // Toggle and button selection in one: the "Disabled" entry replaces the
                // former on/off switch, which did nothing without a button chosen anyway.
                Picker(LocalizedStringKey("label.button"), selection: Binding(
                    get: { model.cycleEnabled ? model.cycleButtonCID : 0 },
                    set: { selection in
                        guard selection != 0 else {
                            model.cycleEnabled = false
                            return
                        }
                        // Button first, then enable: setting the button releases the previous
                        // one, enabling diverts the new one.
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
                    // The permitted range comes from the device; it rejects values beside it.
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
            // Everything in here touches the mouse and would be without effect when offline.
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

                // No switch for the high resolution: the device offers only 1 or 15 steps per
                // detent for it, and 15 feels like fifteen times the speed rather than finer
                // scrolling. There are no values in between (see the README). `mxctl scroll
                // hires` remains for experiments.

            }
            .disabled(!model.connected)
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }
}
