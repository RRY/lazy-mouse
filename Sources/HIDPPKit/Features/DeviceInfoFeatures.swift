import Foundation

/// Feature 0x0003 (Device Information) — Firmware-Stand und Seriennummer.
public struct DeviceInfoFeature {
    public static let featureID: UInt16 = 0x0003

    private let device: HIDPPDevice

    public init(device: HIDPPDevice) {
        self.device = device
    }

    /// Function 0x00: getDeviceInfo
    private func entityCountAndCapabilities() throws -> (count: Int, capabilities: UInt8) {
        let response = try device.call(feature: DeviceInfoFeature.featureID, function: 0x00)
        guard response.params.count >= 15 else { throw HIDPPError.malformedResponse }
        return (Int(response.params[0]), response.params[14])
    }

    /// Version der Anwendungs-Firmware, formatiert wie in den macOS-Systeminformationen
    /// (z. B. `RBM22.02_0009`).
    ///
    /// Das Gerät führt mehrere Einheiten (Bootloader, Anwendung, Hardware); maßgeblich ist
    /// die mit Typ 0. Layout je Einheit: Typ(1), Präfix(3 ASCII), Nummer(1), Revision(1),
    /// Build(2) — Nummer, Revision und Build sind BCD-kodiert, werden also hexadezimal
    /// ausgegeben, um die aufgedruckte Schreibweise zu treffen.
    public func firmwareVersion() throws -> String? {
        let (count, _) = try entityCountAndCapabilities()
        for entity in 0..<count {
            let response = try device.call(feature: DeviceInfoFeature.featureID, function: 0x01, params: [UInt8(entity)])
            let p = response.params
            guard p.count >= 8, p[0] == 0 else { continue }
            let prefix = String(bytes: p[1...3].filter { $0 >= 0x20 && $0 < 0x7F }, encoding: .ascii) ?? ""
            return String(format: "%@%02X.%02X_%02X%02X", prefix, p[4], p[5], p[6], p[7])
        }
        return nil
    }

    /// Function 0x02: getDeviceSerialNumber. Nur verfügbar, wenn Bit 0 der Capabilities
    /// gesetzt ist; sonst antwortet das Gerät mit einem Fehler.
    public func serialNumber() throws -> String? {
        let (_, capabilities) = try entityCountAndCapabilities()
        guard capabilities & 0x01 != 0 else { return nil }
        let response = try device.call(feature: DeviceInfoFeature.featureID, function: 0x02)
        let chars = response.params.prefix(12).filter { $0 >= 0x20 && $0 < 0x7F }
        return chars.isEmpty ? nil : String(bytes: chars, encoding: .ascii)
    }
}

/// Feature 0x1814 (Change Host) — hier ausschließlich lesend für die Anzeige des Kanals,
/// auf dem die Maus gerade sendet. Ein Umschalten per Software würde die Verbindung zu
/// diesem Rechner sofort trennen und ist deshalb nicht vorgesehen.
public struct HostChannelFeature {
    public static let featureID: UInt16 = 0x1814

    private let device: HIDPPDevice

    public init(device: HIDPPDevice) {
        self.device = device
    }

    /// Function 0x00: getHostInfo -> (Kanalanzahl, aktueller Kanal)
    /// Das Gerät zählt Kanäle ab 0; nach außen wird die Beschriftung 1–3 verwendet.
    public func current() throws -> (channel: Int, total: Int) {
        let response = try device.call(feature: HostChannelFeature.featureID, function: 0x00)
        guard response.params.count >= 2 else { throw HIDPPError.malformedResponse }
        return (Int(response.params[1]) + 1, Int(response.params[0]))
    }
}

/// Feature 0x0007 (Device Friendly Name) — frei wählbarer Gerätename.
public struct FriendlyNameFeature {
    public static let featureID: UInt16 = 0x0007

    private let device: HIDPPDevice

    public init(device: HIDPPDevice) {
        self.device = device
    }

    /// Function 0x00: getFriendlyNameLen -> (aktuell, Maximum, Standard)
    public func lengths() throws -> (current: Int, max: Int) {
        let response = try device.call(feature: FriendlyNameFeature.featureID, function: 0x00)
        guard response.params.count >= 2 else { throw HIDPPError.malformedResponse }
        return (Int(response.params[0]), Int(response.params[1]))
    }

    /// Function 0x01: getFriendlyName(byteIndex). Die Antwort beginnt mit dem Byte-Index,
    /// danach folgen die Zeichen; lange Namen kommen in mehreren Blöcken.
    public func name() throws -> String {
        let (length, _) = try lengths()
        var collected: [UInt8] = []
        var index = 0
        while collected.count < length, index < length {
            let response = try device.call(feature: FriendlyNameFeature.featureID, function: 0x01, params: [UInt8(index)])
            guard response.params.count > 1 else { break }
            let chunk = Array(response.params[1...])
            collected += chunk
            index += chunk.count
        }
        let printable = collected.prefix(length).filter { $0 >= 0x20 && $0 < 0x7F }
        return String(bytes: printable, encoding: .ascii) ?? ""
    }

    /// Function 0x03: setFriendlyName(byteIndex, Zeichen). Pro Aufruf passen 15 Zeichen
    /// hinter den Index in den Report, längere Namen werden in Blöcken geschrieben.
    ///
    /// Wichtig: Der Setter liegt auf Funktion 3, nicht auf 2 — Funktion 2 liefert den
    /// *Standard*namen und quittiert einen Schreibversuch klaglos, ohne etwas zu ändern.
    /// Die Antwort nennt die Zahl der übernommenen Zeichen; daran wird weitergezählt,
    /// statt die gesendete Blocklänge anzunehmen.
    public func setName(_ newName: String) throws {
        let (_, maxLength) = try lengths()
        let bytes = Array(newName.unicodeScalars
            .filter { $0.isASCII && $0.value >= 0x20 && $0.value < 0x7F }
            .map { UInt8($0.value) }
            .prefix(maxLength))
        guard !bytes.isEmpty else { throw HIDPPError.malformedResponse }

        var index = 0
        while index < bytes.count {
            let chunk = Array(bytes[index..<min(index + 15, bytes.count)])
            let response = try device.call(feature: FriendlyNameFeature.featureID, function: 0x03, params: [UInt8(index)] + chunk)
            guard let written = response.params.first, written > UInt8(index) else {
                throw HIDPPError.malformedResponse
            }
            index = Int(written)
        }
    }

    /// Function 0x04: resetFriendlyName — stellt den ab Werk vergebenen Namen wieder her.
    public func resetName() throws {
        try device.call(feature: FriendlyNameFeature.featureID, function: 0x04)
    }
}
