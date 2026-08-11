import Foundation

/// Feature 0x0003 (Device Information) — firmware version and serial number.
public struct DeviceInfoFeature {
    public static let featureID: UInt16 = 0x0003

    private let device: HIDPPDevice

    public init(device: HIDPPDevice) {
        self.device = device
    }

    /// Function 0x00: getDeviceInfo
    private func entityCountAndCapabilities() throws -> (count: Int, capabilities: UInt8) {
        let response = try device.call(feature: DeviceInfoFeature.featureID, function: 0x00)
        guard response.params.count >= 15 else { throw HIDPPError.malformedResponse }
        return (Int(response.params[0]), response.params[14])
    }

    /// Version of the application firmware, formatted as in the macOS system information
    /// (for example `RBM22.02_0009`).
    ///
    /// The device carries several entities (bootloader, application, hardware); the one with
    /// type 0 is the relevant one. Layout per entity: type(1), prefix(3 ASCII), number(1),
    /// revision(1), build(2) — number, revision and build are BCD encoded and therefore
    /// printed as hex to match the notation Logitech uses.
    public func firmwareVersion() throws -> String? {
        let (count, _) = try entityCountAndCapabilities()
        for entity in 0..<count {
            let response = try device.call(feature: DeviceInfoFeature.featureID, function: 0x01, params: [UInt8(entity)])
            let p = response.params
            guard p.count >= 8, p[0] == 0 else { continue }
            let prefix = String(bytes: p[1...3].filter { $0 >= 0x20 && $0 < 0x7F }, encoding: .ascii) ?? ""
            return String(format: "%@%02X.%02X_%02X%02X", prefix, p[4], p[5], p[6], p[7])
        }
        return nil
    }

    /// Function 0x02: getDeviceSerialNumber. Only available if bit 0 of the capabilities is
    /// set; otherwise the device answers with an error.
    public func serialNumber() throws -> String? {
        let (_, capabilities) = try entityCountAndCapabilities()
        guard capabilities & 0x01 != 0 else { return nil }
        let response = try device.call(feature: DeviceInfoFeature.featureID, function: 0x02)
        let chars = response.params.prefix(12).filter { $0 >= 0x20 && $0 < 0x7F }
        return chars.isEmpty ? nil : String(bytes: chars, encoding: .ascii)
    }
}

/// Feature 0x1814 (Change Host) — used read-only here, to show which channel the mouse is
/// currently on. Switching by software would immediately cut the connection to this computer
/// and is therefore not offered.
public struct HostChannelFeature {
    public static let featureID: UInt16 = 0x1814

    private let device: HIDPPDevice

    public init(device: HIDPPDevice) {
        self.device = device
    }

    /// Function 0x00: getHostInfo -> (number of channels, current channel)
    /// The device counts channels from 0; the labelling 1–3 is used towards the outside.
    public func current() throws -> (channel: Int, total: Int) {
        let response = try device.call(feature: HostChannelFeature.featureID, function: 0x00)
        guard response.params.count >= 2 else { throw HIDPPError.malformedResponse }
        return (Int(response.params[1]) + 1, Int(response.params[0]))
    }
}

/// Feature 0x0007 (Device Friendly Name) — a freely chosen device name.
public struct FriendlyNameFeature {
    public static let featureID: UInt16 = 0x0007

    private let device: HIDPPDevice

    public init(device: HIDPPDevice) {
        self.device = device
    }

    /// Function 0x00: getFriendlyNameLen -> (current, maximum, default)
    public func lengths() throws -> (current: Int, max: Int) {
        let response = try device.call(feature: FriendlyNameFeature.featureID, function: 0x00)
        guard response.params.count >= 2 else { throw HIDPPError.malformedResponse }
        return (Int(response.params[0]), Int(response.params[1]))
    }

    /// Function 0x01: getFriendlyName(byteIndex). The response starts with the byte index,
    /// followed by the characters; long names arrive in several chunks.
    public func name() throws -> String {
        let (length, _) = try lengths()
        var collected: [UInt8] = []
        var index = 0
        while collected.count < length, index < length {
            let response = try device.call(feature: FriendlyNameFeature.featureID, function: 0x01, params: [UInt8(index)])
            guard response.params.count > 1 else { break }
            let chunk = Array(response.params[1...])
            collected += chunk
            index += chunk.count
        }
        let printable = collected.prefix(length).filter { $0 >= 0x20 && $0 < 0x7F }
        return String(bytes: printable, encoding: .ascii) ?? ""
    }

    /// Function 0x03: setFriendlyName(byteIndex, characters). Fifteen characters fit behind
    /// the index in one report; longer names are written in chunks.
    ///
    /// Note the setter is function 3, not 2 — function 2 returns the *default* name and
    /// acknowledges a write attempt without complaint while changing nothing. The response
    /// states how many characters were accepted; counting continues from that rather than
    /// assuming the chunk length that was sent.
    public func setName(_ newName: String) throws {
        let (_, maxLength) = try lengths()
        let bytes = Array(newName.unicodeScalars
            .filter { $0.isASCII && $0.value >= 0x20 && $0.value < 0x7F }
            .map { UInt8($0.value) }
            .prefix(maxLength))
        guard !bytes.isEmpty else { throw HIDPPError.malformedResponse }

        var index = 0
        while index < bytes.count {
            let chunk = Array(bytes[index..<min(index + 15, bytes.count)])
            let response = try device.call(feature: FriendlyNameFeature.featureID, function: 0x03, params: [UInt8(index)] + chunk)
            guard let written = response.params.first, written > UInt8(index) else {
                throw HIDPPError.malformedResponse
            }
            index = Int(written)
        }
    }

    /// Function 0x04: resetFriendlyName — restores the factory-assigned name.
    public func resetName() throws {
        try device.call(feature: FriendlyNameFeature.featureID, function: 0x04)
    }
}
