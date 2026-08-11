import Foundation

/// Feature 0x2201 (Adjustable DPI). Addresses sensor index 0 (the MX Master 3S has one sensor).
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
    /// The response starts with the sensor index; only then do 16-bit values follow. A value
    /// with bits `0xE000` set is not a DPI step but a range marker: the *preceding* value is
    /// the minimum, the lower 13 bits are the step size, and the *following* value is the
    /// maximum. A zero ends the list.
    ///
    /// On the MX Master 3S the response reads `00 | 00C8 | E032 | 1F40`, i.e. 200 to 8000 in
    /// steps of 50.
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
                // The minimum is already in the list and belongs to the range, not to the
                // individual steps.
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

    /// Function 0x02: GetSensorDpi -> (current DPI, default DPI)
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
