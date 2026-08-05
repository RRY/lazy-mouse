import Foundation

/// Protokoll-Kern: Feature-Discovery über die Root-Feature (0x0000) und ein generischer
/// Aufrufmechanismus, auf dem die konkreten Feature-Wrapper aufsetzen.
public final class HIDPPDevice {
    /// 0xFF adressiert bei direkt verbundenen Geräten (Bluetooth/USB-Direct, kein Empfänger) das Gerät selbst.
    public static let directDeviceIndex: UInt8 = 0xFF

    private let transport: HIDPPTransport
    private let deviceIndex: UInt8
    private var swIDCounter: UInt8 = 1
    private var featureIndexCache: [UInt16: UInt8] = [:]

    public var productName: String { transport.productName }

    public init(transport: HIDPPTransport, deviceIndex: UInt8 = HIDPPDevice.directDeviceIndex) {
        self.transport = transport
        self.deviceIndex = deviceIndex
    }

    @discardableResult
    public func connect(nameHint: String? = "MX Master 3S") throws -> String {
        try transport.connect(nameHint: nameHint)
    }

    private func nextSoftwareID() -> UInt8 {
        swIDCounter = swIDCounter == 0x0F ? 1 : swIDCounter + 1
        return swIDCounter
    }

    /// Root-Feature 0x0000, Function 0x00 (GetFeature): löst eine 16-Bit Feature-ID
    /// in den geräteseitigen Feature-Index auf, den alle weiteren Aufrufe referenzieren.
    public func featureIndex(for featureID: UInt16) throws -> UInt8 {
        if let cached = featureIndexCache[featureID] {
            return cached
        }
        let params: [UInt8] = [UInt8(featureID >> 8), UInt8(featureID & 0xFF)]
        let response = try call(featureIndex: 0x00, function: 0x00, params: params)
        let index = response.params[0]
        guard index != 0 else {
            throw HIDPPError.protocolError(featureIndex: 0x00, function: 0x00, errorCode: 0)
        }
        featureIndexCache[featureID] = index
        return index
    }

    /// Generischer Feature-Aufruf. `long: true` erzwingt einen 20-Byte-Report für Antworten
    /// mit mehr als 3 Nutzbytes.
    @discardableResult
    public func call(featureIndex: UInt8, function: UInt8, params: [UInt8] = [], long: Bool = false, timeout: TimeInterval = 2.0) throws -> HIDPPResponse {
        let swID = nextSoftwareID()
        return try transport.request(
            deviceIndex: deviceIndex,
            featureIndex: featureIndex,
            function: function,
            swID: swID,
            params: params,
            long: long || params.count > 3,
            timeout: timeout
        )
    }

    /// Bequemlichkeitsmethode: Feature-ID auflösen und direkt aufrufen.
    @discardableResult
    public func call(feature featureID: UInt16, function: UInt8, params: [UInt8] = [], long: Bool = false, timeout: TimeInterval = 2.0) throws -> HIDPPResponse {
        let index = try featureIndex(for: featureID)
        return try call(featureIndex: index, function: function, params: params, long: long, timeout: timeout)
    }
}
