import Foundation

/// Feature 0x2121 (HiRes Wheel) — the vertical scroll wheel.
///
/// The mode lives in a flag byte. The assignment follows the protocol documentation; what is
/// empirically confirmed is only that every bit can be set and read back. Changing one bit
/// preserves the others — `target` in particular must never be set by accident, because the
/// wheel then reports its movement to HID++ instead of scrolling normally, which means it
/// stops working.
public struct HiResWheelFeature {
    public static let featureID: UInt16 = 0x2121

    private enum Flag {
        /// Wheel reports to HID++ instead of HID — scrolling stops working.
        static let target: UInt8 = 0x01
        static let resolution: UInt8 = 0x02
        static let invert: UInt8 = 0x04
    }

    private let device: HIDPPDevice

    public init(device: HIDPPDevice) {
        self.device = device
    }

    /// Function 0x01: GetWheelMode
    private func modeFlags() throws -> UInt8 {
        let response = try device.call(feature: HiResWheelFeature.featureID, function: 0x01)
        guard let flags = response.params.first else { throw HIDPPError.malformedResponse }
        return flags
    }

    public func isInverted() throws -> Bool {
        try modeFlags() & Flag.invert != 0
    }

    /// High resolution: the wheel reports `multiplier` steps per detent instead of one, for
    /// finer and therefore smoother scrolling.
    public func isHighResolution() throws -> Bool {
        try modeFlags() & Flag.resolution != 0
    }

    /// Function 0x00: GetWheelCapability — multiplier between high and normal resolution.
    public func resolutionMultiplier() throws -> Int {
        let response = try device.call(feature: HiResWheelFeature.featureID, function: 0x00)
        guard let multiplier = response.params.first else { throw HIDPPError.malformedResponse }
        return Int(multiplier)
    }

    /// Function 0x02: SetWheelMode. Changes individual bits and preserves the rest.
    private func setFlag(_ flag: UInt8, _ enabled: Bool) throws {
        var flags = try modeFlags()
        flags = enabled ? (flags | flag) : (flags & ~flag)
        // Safety net: this bit would mute the wheel and must never be set.
        flags &= ~Flag.target
        try device.call(feature: HiResWheelFeature.featureID, function: 0x02, params: [flags])
    }

    public func setInverted(_ inverted: Bool) throws {
        try setFlag(Flag.invert, inverted)
    }

    public func setHighResolution(_ enabled: Bool) throws {
        try setFlag(Flag.resolution, enabled)
    }
}

/// Feature 0x2150 (Thumbwheel) — the horizontal thumb wheel.
///
/// `SetThumbwheelReporting` takes two bytes: reporting mode and inversion, each 0 or 1. The
/// device rejects other values — 0x02 in the first byte is answered with INVALID_ARGUMENT,
/// in the second it is silently discarded. `GetThumbwheelStatus` returns both.
public struct ThumbwheelFeature {
    public static let featureID: UInt16 = 0x2150

    private let device: HIDPPDevice

    public init(device: HIDPPDevice) {
        self.device = device
    }

    /// Function 0x01: GetThumbwheelStatus -> (reporting mode, inversion)
    private func status() throws -> (reportingDiverted: Bool, inverted: Bool) {
        let response = try device.call(feature: ThumbwheelFeature.featureID, function: 0x01)
        guard response.params.count >= 2 else { throw HIDPPError.malformedResponse }
        return (response.params[0] != 0, response.params[1] != 0)
    }

    public func isInverted() throws -> Bool {
        try status().inverted
    }

    /// Function 0x02: SetThumbwheelReporting
    public func setInverted(_ inverted: Bool) throws {
        // Leave the reporting mode alone: diverted, the wheel reports to HID++ instead of scrolling.
        let current = try status()
        try device.call(
            feature: ThumbwheelFeature.featureID,
            function: 0x02,
            params: [current.reportingDiverted ? 1 : 0, inverted ? 1 : 0]
        )
    }
}
