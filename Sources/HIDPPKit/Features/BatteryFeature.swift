import Foundation

/// Feature 0x1004 (Unified Battery) — auf allen aktuellen Logitech-Geräten inkl. MX Master 3S
/// die Standard-Batterie-Feature. Byte-Layout unten nach bestem verfügbaren Protokollwissen;
/// falls die Prozentzahl auf echter Hardware unplausibel wirkt, zuerst `rawStatus()` prüfen,
/// um die Offsets empirisch zu verifizieren.
public struct BatteryFeature {
    public static let featureID: UInt16 = 0x1004

    public enum ChargingStatus: UInt8 {
        case discharging = 0
        case charging = 1
        case chargingSlow = 2
        case chargeComplete = 3
        case chargeError = 4
        case unknown = 0xFF

        init(raw: UInt8) {
            self = ChargingStatus(rawValue: raw) ?? .unknown
        }
    }

    public struct Status {
        public let percentage: Int
        public let chargingStatus: ChargingStatus
        public let externalPowerConnected: Bool
    }

    private let device: HIDPPDevice

    public init(device: HIDPPDevice) {
        self.device = device
    }

    /// Function 0x01: GetStatus
    public func status() throws -> Status {
        let response = try device.call(feature: BatteryFeature.featureID, function: 0x01)
        guard response.params.count >= 4 else { throw HIDPPError.malformedResponse }
        let percentage = Int(response.params[0])
        let charging = ChargingStatus(raw: response.params[2])
        let externalPower = (response.params[3] & 0x01) != 0
        return Status(percentage: percentage, chargingStatus: charging, externalPowerConnected: externalPower)
    }

    /// Rohantwort für Diagnose/Kalibrierung der Byte-Offsets gegen echte Hardware.
    public func rawStatus() throws -> [UInt8] {
        try device.call(feature: BatteryFeature.featureID, function: 0x01).params
    }
}
