import Foundation

/// Feature 0x2121 (HiRes Wheel) — vertikales Scrollrad.
///
/// Der Modus steckt in einem Flag-Byte. Belegung laut Protokolldokumentation; empirisch
/// bestätigt ist nur, dass alle Bits gesetzt und zurückgelesen werden können. Beim Ändern
/// werden die übrigen Bits erhalten — insbesondere `target` darf nicht versehentlich
/// gesetzt werden, weil das Rad seine Bewegung dann an HID++ meldet statt als normales
/// Scrollen, also faktisch aufhört zu funktionieren.
public struct HiResWheelFeature {
    public static let featureID: UInt16 = 0x2121

    private enum Flag {
        /// Rad meldet an HID++ statt an HID — Scrollen fällt damit aus.
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

    /// Function 0x02: SetWheelMode
    public func setInverted(_ inverted: Bool) throws {
        var flags = try modeFlags()
        flags = inverted ? (flags | Flag.invert) : (flags & ~Flag.invert)
        // Sicherheitsnetz: dieses Bit würde das Rad stumm schalten und gehört nie gesetzt.
        flags &= ~Flag.target
        try device.call(feature: HiResWheelFeature.featureID, function: 0x02, params: [flags])
    }
}

/// Feature 0x2150 (Thumbwheel) — horizontales Daumenrad.
///
/// `SetThumbwheelReporting` nimmt zwei Bytes: Meldemodus und Invertierung, jeweils 0 oder 1.
/// Andere Werte lehnt das Gerät ab (0x02 im ersten Byte quittiert es mit INVALID_ARGUMENT,
/// im zweiten verwirft es sie stillschweigend). `GetThumbwheelStatus` gibt beide zurück.
public struct ThumbwheelFeature {
    public static let featureID: UInt16 = 0x2150

    private let device: HIDPPDevice

    public init(device: HIDPPDevice) {
        self.device = device
    }

    /// Function 0x01: GetThumbwheelStatus -> (Meldemodus, Invertierung)
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
        // Meldemodus unverändert lassen: umgeleitet meldet das Rad an HID++ statt zu scrollen.
        let current = try status()
        try device.call(
            feature: ThumbwheelFeature.featureID,
            function: 0x02,
            params: [current.reportingDiverted ? 1 : 0, inverted ? 1 : 0]
        )
    }
}
