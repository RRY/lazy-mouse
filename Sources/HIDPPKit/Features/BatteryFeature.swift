import Foundation

/// Feature 0x1004 (Unified Battery) — the standard battery feature on all current Logitech
/// devices including the MX Master 3S. The byte layout below follows the best available
/// protocol knowledge; if the percentage looks implausible on real hardware, check
/// `rawStatus()` first to verify the offsets empirically.
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

    /// Raw response, for diagnosing and calibrating the byte offsets against real hardware.
    public func rawStatus() throws -> [UInt8] {
        try device.call(feature: BatteryFeature.featureID, function: 0x01).params
    }
}
