import Foundation
import SwiftUI
import HIDPPKit

/// Zustand der Maus für die Oberfläche. Alle HID-Zugriffe laufen über den Worker-Thread;
/// veröffentlichte Eigenschaften werden ausschließlich auf der Hauptqueue geschrieben.
@MainActor
final class MouseModel: ObservableObject {

    @Published var productName: String = "—"
    @Published var connected = false
    @Published var statusMessage = String(localized: "status.notConnected")
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
    /// Tasten, die für die DPI-Umschaltung angeboten werden. Gelesen wird vom Gerät, damit
    /// die Auswahl auch bei anderen Modellen stimmt.
    @Published var availableButtons: [(cid: Int, name: String)] = []
    @Published var friendlyName = ""
    @Published var friendlyNameProblem: String?
    /// Höchstlänge des Gerätenamens, wie sie das Gerät meldet.
    @Published var friendlyNameMaxLength = 18
    /// Zulässiger DPI-Bereich, wie ihn das Gerät meldet. Werte außerhalb oder neben dem
    /// Raster lehnt es mit INVALID_ARGUMENT ab.
    @Published var dpiRange: (min: Int, max: Int, step: Int)?

    /// Beschreibt, was am eingetragenen Stufen-Text nicht zum Gerät passt.
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

    /// Zeichen, die macOS vom Gerätenamen übernimmt. Das Gerät speichert mehr (18), zeigt
    /// in den Bluetooth-Einstellungen erscheint aber nur der gekürzte Anfang.
    static let displayedNameLength = 14

    /// Tastenname in der Sprache des Systems. Bewusst hier statt in `HIDPPKit`: die
    /// Bibliothek kennt keine Sprachdateien, ihre Namen dienen dem CLI.
    static func localizedButtonName(for cid: UInt16) -> String {
        let key = String(format: "button.0x%04X", cid)
        let localized = String(localized: String.LocalizationValue(key))
        // Unbekannte Control-ID: der Schlüssel kommt unübersetzt zurück.
        guard localized != key else {
            return String(format: String(localized: "button.unknown"), cid)
        }
        return localized
    }

    /// Nur Tasten, deren angestammte Funktion entbehrlich ist. Zurück, Vorwärts und die
    /// mittlere Taste sind in ihrer Standardbelegung nützlicher als eine DPI-Umschaltung,
    /// und die virtuelle Gestentaste ist gar keine Taste. Findet sich auf einem fremden
    /// Modell keine davon, bleibt es bei allen umleitbaren — sonst wäre die Funktion dort
    /// ohne Not tot.
    private static let preferredCycleButtons: Set<Int> = [0x00C3, 0x00C4]
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
        worker.onConnectionChange = { [weak self] isConnected in
            Task { @MainActor in self?.handleConnectionChange(isConnected) }
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
            statusMessage = String(localized: "status.connected")
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
                statusMessage = String(localized: "status.noPermission")
            } else if case HIDPPError.deviceNotFound = error {
                statusMessage = String(localized: "status.deviceNotFound")
            } else {
                statusMessage = "\(error)"
            }
        case .idle:
            connected = false
            permissionDenied = false
            statusMessage = String(localized: "status.notConnected")
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

    /// Schreibt den Gerätenamen. macOS übernimmt ihn erst beim nächsten Verbinden und kürzt
    /// ihn dabei auf `displayedNameLength` Zeichen.
    func setFriendlyName(_ newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            friendlyNameProblem = String(localized: "problem.nameEmpty")
            return
        }
        worker.perform { device -> String in
            let feature = FriendlyNameFeature(device: device)
            try feature.setName(trimmed)
            // Zurücklesen: das Gerät kürzt zu lange Namen selbst.
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
        worker.perform { device in
            try AdjustableDPIFeature(device: device).setDPI(dpi)
        } completion: { [weak self] result in
            Task { @MainActor in
                if case .success = result { self?.currentDPI = dpi }
            }
        }
    }

    /// Werte, die sich nicht von selbst ändern und einmal beim Verbinden gelesen werden.
    private struct StaticInfo {
        let firmware: String?
        let serial: String?
        let buttons: [(cid: Int, name: String)]
        let friendlyName: String
        let friendlyNameMaxLength: Int
        let dpiRange: (min: Int, max: Int, step: Int)?
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
                // Die Obergrenze meldet das Gerät selbst; 18 ist nur der Rückfall.
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
                // Die gespeicherte Taste kann von einem anderen Gerät stammen; dann auf die
                // erste vorhandene ausweichen, sonst zeigte die Auswahl ins Leere.
                if !info.buttons.isEmpty, !info.buttons.contains(where: { $0.cid == self.cycleButtonCID }) {
                    self.cycleButtonCID = info.buttons[0].cid
                }
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

    /// Verlust und Wiederkehr des Geräts, etwa rund um den Ruhezustand des Rechners.
    private func handleConnectionChange(_ isConnected: Bool) {
        connected = isConnected
        guard isConnected else {
            statusMessage = String(localized: "status.deviceNotFound")
            // Anzeigewerte verwerfen, statt veraltete stehen zu lassen.
            batteryPercent = nil
            currentDPI = nil
            hostChannel = nil
            return
        }
        permissionDenied = false
        statusMessage = String(localized: "status.connected")
        productName = worker.productName
        loadStaticInfo()
        refresh()
        // Das Gerät verliert die Umleitung beim Trennen; ohne dies bliebe die DPI-Taste
        // nach dem Aufwachen wirkungslos, obwohl der Schalter sie als aktiv ausweist.
        if cycleEnabled { applyCycleState() }
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
