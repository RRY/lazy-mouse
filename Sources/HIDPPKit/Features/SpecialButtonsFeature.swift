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

        /// Nur umleitbare Tasten lassen sich für eigene Aktionen verwenden. Das Bit schützt
        /// zugleich vor Unfug: Links- und Rechtsklick sind nicht umleitbar und tauchen
        /// deshalb in einer danach gefilterten Auswahl gar nicht erst auf.
        public var isDivertable: Bool { flags & 0x20 != 0 }

        /// Sprechender Name, soweit die Control-ID bekannt ist.
        public var name: String { SpecialButtonsFeature.name(forControlID: controlID) }
    }

    /// Namen der geläufigen Control-IDs. Unbekannte werden hexadezimal ausgewiesen, damit
    /// die Auswahl auch bei fremden Modellen brauchbar bleibt.
    public static func name(forControlID cid: UInt16) -> String {
        switch cid {
        case 0x0050: return "Linksklick"
        case 0x0051: return "Rechtsklick"
        case 0x0052: return "Mittlere Taste"
        case 0x0053: return "Zurück"
        case 0x0056: return "Vorwärts"
        case 0x005B: return "Daumentaste"
        case 0x00C3: return "Gestentaste (Daumen)"
        case 0x00C4: return "Taste am Scrollrad"
        case 0x00D7: return "Virtuelle Gestentaste"
        default: return String(format: "Taste 0x%04X", cid)
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

    /// Aktuelle Zuordnung einer Taste — im Gegensatz zu `Control` (statische Geräteinfo)
    /// spiegelt das den tatsächlich gesetzten Remap-Zustand wider.
    public struct Reporting {
        public let controlID: UInt16
        public let flags: UInt8
        /// Aktuell zugeordnete Task-ID (entspricht der nativen, solange nichts umgemappt ist).
        public let remappedTaskID: UInt16
    }

    /// Function 0x02: GetCidReporting — liest die aktuelle Zuordnung einer Taste.
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

    /// Flag-Bits in `SetCidReporting`/`GetCidReporting`. Jede Einstellung hat ein Wert-Bit
    /// und ein zugehöriges "valid"-Bit; nur wenn letzteres gesetzt ist, übernimmt das Gerät
    /// den Wert. Empirisch an der MX Master 3S bestätigt.
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
    /// Parameter-Layout (Feature-Version 5): `cid(2), flags(1), reserved(1), remap(2)`.
    /// Das reservierte Byte muss 0 sein — jeder andere Wert quittiert das Gerät mit
    /// INVALID_ARGUMENT.
    ///
    /// **Kein On-Device-Remapping:** Das Remap-Feld wird von der MX Master 3S zwar
    /// entgegengenommen, aber nie übernommen — `GetCidReporting` liefert danach unverändert
    /// 0x0000. Getestet wurden alle Flag-Bits sowie beide Byte-Layouts. Tastenbelegung wie
    /// in Logi Options+ läuft deshalb nicht auf dem Gerät, sondern über `divert`: die Taste
    /// meldet ihren Druck dann als HID++-Notification an den Host, der die gewünschte Aktion
    /// selbst ausführt (setzt einen dauerhaft laufenden Prozess voraus).
    private func setReporting(controlID: UInt16, flags: UInt8) throws {
        try device.call(
            feature: SpecialButtonsFeature.featureID,
            function: 0x03,
            params: [UInt8(controlID >> 8), UInt8(controlID & 0xFF), flags, 0x00, 0x00, 0x00]
        )
    }

    /// Leitet die Tastendrücke einer Taste als HID++-Notification an den Host um, statt die
    /// native Aktion auszulösen. Ohne einen Prozess, der diese Notifications verarbeitet,
    /// ist die Taste damit faktisch wirkungslos.
    public func setDivert(controlID: UInt16, enabled: Bool) throws {
        try setReporting(controlID: controlID, flags: Flag.divertValid | (enabled ? Flag.divert : 0))
    }

    /// Setzt alle Reporting-Flags einer Taste auf den Auslieferungszustand zurück.
    public func resetReporting(controlID: UInt16) throws {
        try setReporting(controlID: controlID, flags: Flag.divertValid | Flag.persistValid | Flag.rawXYValid)
    }
}
