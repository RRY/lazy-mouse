import Foundation

/// Feature 0x2110 (SmartShift) — steuert den Wechsel zwischen eingerastetem ("Ratchet")
/// und freilaufendem Scrollrad.
public struct SmartShiftFeature {
    public static let featureID: UInt16 = 0x2110

    public enum Mode: UInt8 {
        case freespin = 1
        case ratchet = 2
        case auto = 0
    }

    public struct Status {
        public let mode: Mode
        /// Schwelle (0-50), ab der im Auto-Modus in den Freilauf gewechselt wird.
        public let autoDisengageThreshold: Int
    }

    private let device: HIDPPDevice

    public init(device: HIDPPDevice) {
        self.device = device
    }

    /// Function 0x00: GetRatchetControlMode
    public func status() throws -> Status {
        let response = try device.call(feature: SmartShiftFeature.featureID, function: 0x00)
        guard response.params.count >= 2 else { throw HIDPPError.malformedResponse }
        let mode = Mode(rawValue: response.params[0]) ?? .auto
        return Status(mode: mode, autoDisengageThreshold: Int(response.params[1]))
    }

    /// Function 0x01: SetRatchetControlMode
    public func setMode(_ mode: Mode, threshold: Int = 0) throws {
        try device.call(feature: SmartShiftFeature.featureID, function: 0x01, params: [mode.rawValue, UInt8(clamping: threshold)])
    }
}
