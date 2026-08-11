import Foundation
import SwiftUI
import HIDPPKit

/// State of the mouse for the interface. Every HID access goes through the worker thread;
/// published properties are written on the main queue only.
@MainActor
final class MouseModel: ObservableObject {

    @Published var productName: String = "—"
    @Published var connected = false
    @Published var statusMessage = String(localized: "status.notConnected")
    /// Governs whether another connection attempt makes sense at all: only the user can fix
    /// a missing permission, in System Settings.
    @Published var permissionDenied = false
    @Published var batteryPercent: Int?
    @Published var charging = false
    @Published var currentDPI: Int?
    @Published var scrollMode: SmartShiftFeature.Mode?
    @Published var verticalInverted = false
    @Published var horizontalInverted = false
    @Published var firmwareVersion: String?
    @Published var serialNumber: String?
    /// Buttons offered for DPI switching. Read from the device so the selection is right on
    /// other models too.
    @Published var availableButtons: [(cid: Int, name: String)] = []
    @Published var friendlyName = ""
    @Published var friendlyNameProblem: String?
    /// Maximum length of the device name as reported by the device.
    @Published var friendlyNameMaxLength = 18
    /// Permitted DPI range as reported by the device. It rejects values outside it or beside
    /// the grid with INVALID_ARGUMENT.
    @Published var dpiRange: (min: Int, max: Int, step: Int)?

    /// Describes what about the entered steps does not fit the device.
    var cycleStepsProblem: String? {
        guard let range = dpiRange else { return nil }
        let parsed = cycleStepsRaw.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard parsed.count >= 2 else { return String(localized: "problem.stepsTooFew") }
        let invalid = parsed.filter {
            $0 < range.min || $0 > range.max || ($0 - range.min) % range.step != 0
        }
        guard invalid.isEmpty else {
            return String(format: String(localized: "problem.stepsRejected"), invalid.map(String.init).joined(separator: ", "))
        }
        return nil
    }

    /// Characters macOS takes from the device name. The device stores more (18), but only the
    /// truncated beginning shows up in the Bluetooth settings.
    static let displayedNameLength = 14

    /// Button name in the system language. Deliberately here rather than in `HIDPPKit`: the
    /// library has no string files, its names serve the CLI.
    static func localizedButtonName(for cid: UInt16) -> String {
        let key = String(format: "button.0x%04X", cid)
        let localized = String(localized: String.LocalizationValue(key))
        // Unknown control ID: the key comes back untranslated.
        guard localized != key else {
            return String(format: String(localized: "button.unknown"), cid)
        }
        return localized
    }

    /// Only buttons whose native function is expendable. Back, forward and the middle button
    /// are more useful in their default assignment than as a DPI switch, and the virtual
    /// gesture button is not a button at all. If an unfamiliar model carries none of these,
    /// all divertable ones remain — otherwise the feature would be dead there for no reason.
    private static let preferredCycleButtons: Set<Int> = [0x00C3, 0x00C4]
    @Published var hostChannel: (channel: Int, total: Int)?

    // Settings are mirrored into UserDefaults by hand rather than through @AppStorage: that
    // wrapper does not raise objectWillChange in an ObservableObject class, so the interface
    // would not follow changes reliably.
    @Published var cycleEnabled: Bool {
        didSet {
            defaults.set(cycleEnabled, forKey: Keys.cycleEnabled)
            applyCycleState()
        }
    }
    @Published var cycleButtonCID: Int {
        didSet {
            // Release the previous button first, or it would stay diverted.
            releaseButton(cid: UInt16(oldValue))
            defaults.set(cycleButtonCID, forKey: Keys.cycleButtonCID)
            applyCycleState()
        }
    }
    @Published var cycleStepsRaw: String {
        didSet { defaults.set(cycleStepsRaw, forKey: Keys.cycleSteps) }
    }

    /// Launch at login. The true state lives in the system, not in UserDefaults — hence the
    /// read-back after every write, so a rejected change becomes visible.
    @Published var launchAtLogin: Bool = LoginItem.isEnabled
    @Published var launchAtLoginProblem: String?

    func setLaunchAtLogin(_ enabled: Bool) {
        if let error = LoginItem.setEnabled(enabled) {
            launchAtLoginProblem = error
        } else if enabled && LoginItem.isBlockedBySystem {
            launchAtLoginProblem = String(localized: "problem.loginItemBlocked")
        } else {
            launchAtLoginProblem = nil
        }
        launchAtLogin = LoginItem.isEnabled
    }

    var cycleSteps: [Int] {
        let parsed = cycleStepsRaw.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        return parsed.count >= 2 ? parsed : [1000, 1600, 2400]
    }

    private enum Keys {
        static let cycleEnabled = "cycleEnabled"
        static let cycleButtonCID = "cycleButtonCID"
        static let cycleSteps = "cycleSteps"
        // Wanted device values. The mouse loses them when switched off, so the app holds them
        // and writes them back on every connection.
        static let desiredDPI = "desiredDPI"
        static let desiredScrollMode = "desiredScrollMode"
        static let desiredVerticalInverted = "desiredVerticalInverted"
        static let desiredHorizontalInverted = "desiredHorizontalInverted"
    }

    /// Writes the remembered values to the device.
    ///
    /// Necessary because the MX Master 3S keeps DPI and scroll direction only until it is
    /// switched off — measured on the device: after an off/on cycle it read 1000 DPI and a
    /// thumb wheel that was no longer inverted. Without writing them back the settings would
    /// be lost on every power-up. Values that were never set stay untouched.
    private func applyStoredSettings() {
        let dpi = defaults.object(forKey: Keys.desiredDPI) as? Int
        let mode = (defaults.object(forKey: Keys.desiredScrollMode) as? Int)
            .flatMap { SmartShiftFeature.Mode(rawValue: UInt8($0)) }
        let vertical = defaults.object(forKey: Keys.desiredVerticalInverted) as? Bool
        let horizontal = defaults.object(forKey: Keys.desiredHorizontalInverted) as? Bool
        guard dpi != nil || mode != nil || vertical != nil || horizontal != nil else { return }

        worker.perform { device in
            if let dpi = dpi { try? AdjustableDPIFeature(device: device).setDPI(dpi) }
            if let mode = mode { try? SmartShiftFeature(device: device).setMode(mode) }
            if let vertical = vertical { try? HiResWheelFeature(device: device).setInverted(vertical) }
            if let horizontal = horizontal { try? ThumbwheelFeature(device: device).setInverted(horizontal) }
        } completion: { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    private let defaults = UserDefaults.standard
    private let worker = HIDPPWorker()
    private var stepIndex = 0
    private var refreshTimer: Timer?
    /// Runs only while there is no usable connection.
    private var retryTimer: Timer?

    /// The connection has stopped answering.
    ///
    /// This can happen without the device disappearing: after a system start it is adopted
    /// before it is ready to answer. It used to go unnoticed because the read routine
    /// swallowed every error — the display stayed empty while still claiming a connection.
    private func handleConnectionLost() {
        connected = false
        statusMessage = String(localized: "status.deviceNotFound")
        batteryPercent = nil
        currentDPI = nil
        hostChannel = nil
        startRetrying()
    }

    /// Keeps trying in the background until the device answers. Pointless when the permission
    /// is missing — only the user can grant that.
    private func startRetrying() {
        guard retryTimer == nil, !permissionDenied else { return }
        retryTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.attemptRecovery() }
        }
    }

    private func stopRetrying() {
        retryTimer?.invalidate()
        retryTimer = nil
    }

    private func attemptRecovery() {
        worker.perform { device in
            // A single request suffices as proof that the device answers again.
            _ = try BatteryFeature(device: device).status()
        } completion: { [weak self] result in
            guard let self = self, case .success = result else { return }
            Task { @MainActor in
                self.stopRetrying()
                self.handleConnectionChange(true)
            }
        }
    }

    init() {
        cycleEnabled = defaults.bool(forKey: Keys.cycleEnabled)
        let storedCID = defaults.integer(forKey: Keys.cycleButtonCID)
        cycleButtonCID = storedCID == 0 ? 0x00C3 : storedCID
        cycleStepsRaw = defaults.string(forKey: Keys.cycleSteps) ?? "1000,1600,2400"

        worker.onNotification = { [weak self] body in
            Task { @MainActor in self?.handleNotification(body) }
        }
        worker.onConnectionChange = { [weak self] isConnected in
            Task { @MainActor in self?.handleConnectionChange(isConnected) }
        }
        connect()
        // After a restart the diversion is gone from the device — set it again.
        if cycleEnabled { applyCycleState() }
    }

    func connect() {
        switch worker.start() {
        case .connected(let name):
            productName = name
            connected = true
            permissionDenied = false
            statusMessage = String(localized: "status.connected")
            loadStaticInfo()
            applyStoredSettings()
            refresh()
            // Battery changes slowly; an interval of one minute is enough.
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
        case .failed(let error):
            connected = false
            permissionDenied = (error as? HIDPPError)?.isPermissionDenied ?? false
            if permissionDenied {
                statusMessage = String(localized: "status.noPermission")
            } else if case HIDPPError.deviceNotFound = error {
                statusMessage = String(localized: "status.deviceNotFound")
            } else {
                statusMessage = "\(error)"
            }
            // At system start the app often runs before Bluetooth has connected the mouse.
            startRetrying()
        case .idle:
            connected = false
            permissionDenied = false
            statusMessage = String(localized: "status.notConnected")
        }
    }

    func refresh() {
        worker.perform { device -> Snapshot in
            // Deliberately without try?: if this request already fails, the connection is
            // dead. With try? a snapshot full of nil would come back and the app would keep
            // believing it is connected — exactly the "no warning triangle, no data" picture.
            let battery = try BatteryFeature(device: device).status()
            return Snapshot(
                batteryPercent: battery.percentage,
                charging: battery.chargingStatus == .charging,
                dpi: try? AdjustableDPIFeature(device: device).currentDPI().current,
                scrollMode: try? SmartShiftFeature(device: device).status().mode,
                verticalInverted: (try? HiResWheelFeature(device: device).isInverted()) ?? false,
                horizontalInverted: (try? ThumbwheelFeature(device: device).isInverted()) ?? false,
                // Can change when the channel is switched on the device.
                hostChannel: try? HostChannelFeature(device: device).current()
            )
        } completion: { [weak self] result in
            guard let self = self else { return }
            guard case .success(let snapshot) = result else {
                Task { @MainActor in self.handleConnectionLost() }
                return
            }
            Task { @MainActor in
                self.batteryPercent = snapshot.batteryPercent
                self.charging = snapshot.charging
                self.currentDPI = snapshot.dpi
                self.scrollMode = snapshot.scrollMode
                self.verticalInverted = snapshot.verticalInverted
                self.horizontalInverted = snapshot.horizontalInverted
                self.hostChannel = snapshot.hostChannel
                if let dpi = snapshot.dpi, let index = self.cycleSteps.firstIndex(of: dpi) {
                    self.stepIndex = index
                }
            }
        }
    }

    /// Writes the device name. macOS only picks it up on the next connection and truncates it
    /// to `displayedNameLength` characters.
    func setFriendlyName(_ newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            friendlyNameProblem = String(localized: "problem.nameEmpty")
            return
        }
        worker.perform { device -> String in
            let feature = FriendlyNameFeature(device: device)
            try feature.setName(trimmed)
            // Read back: the device truncates overlong names itself.
            return try feature.name()
        } completion: { [weak self] result in
            Task { @MainActor in
                switch result {
                case .success(let stored):
                    self?.friendlyName = stored
                    self?.friendlyNameProblem = stored == trimmed
                        ? nil
                        : String(format: String(localized: "problem.nameTruncated"), stored.count, stored)
                case .failure(let error):
                    self?.friendlyNameProblem = "\(error)"
                }
            }
        }
    }

    func setDPI(_ dpi: Int) {
        defaults.set(dpi, forKey: Keys.desiredDPI)
        worker.perform { device in
            try AdjustableDPIFeature(device: device).setDPI(dpi)
        } completion: { [weak self] result in
            Task { @MainActor in
                if case .success = result { self?.currentDPI = dpi }
            }
        }
    }

    /// Values that do not change by themselves, read once on connecting.
    private struct StaticInfo {
        let firmware: String?
        let serial: String?
        let buttons: [(cid: Int, name: String)]
        let friendlyName: String
        let friendlyNameMaxLength: Int
        let dpiRange: (min: Int, max: Int, step: Int)?
    }

    /// One read pass. Its own type because a six-field tuple would leave the call site as
    /// nothing but indices.
    private struct Snapshot {
        let batteryPercent: Int?
        let charging: Bool
        let dpi: Int?
        let scrollMode: SmartShiftFeature.Mode?
        let verticalInverted: Bool
        let horizontalInverted: Bool
        let hostChannel: (channel: Int, total: Int)?
    }

    /// Firmware and serial number do not change by themselves — reading them once on
    /// connecting is enough, rather than folding them into every minute's refresh.
    private func loadStaticInfo() {
        worker.perform { device -> StaticInfo in
            let info = DeviceInfoFeature(device: device)
            let nameFeature = FriendlyNameFeature(device: device)
            let controls = (try? SpecialButtonsFeature(device: device).listControls()) ?? []
            let divertable = controls.filter(\.isDivertable).map {
                (cid: Int($0.controlID), name: MouseModel.localizedButtonName(for: $0.controlID))
            }
            let preferred = divertable.filter { MouseModel.preferredCycleButtons.contains($0.cid) }
            return StaticInfo(
                firmware: try? info.firmwareVersion(),
                serial: try? info.serialNumber(),
                buttons: preferred.isEmpty ? divertable : preferred,
                friendlyName: (try? nameFeature.name()) ?? "",
                // The device reports the upper limit itself; 18 is only the fallback.
                friendlyNameMaxLength: (try? nameFeature.lengths().max) ?? 18,
                dpiRange: (try? AdjustableDPIFeature(device: device).dpiList().range).flatMap {
                    $0.map { (min: $0.min, max: $0.max, step: $0.step) }
                }
            )
        } completion: { [weak self] result in
            guard case .success(let info) = result else { return }
            Task { @MainActor in
                guard let self = self else { return }
                self.firmwareVersion = info.firmware
                self.serialNumber = info.serial
                self.availableButtons = info.buttons
                self.friendlyName = info.friendlyName
                self.friendlyNameMaxLength = info.friendlyNameMaxLength
                self.dpiRange = info.dpiRange
                // The stored button may come from a different device; fall back to the first
                // available one, or the selection would point nowhere.
                if !info.buttons.isEmpty, !info.buttons.contains(where: { $0.cid == self.cycleButtonCID }) {
                    self.cycleButtonCID = info.buttons[0].cid
                }
            }
        }
    }

    func setVerticalInverted(_ inverted: Bool) {
        defaults.set(inverted, forKey: Keys.desiredVerticalInverted)
        worker.perform { device in
            try HiResWheelFeature(device: device).setInverted(inverted)
        } completion: { [weak self] result in
            Task { @MainActor in
                if case .success = result { self?.verticalInverted = inverted }
            }
        }
    }

    func setHorizontalInverted(_ inverted: Bool) {
        defaults.set(inverted, forKey: Keys.desiredHorizontalInverted)
        worker.perform { device in
            try ThumbwheelFeature(device: device).setInverted(inverted)
        } completion: { [weak self] result in
            Task { @MainActor in
                if case .success = result { self?.horizontalInverted = inverted }
            }
        }
    }

    func setScrollMode(_ mode: SmartShiftFeature.Mode) {
        defaults.set(Int(mode.rawValue), forKey: Keys.desiredScrollMode)
        worker.perform { device in
            try SmartShiftFeature(device: device).setMode(mode)
        } completion: { [weak self] result in
            Task { @MainActor in
                if case .success = result { self?.scrollMode = mode }
            }
        }
    }

    /// Enables or releases the diversion of the button that steps through DPI levels.
    func applyCycleState() {
        let cid = UInt16(cycleButtonCID)
        let enabled = cycleEnabled
        worker.perform { device in
            let buttons = SpecialButtonsFeature(device: device)
            // Reset rather than divert=off: that also returns persist and rawXY to default.
            if enabled {
                try buttons.setDivert(controlID: cid, enabled: true)
            } else {
                try buttons.resetReporting(controlID: cid)
            }
        } completion: { _ in }
    }

    private func releaseButton(cid: UInt16) {
        worker.perform { device in
            try SpecialButtonsFeature(device: device).resetReporting(controlID: cid)
        } completion: { _ in }
    }

    /// Has to run on quit — a diverted button would stay dead otherwise. Blocks deliberately
    /// so the command reaches the device before the process ends.
    func releaseButtonOnQuit() {
        guard cycleEnabled else { return }
        let cid = UInt16(cycleButtonCID)
        worker.performSync { device in
            try SpecialButtonsFeature(device: device).resetReporting(controlID: cid)
        }
    }

    /// Loss and return of the device, around system sleep for instance.
    private func handleConnectionChange(_ isConnected: Bool) {
        connected = isConnected
        guard isConnected else {
            statusMessage = String(localized: "status.deviceNotFound")
            // Discard the displayed values rather than leaving stale ones.
            batteryPercent = nil
            currentDPI = nil
            hostChannel = nil
            return
        }
        stopRetrying()
        permissionDenied = false
        statusMessage = String(localized: "status.connected")
        productName = worker.productName
        loadStaticInfo()
        applyStoredSettings()
        refresh()
        // The device loses the diversion when disconnecting; without this the DPI button
        // would stay dead after waking while the switch still claims it is active.
        if cycleEnabled { applyCycleState() }
    }

    private func handleNotification(_ body: [UInt8]) {
        guard cycleEnabled, body.count >= 5 else { return }
        let cid = (UInt16(body[3]) << 8) | UInt16(body[4])
        // Only the press advances; the release reports CID 0.
        guard cid == UInt16(cycleButtonCID) else { return }
        let steps = cycleSteps
        stepIndex = (stepIndex + 1) % steps.count
        setDPI(steps[stepIndex])
    }
}
