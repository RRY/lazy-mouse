import Foundation
import IOKit
import IOKit.hid

/// Low-level transport for HID++ 2.0 over IOKit.
///
/// What matters for Bluetooth LE on macOS, established empirically on an MX Master 3S:
///
/// * The HID++ vendor collection does NOT appear as its own IOHIDDevice but as an additional
///   usage pair on the same device as the standard mouse collection (usage page 0xFF43 on the
///   MX Master 3S). A matching dictionary filtering on the usage page therefore does not find
///   the device — it has to be matched by vendor ID and the collection identified afterwards
///   through its elements.
///
/// * Only report ID 0x11 exists (long, 19-byte body); there is no classic 0x10 (short).
///
/// * `IOHIDDeviceSetReport` returns kIOReturnSuccess but sends nothing at all. Sending only
///   works through `IOHIDDeviceSetValue` on the 19-byte output array element of the vendor
///   collection.
///
/// * Receiving goes through `IOHIDDeviceRegisterInputReportCallback`. The callback delivers
///   the report including the leading report ID, so the HID++ body starts at index 1. The
///   input *element* is not usable as a source: it only caches the most recently received
///   report, and many SET calls trigger a notification right after their answer that
///   overwrites the cache within milliseconds — the answer would be lost.
///
/// Because the matching uses the vendor ID without restricting the usage page, macOS requires
/// the "Input Monitoring" permission for the calling application.
public final class HIDPPTransport {

    public static let vendorIDLogitech = 0x046D
    /// Report ID of every HID++ message on this transport.
    static let reportID: UInt8 = 0x11
    /// Body length of a HID++ long report, excluding the report ID.
    static let reportBodyLength = 19

    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private var outputElement: IOHIDElement?

    private let inputBufferSize = 64
    private let inputBuffer: UnsafeMutablePointer<UInt8>
    /// HID++ bodies received since the last request, without the report ID.
    private var receivedBodies: [[UInt8]] = []

    public private(set) var productName: String = "unknown"
    /// Usage page of the HID++ vendor collection that was found (0xFF43 over BLE).
    public private(set) var vendorUsagePage: UInt32 = 0

    /// Called for every device notification (software ID 0) as it arrives — unlike
    /// `listen(...)` without blocking. Runs on the thread whose run loop serves the device.
    public var onNotification: (([UInt8]) -> Void)?

    public init() {
        inputBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: inputBufferSize)
    }

    deinit {
        if let device = device {
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        inputBuffer.deallocate()
    }

    /// Product ID of the MX Master 3S. Preferred when several Logitech devices are attached;
    /// if it is not among them, any device carrying a HID++ collection qualifies. Deliberately
    /// the product ID rather than the product name: the name is writable through
    /// `FriendlyNameFeature`, so a name filter would stop matching after a rename — the
    /// product ID stays.
    public static let productIDMXMaster3S = 0xB034

    /// Reports the device disappearing or coming back — around system sleep, for instance.
    /// Runs on the thread whose run loop serves the manager.
    public var onConnectionChange: ((Bool) -> Void)?

    private var preferredProductID: Int?

    /// Registers the manager for arrivals and removals. Without this the transport would keep
    /// its reference to the old, long-removed device after sleep: macOS creates a new
    /// `IOHIDDevice` on reconnection, and every access would silently go nowhere until the
    /// application restarts.
    private func registerDeviceCallbacks(_ mgr: IOHIDManager) {
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(mgr, { context, _, _, device in
            guard let context = context else { return }
            let transport = Unmanaged<HIDPPTransport>.fromOpaque(context).takeUnretainedValue()
            // Only step in when no device is currently being served.
            guard transport.device == nil else { return }
            // After a reconnection pick the same model as before; otherwise the wrong one
            // could be adopted when several Logitech devices are present.
            if let wanted = transport.preferredProductID,
               (IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int) != wanted {
                return
            }
            if transport.adopt(device) {
                transport.onConnectionChange?(true)
            }
        }, context)

        IOHIDManagerRegisterDeviceRemovalCallback(mgr, { context, _, _, device in
            guard let context = context else { return }
            let transport = Unmanaged<HIDPPTransport>.fromOpaque(context).takeUnretainedValue()
            guard transport.device == device else { return }
            transport.device = nil
            transport.outputElement = nil
            transport.receivedBodies.removeAll()
            transport.onConnectionChange?(false)
        }, context)
    }

    /// Adopts a device, provided it carries the HID++ collection.
    @discardableResult
    private func adopt(_ candidate: IOHIDDevice) -> Bool {
        guard let elements = IOHIDDeviceCopyMatchingElements(candidate, nil, IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement] else {
            return false
        }
        // The HID++ output array element: vendor usage page, 19 bytes of 8 bits each.
        let out = elements.first { el in
            IOHIDElementGetUsagePage(el) >= 0xFF00
                && IOHIDElementGetType(el) == kIOHIDElementTypeOutput
                && IOHIDElementGetReportCount(el) == UInt32(HIDPPTransport.reportBodyLength)
                && IOHIDElementGetReportSize(el) == 8
        }
        guard let outputElement = out else { return false }

        IOHIDDeviceScheduleWithRunLoop(candidate, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        guard IOHIDDeviceOpen(candidate, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            return false
        }

        IOHIDDeviceRegisterInputReportCallback(
            candidate,
            inputBuffer,
            inputBufferSize,
            { context, _, _, _, reportID, report, reportLength in
                guard let context = context, UInt8(truncatingIfNeeded: reportID) == HIDPPTransport.reportID else { return }
                let transport = Unmanaged<HIDPPTransport>.fromOpaque(context).takeUnretainedValue()
                // The callback includes the report ID as the first byte.
                let raw = Array(UnsafeBufferPointer(start: report, count: reportLength))
                guard raw.count > 1 else { return }
                let body = Array(raw.dropFirst())
                transport.receivedBodies.append(body)
                if body.count >= 3, (body[2] & 0x0F) == 0 {
                    transport.onNotification?(body)
                }
            },
            Unmanaged.passUnretained(self).toOpaque()
        )

        device = candidate
        // The product ID actually adopted becomes the preference for later arrivals — even
        // when the first connection fell back to a different model.
        preferredProductID = IOHIDDeviceGetProperty(candidate, kIOHIDProductIDKey as CFString) as? Int
        self.outputElement = outputElement
        productName = (IOHIDDeviceGetProperty(candidate, kIOHIDProductKey as CFString) as? String) ?? "Logitech device"
        vendorUsagePage = IOHIDElementGetUsagePage(outputElement)
        return true
    }

    @discardableResult
    public func connect(preferredProductID: Int? = HIDPPTransport.productIDMXMaster3S) throws -> String {
        self.preferredProductID = preferredProductID
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(mgr, [kIOHIDVendorIDKey as String: HIDPPTransport.vendorIDLogitech] as CFDictionary)

        let openResult = IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openResult == kIOReturnSuccess else {
            throw HIDPPError.managerOpenFailed(openResult)
        }
        self.manager = mgr
        registerDeviceCallbacks(mgr)
        // The manager has to sit on the run loop, or arrival and removal never arrive.
        IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)

        guard let deviceSet = IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice>, !deviceSet.isEmpty else {
            throw HIDPPError.deviceNotFound
        }

        let candidates: [IOHIDDevice]
        if let preferred = preferredProductID {
            let matching = deviceSet.filter {
                (IOHIDDeviceGetProperty($0, kIOHIDProductIDKey as CFString) as? Int) == preferred
            }
            candidates = matching.isEmpty ? Array(deviceSet) : Array(matching)
        } else {
            candidates = Array(deviceSet)
        }

        for candidate in candidates where adopt(candidate) {
            return productName
        }

        throw HIDPPError.deviceNotFound
    }

    /// Whether a device is currently being served.
    public var isConnected: Bool { device != nil }

    /// Checks whether a received body is the answer to a request with this software ID.
    ///
    /// In error responses (`body[1] == 0xFF`) the function/swID byte sits at position 3
    /// instead of 2, because the original feature address is inserted in between.
    private static func matches(body: [UInt8], swID: UInt8) -> Bool {
        guard body.count >= 4 else { return false }
        let funcSw = body[1] == 0xFF ? body[3] : body[2]
        return (funcSw & 0x0F) == swID
    }

    /// Sends a HID++ request and waits for the matching answer.
    ///
    /// Device notifications (software ID 0) are skipped; on SET calls they regularly arrive
    /// shortly after the answer itself.
    public func request(
        deviceIndex: UInt8,
        featureIndex: UInt8,
        function: UInt8,
        swID: UInt8,
        params: [UInt8] = [],
        timeout: TimeInterval = 2.0
    ) throws -> HIDPPResponse {
        guard let device = device, let outputElement = outputElement else {
            throw HIDPPError.notConnected
        }

        let effectiveSwID = (swID & 0x0F) == 0 ? 1 : (swID & 0x0F)
        receivedBodies.removeAll()

        var body = [UInt8](repeating: 0, count: HIDPPTransport.reportBodyLength)
        body[0] = deviceIndex
        body[1] = featureIndex
        body[2] = (function << 4) | effectiveSwID
        for (i, p) in params.prefix(HIDPPTransport.reportBodyLength - 3).enumerated() {
            body[3 + i] = p
        }

        let sendResult = body.withUnsafeMutableBufferPointer { buf -> IOReturn in
            guard let value = IOHIDValueCreateWithBytes(kCFAllocatorDefault, outputElement, 0, buf.baseAddress!, buf.count) else {
                return kIOReturnError
            }
            return IOHIDDeviceSetValue(device, outputElement, value)
        }
        guard sendResult == kIOReturnSuccess else {
            throw HIDPPError.sendFailed(sendResult)
        }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            CFRunLoopRunInMode(.defaultMode, 0.01, true)
            if let match = receivedBodies.first(where: { HIDPPTransport.matches(body: $0, swID: effectiveSwID) }) {
                return try HIDPPResponse(body: match)
            }
        }
        throw HIDPPError.timeout
    }

    /// Listens for device notifications (software ID 0) — presses of a button redirected via
    /// `divert`, for instance. Blocks until `duration` has elapsed or `shouldStop` returns
    /// true.
    public func listen(duration: TimeInterval, shouldStop: () -> Bool = { false }, onNotification: ([UInt8]) -> Void) {
        receivedBodies.removeAll()
        var delivered = 0
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline, !shouldStop() {
            CFRunLoopRunInMode(.defaultMode, 0.05, true)
            while delivered < receivedBodies.count {
                let body = receivedBodies[delivered]
                delivered += 1
                if body.count >= 3, (body[2] & 0x0F) == 0 {
                    onNotification(body)
                }
            }
        }
    }
}

/// Parsed answer to a HID++ request.
public struct HIDPPResponse {
    public let featureIndex: UInt8
    public let function: UInt8
    public let params: [UInt8]

    /// HID++ 2.0 error response: [deviceIndex, 0xFF, originalFeatureIndex, originalFuncSw, errorCode, ...]
    init(body: [UInt8]) throws {
        guard body.count >= 3 else { throw HIDPPError.malformedResponse }
        if body[1] == 0xFF {
            guard body.count >= 5 else { throw HIDPPError.malformedResponse }
            throw HIDPPError.protocolError(featureIndex: body[2], function: body[3] >> 4, errorCode: body[4])
        }
        self.featureIndex = body[1]
        self.function = body[2] >> 4
        self.params = Array(body[3...])
    }
}
