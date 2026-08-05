import Foundation

/// Feature 0x1B04 (Special Keys / Mouse Buttons) — enumeriert die programmierbaren Tasten
/// (Vor/Zurück, Gesten-Taste, Rad-Kippfunktion etc.) und erlaubt On-Device-Remapping auf
/// eine andere Task-ID. Rohe Control-/Task-IDs statt symbolischer Namen: die exakte
/// Bit-Semantik der Capability-/Report-Flags ist geräteabhängig und sollte vor einem
/// "diverted"/Software-Remap gegen die reale MX Master 3S verifiziert werden.
public struct SpecialButtonsFeature {
    public static let featureID: UInt16 = 0x1B04

    public struct Control {
        public let controlID: UInt16
        public let taskID: UInt16
        public let flags: UInt8
        public let position: UInt8
        public let group: UInt8
        public let groupMask: UInt8
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

    /// Function 0x01: GetCidInfo(index) — liefert die vollständige Liste der Controls.
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

    /// Function 0x03: SetCidReporting — remapped eine Control-ID auf eine andere Task-ID,
    /// rein on-device (kein Divert-Flag gesetzt, daher ohne laufenden Host-Prozess wirksam).
    public func remap(controlID: UInt16, toTaskID taskID: UInt16) throws {
        let cidHi = UInt8(controlID >> 8)
        let cidLo = UInt8(controlID & 0xFF)
        let flags: UInt8 = 0x00
        let tidHi = UInt8(taskID >> 8)
        let tidLo = UInt8(taskID & 0xFF)
        try device.call(feature: SpecialButtonsFeature.featureID, function: 0x03, params: [cidHi, cidLo, flags, tidHi, tidLo])
    }
}
