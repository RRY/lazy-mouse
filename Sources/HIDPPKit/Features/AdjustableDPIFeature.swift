import Foundation

/// Feature 0x2201 (Adjustable DPI). Adressiert Sensor-Index 0 (die MX Master 3S hat einen Sensor).
public struct AdjustableDPIFeature {
    public static let featureID: UInt16 = 0x2201

    public struct SensorRange {
        public let min: Int
        public let max: Int
        public let step: Int
    }

    private let device: HIDPPDevice
    private let sensorIndex: UInt8

    public init(device: HIDPPDevice, sensorIndex: UInt8 = 0) {
        self.device = device
        self.sensorIndex = sensorIndex
    }

    /// Function 0x00: GetSensorCount
    public func sensorCount() throws -> Int {
        let response = try device.call(feature: AdjustableDPIFeature.featureID, function: 0x00)
        guard let count = response.params.first else { throw HIDPPError.malformedResponse }
        return Int(count)
    }

    /// Function 0x01: GetSensorDpiList.
    ///
    /// Die Antwort beginnt mit dem Sensor-Index, erst danach folgen 16-Bit-Werte. Ein Wert
    /// mit gesetzten Bits `0xE000` ist keine DPI-Stufe, sondern eine Bereichsmarke: der
    /// *vorhergehende* Wert ist das Minimum, die unteren 13 Bit sind die Schrittweite, der
    /// *folgende* Wert das Maximum. Eine Null beendet die Liste.
    ///
    /// Bei der MX Master 3S lautet die Antwort `00 | 00C8 | E032 | 1F40`, also 200 bis 8000
    /// in Schritten von 50.
    public func dpiList() throws -> (fixedValues: [Int], range: SensorRange?) {
        let response = try device.call(feature: AdjustableDPIFeature.featureID, function: 0x01, params: [sensorIndex])
        guard response.params.count > 2 else { throw HIDPPError.malformedResponse }
        let data = Array(response.params.dropFirst())
        let words = stride(from: 0, to: data.count - 1, by: 2).map { idx -> Int in
            (Int(data[idx]) << 8) | Int(data[idx + 1])
        }

        var fixed: [Int] = []
        var range: SensorRange?
        var i = 0
        while i < words.count, words[i] != 0 {
            if words[i] & 0xE000 == 0xE000 {
                let step = words[i] & 0x1FFF
                // Das Minimum steht bereits in der Liste und gehört zum Bereich, nicht zu
                // den Einzelstufen.
                let minimum = fixed.popLast() ?? 0
                let maximum = i + 1 < words.count ? words[i + 1] : minimum
                range = SensorRange(min: minimum, max: maximum, step: step)
                i += 2
            } else {
                fixed.append(words[i])
                i += 1
            }
        }
        return (fixed, range)
    }

    /// Function 0x02: GetSensorDpi -> (aktuelle DPI, Standard-DPI)
    public func currentDPI() throws -> (current: Int, `default`: Int) {
        let response = try device.call(feature: AdjustableDPIFeature.featureID, function: 0x02, params: [sensorIndex])
        guard response.params.count >= 5 else { throw HIDPPError.malformedResponse }
        let current = (Int(response.params[1]) << 8) | Int(response.params[2])
        let def = (Int(response.params[3]) << 8) | Int(response.params[4])
        return (current, def)
    }

    /// Function 0x03: SetSensorDpi
    public func setDPI(_ dpi: Int) throws {
        let hi = UInt8((dpi >> 8) & 0xFF)
        let lo = UInt8(dpi & 0xFF)
        try device.call(feature: AdjustableDPIFeature.featureID, function: 0x03, params: [sensorIndex, hi, lo])
    }
}
