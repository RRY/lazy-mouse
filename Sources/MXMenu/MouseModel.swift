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
    @Published var batteryPercent: Int?
    @Published var charging = false
    @Published var currentDPI: Int?
    @Published var scrollMode: SmartShiftFeature.Mode?

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
            statusMessage = "Verbunden"
            refresh()
            // Batterie ändert sich träge; ein Intervall von einer Minute reicht.
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
        case .failed(let message):
            connected = false
            statusMessage = message.contains("nicht gefunden")
                ? "Maus nicht gefunden — eingeschaltet und gekoppelt?"
                : "Kein Zugriff — Eingabeüberwachung erlaubt?"
        case .idle:
            connected = false
            statusMessage = "Nicht verbunden"
        }
    }

    func refresh() {
        worker.perform { device -> (Int?, Bool, Int?, SmartShiftFeature.Mode?) in
            let battery = try? BatteryFeature(device: device).status()
            let dpi = try? AdjustableDPIFeature(device: device).currentDPI()
            let scroll = try? SmartShiftFeature(device: device).status()
            return (battery?.percentage, battery?.chargingStatus == .charging, dpi?.current, scroll?.mode)
        } completion: { [weak self] result in
            guard let self = self, case .success(let values) = result else { return }
            Task { @MainActor in
                self.batteryPercent = values.0
                self.charging = values.1
                self.currentDPI = values.2
                self.scrollMode = values.3
                if let dpi = values.2, let index = self.cycleSteps.firstIndex(of: dpi) {
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
