import Foundation

/// Protocol core: feature discovery through the root feature (0x0000) plus a generic call
/// mechanism the concrete feature wrappers build on.
public final class HIDPPDevice {
    /// For directly connected devices (Bluetooth or USB, no receiver) 0xFF addresses the device itself.
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
    public func connect(preferredProductID: Int? = HIDPPTransport.productIDMXMaster3S) throws -> String {
        try transport.connect(preferredProductID: preferredProductID)
    }

    private func nextSoftwareID() -> UInt8 {
        swIDCounter = swIDCounter == 0x0F ? 1 : swIDCounter + 1
        return swIDCounter
    }

    /// Root feature 0x0000, function 0x00 (GetFeature): resolves a 16-bit feature ID into
    /// the device-side feature index that all further calls refer to.
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

    /// Generic feature call.
    @discardableResult
    public func call(featureIndex: UInt8, function: UInt8, params: [UInt8] = [], timeout: TimeInterval = 2.0) throws -> HIDPPResponse {
        try transport.request(
            deviceIndex: deviceIndex,
            featureIndex: featureIndex,
            function: function,
            swID: nextSoftwareID(),
            params: params,
            timeout: timeout
        )
    }

    /// Convenience: resolve the feature ID and call it in one step.
    @discardableResult
    public func call(feature featureID: UInt16, function: UInt8, params: [UInt8] = [], timeout: TimeInterval = 2.0) throws -> HIDPPResponse {
        let index = try featureIndex(for: featureID)
        return try call(featureIndex: index, function: function, params: params, timeout: timeout)
    }

    /// Listens for device notifications, for instance presses of diverted buttons.
    public func listen(duration: TimeInterval, shouldStop: () -> Bool = { false }, onNotification: ([UInt8]) -> Void) {
        transport.listen(duration: duration, shouldStop: shouldStop, onNotification: onNotification)
    }
}
