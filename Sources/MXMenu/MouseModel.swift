import Foundation
import SwiftUI
import HIDPPKit

/// Zustand der Maus für die Oberfläche. Alle HID-Zugriffe laufen über den Worker-Thread;
/// veröffentlichte Eigenschaften werden ausschließlich auf der Hauptqueue geschrieben.
@MainActor
final class MouseModel: ObservableObject {

    @Published var productName: String = "—"
    @Published var connected = false
    @Published var statusMessage = "Nicht verbunden"
    /// Steuert, ob ein erneuter Verbindungsversuch überhaupt Sinn ergibt: eine fehlende
    /// Berechtigung kann nur der Nutzer in den Systemeinstellungen beheben.
    @Published var permissionDenied = false
    @Published var batteryPercent: Int?
    @Published var charging = false
    @Published var currentDPI: Int?
    @Published var scrollMode: SmartShiftFeature.Mode?
    @Published var verticalInverted = false
    @Published var horizontalInverted = false
    @Published var firmwareVersion: String?
    @Published var serialNumber: String?
    @Published var hostChannel: (channel: Int, total: Int)?

    // Einstellungen werden von Hand in UserDefaults gespiegelt statt über @AppStorage:
    // dessen Wrapper löst in einer ObservableObject-Klasse kein objectWillChange aus, die
    // Oberfläche würde Änderungen also nicht zuverlässig nachziehen.
    @Published var cycleEnabled: Bool {
        didSet {
            defaults.set(cycleEnabled, forKey: Keys.cycleEnabled)
            applyCycleState()
        }
    }
    @Published var cycleButtonCID: Int {
        didSet {
            // Erst die bisherige Taste freigeben, sonst bliebe sie umgeleitet zurück.
            releaseButton(cid: UInt16(oldValue))
            defaults.set(cycleButtonCID, forKey: Keys.cycleButtonCID)
            applyCycleState()
        }
    }
    @Published var cycleStepsRaw: String {
        didSet { defaults.set(cycleStepsRaw, forKey: Keys.cycleSteps) }
    }

    /// Autostart. Der wahre Zustand liegt im System, nicht in UserDefaults — deshalb wird
    /// nach jedem Schreiben zurückgelesen, damit eine abgelehnte Änderung sichtbar wird.
    @Published var launchAtLogin: Bool = LoginItem.isEnabled
    @Published var launchAtLoginProblem: String?

    func setLaunchAtLogin(_ enabled: Bool) {
        if let error = LoginItem.setEnabled(enabled) {
            launchAtLoginProblem = error
        } else if enabled && LoginItem.isBlockedBySystem {
            launchAtLoginProblem = "In den Systemeinstellungen unter Anmeldeobjekte freigeben."
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
    }

    private let defaults = UserDefaults.standard
    private let worker = HIDPPWorker()
    private var stepIndex = 0
    private var refreshTimer: Timer?

    init() {
        cycleEnabled = defaults.bool(forKey: Keys.cycleEnabled)
        let storedCID = defaults.integer(forKey: Keys.cycleButtonCID)
        cycleButtonCID = storedCID == 0 ? 0x00C3 : storedCID
        cycleStepsRaw = defaults.string(forKey: Keys.cycleSteps) ?? "1000,1600,2400"

        worker.onNotification = { [weak self] body in
            Task { @MainActor in self?.handleNotification(body) }
        }
        connect()
        // Nach einem Neustart steht die Umleitung im Gerät nicht mehr — erneut setzen.
        if cycleEnabled { applyCycleState() }
    }

    func connect() {
        switch worker.start() {
        case .connected(let name):
            productName = name
            connected = true
            permissionDenied = false
            statusMessage = "Verbunden"
            loadStaticInfo()
            refresh()
            // Batterie ändert sich träge; ein Intervall von einer Minute reicht.
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
        case .failed(let error):
            connected = false
            permissionDenied = (error as? HIDPPError)?.isPermissionDenied ?? false
            if permissionDenied {
                statusMessage = "Kein Zugriff — Eingabeüberwachung nicht erlaubt"
            } else if case HIDPPError.deviceNotFound = error {
                statusMessage = "Maus nicht gefunden — eingeschaltet und gekoppelt?"
            } else {
                statusMessage = "\(error)"
            }
        case .idle:
            connected = false
            permissionDenied = false
            statusMessage = "Nicht verbunden"
        }
    }

    func refresh() {
        worker.perform { device -> Snapshot in
            let battery = try? BatteryFeature(device: device).status()
            return Snapshot(
                batteryPercent: battery?.percentage,
                charging: battery?.chargingStatus == .charging,
                dpi: try? AdjustableDPIFeature(device: device).currentDPI().current,
                scrollMode: try? SmartShiftFeature(device: device).status().mode,
                verticalInverted: (try? HiResWheelFeature(device: device).isInverted()) ?? false,
                horizontalInverted: (try? ThumbwheelFeature(device: device).isInverted()) ?? false,
                // Kann sich ändern, wenn am Gerät der Kanal umgeschaltet wird.
                hostChannel: try? HostChannelFeature(device: device).current()
            )
        } completion: { [weak self] result in
            guard let self = self, case .success(let snapshot) = result else { return }
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

    func setDPI(_ dpi: Int) {
        worker.perform { device in
            try AdjustableDPIFeature(device: device).setDPI(dpi)
        } completion: { [weak self] result in
            Task { @MainActor in
                if case .success = result { self?.currentDPI = dpi }
            }
        }
    }

    /// Ein Lesedurchgang. Als eigener Typ, weil ein Tupel mit sechs Feldern an der
    /// Aufrufstelle nur noch aus Indizes bestünde.
    private struct Snapshot {
        let batteryPercent: Int?
        let charging: Bool
        let dpi: Int?
        let scrollMode: SmartShiftFeature.Mode?
        let verticalInverted: Bool
        let horizontalInverted: Bool
        let hostChannel: (channel: Int, total: Int)?
    }

    /// Firmware und Seriennummer ändern sich nicht von selbst — einmal beim Verbinden zu
    /// lesen genügt, statt sie in jeden Minutentakt aufzunehmen.
    private func loadStaticInfo() {
        worker.perform { device -> (String?, String?) in
            let info = DeviceInfoFeature(device: device)
            return (try? info.firmwareVersion(), try? info.serialNumber())
        } completion: { [weak self] result in
            guard case .success(let values) = result else { return }
            Task { @MainActor in
                self?.firmwareVersion = values.0
                self?.serialNumber = values.1
            }
        }
    }

    func setVerticalInverted(_ inverted: Bool) {
        worker.perform { device in
            try HiResWheelFeature(device: device).setInverted(inverted)
        } completion: { [weak self] result in
            Task { @MainActor in
                if case .success = result { self?.verticalInverted = inverted }
            }
        }
    }

    func setHorizontalInverted(_ inverted: Bool) {
        worker.perform { device in
            try ThumbwheelFeature(device: device).setInverted(inverted)
        } completion: { [weak self] result in
            Task { @MainActor in
                if case .success = result { self?.horizontalInverted = inverted }
            }
        }
    }

    func setScrollMode(_ mode: SmartShiftFeature.Mode) {
        worker.perform { device in
            try SmartShiftFeature(device: device).setMode(mode)
        } completion: { [weak self] result in
            Task { @MainActor in
                if case .success = result { self?.scrollMode = mode }
            }
        }
    }

    /// Aktiviert bzw. löst die Umleitung der Taste, über die DPI-Stufen geschaltet werden.
    func applyCycleState() {
        let cid = UInt16(cycleButtonCID)
        let enabled = cycleEnabled
        worker.perform { device in
            let buttons = SpecialButtonsFeature(device: device)
            // Zurücksetzen statt divert=off: das stellt auch persist/rawXY auf Default.
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

    /// Muss beim Beenden laufen — eine umgeleitete Taste bliebe sonst wirkungslos zurück.
    /// Blockiert bewusst, damit der Befehl das Gerät noch vor dem Prozessende erreicht.
    func releaseButtonOnQuit() {
        guard cycleEnabled else { return }
        let cid = UInt16(cycleButtonCID)
        worker.performSync { device in
            try SpecialButtonsFeature(device: device).resetReporting(controlID: cid)
        }
    }

    private func handleNotification(_ body: [UInt8]) {
        guard cycleEnabled, body.count >= 5 else { return }
        let cid = (UInt16(body[3]) << 8) | UInt16(body[4])
        // Nur der Druck schaltet weiter; das Loslassen meldet CID 0.
        guard cid == UInt16(cycleButtonCID) else { return }
        let steps = cycleSteps
        stepIndex = (stepIndex + 1) % steps.count
        setDPI(steps[stepIndex])
    }
}
