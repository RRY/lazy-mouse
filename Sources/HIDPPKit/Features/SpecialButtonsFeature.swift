import Foundation

/// Feature 0x1B04 (Special Keys / Mouse Buttons) — enumerates the programmable buttons
/// (back, forward, gesture button, wheel tilt and so on) and controls how they report.
public struct SpecialButtonsFeature {
    public static let featureID: UInt16 = 0x1B04

    public struct Control {
        public let controlID: UInt16
        public let taskID: UInt16
        public let flags: UInt8
        public let position: UInt8
        public let group: UInt8
        public let groupMask: UInt8

        /// Only divertable buttons can be put to own use. The bit doubles as a safeguard:
        /// left and right click are not divertable and therefore never show up in a
        /// selection filtered by it.
        public var isDivertable: Bool { flags & 0x20 != 0 }

        /// Readable name, as far as the control ID is known.
        public var name: String { SpecialButtonsFeature.name(forControlID: controlID) }
    }

    /// Names of the common control IDs. Unknown ones are shown in hex so the selection
    /// stays usable on unfamiliar models.
    public static func name(forControlID cid: UInt16) -> String {
        switch cid {
        case 0x0050: return "Left click"
        case 0x0051: return "Right click"
        case 0x0052: return "Middle button"
        case 0x0053: return "Back"
        case 0x0056: return "Forward"
        case 0x005B: return "Thumb button"
        case 0x00C3: return "Gesture button (thumb)"
        case 0x00C4: return "Button at the wheel"
        case 0x00D7: return "Virtual gesture button"
        default: return String(format: "Button 0x%04X", cid)
        }
    }

    private let device: HIDPPDevice

    public init(device: HIDPPDevice) {
        self.device = device
    }

    /// Function 0x00: GetCount
    public func count() throws -> Int {
        let response = try device.call(feature: SpecialButtonsFeature.featureID, function: 0x00)
        guard let c = response.params.first else { throw HIDPPError.malformedResponse }
        return Int(c)
    }

    /// Function 0x01: GetCidInfo(index) — returns the complete list of controls.
    public func listControls() throws -> [Control] {
        let n = try count()
        var controls: [Control] = []
        for index in 0..<n {
            let response = try device.call(feature: SpecialButtonsFeature.featureID, function: 0x01, params: [UInt8(index)])
            guard response.params.count >= 7 else { continue }
            let cid = (UInt16(response.params[0]) << 8) | UInt16(response.params[1])
            let tid = (UInt16(response.params[2]) << 8) | UInt16(response.params[3])
            let flags = response.params[4]
            let position = response.params[5]
            let group = response.params[6]
            let groupMask = response.params.count > 7 ? response.params[7] : 0
            controls.append(Control(controlID: cid, taskID: tid, flags: flags, position: position, group: group, groupMask: groupMask))
        }
        return controls
    }

    /// Current assignment of a button — unlike `Control`, which is static device info, this
    /// reflects the remap state actually in effect.
    public struct Reporting {
        public let controlID: UInt16
        public let flags: UInt8
        /// Currently assigned task ID (equals the native one as long as nothing is remapped).
        public let remappedTaskID: UInt16
    }

    /// Function 0x02: GetCidReporting — reads the current assignment of a button.
    public func reporting(controlID: UInt16) throws -> Reporting {
        let response = try device.call(
            feature: SpecialButtonsFeature.featureID,
            function: 0x02,
            params: [UInt8(controlID >> 8), UInt8(controlID & 0xFF)]
        )
        guard response.params.count >= 5 else { throw HIDPPError.malformedResponse }
        let cid = (UInt16(response.params[0]) << 8) | UInt16(response.params[1])
        let remapped = (UInt16(response.params[3]) << 8) | UInt16(response.params[4])
        return Reporting(controlID: cid, flags: response.params[2], remappedTaskID: remapped)
    }

    /// Flag bits in `SetCidReporting`/`GetCidReporting`. Every setting has a value bit and a
    /// matching "valid" bit; the device only applies the value if the latter is set.
    /// Confirmed empirically on the MX Master 3S.
    private enum Flag {
        static let divert: UInt8 = 0x01
        static let divertValid: UInt8 = 0x02
        static let persist: UInt8 = 0x04
        static let persistValid: UInt8 = 0x08
        static let rawXY: UInt8 = 0x10
        static let rawXYValid: UInt8 = 0x20
    }

    /// Function 0x03: SetCidReporting.
    ///
    /// Parameter layout (feature version 5): `cid(2), flags(1), reserved(1), remap(2)`. The
    /// reserved byte must be 0 — any other value is answered with INVALID_ARGUMENT.
    ///
    /// **No on-device remapping:** the MX Master 3S accepts the remap field but never applies
    /// it — `GetCidReporting` keeps returning 0x0000 afterwards. Every flag bit and both byte
    /// layouts were tested. Button remapping as in Logi Options+ therefore does not happen on
    /// the device but through `divert`: the button then reports its press as a HID++
    /// notification to the host, which carries out the wanted action itself. That requires a
    /// permanently running process.
    private func setReporting(controlID: UInt16, flags: UInt8) throws {
        try device.call(
            feature: SpecialButtonsFeature.featureID,
            function: 0x03,
            params: [UInt8(controlID >> 8), UInt8(controlID & 0xFF), flags, 0x00, 0x00, 0x00]
        )
    }

    /// Redirects a button's presses to the host as HID++ notifications instead of triggering
    /// the native action. Without a process handling those notifications the button is
    /// effectively dead.
    public func setDivert(controlID: UInt16, enabled: Bool) throws {
        try setReporting(controlID: controlID, flags: Flag.divertValid | (enabled ? Flag.divert : 0))
    }

    /// Resets all reporting flags of a button to their factory state.
    public func resetReporting(controlID: UInt16) throws {
        try setReporting(controlID: controlID, flags: Flag.divertValid | Flag.persistValid | Flag.rawXYValid)
    }
}
