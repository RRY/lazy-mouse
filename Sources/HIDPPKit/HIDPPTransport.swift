import Foundation
import IOKit
import IOKit.hid

/// Low-level transport: findet die HID++ Vendor-Collection der Maus über IOHIDManager
/// und tauscht rohe HID++ 2.0 Reports (kurz = 0x10/7 Byte, lang = 0x11/20 Byte) aus.
///
/// Läuft bewusst single-threaded/blocking: für ein CLI-Tool ist ein Request/Response-Zyklus,
/// der den aktuellen RunLoop kurz anpumpt, einfacher als ein voller async Callback-Graph.
public final class HIDPPTransport {

    public static let reportIDShort: UInt8 = 0x10
    public static let reportIDLong: UInt8 = 0x11
    static let shortBodyLength = 6   // ohne Report-ID: deviceIndex, featureIndex, funcSw, p0..p2
    static let longBodyLength = 19   // ohne Report-ID: deviceIndex, featureIndex, funcSw, p0..p15

    public static let vendorIDLogitech = 0x046D
    /// Logitechs HID++ Vendor-Defined Top-Level-Collection liegt durchgängig auf dieser Usage Page.
    static let hidppUsagePage = 0xFF00

    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private let inputBufferSize = 32
    private let inputBuffer: UnsafeMutablePointer<UInt8>

    /// Empfangene, noch nicht abgeholte Antworten, geschlüsselt nach Software-ID (unteres Nibble von funcSw).
    private var pendingResponses: [UInt8: [UInt8]] = [:]

    public private(set) var productName: String = "unbekannt"

    public init() {
        inputBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: inputBufferSize)
    }

    deinit {
        if let device = device {
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        inputBuffer.deallocate()
    }

    /// Sucht ein an die Maus gekoppeltes Logitech-HID++-Interface und öffnet es.
    /// - Parameter nameHint: bevorzugt ein Gerät, dessen Produktname diesen Teilstring enthält,
    ///   falls mehrere Logitech-HID++-Geräte gleichzeitig verbunden sind.
    @discardableResult
    public func connect(nameHint: String? = "MX Master 3S") throws -> String {
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matchDict: [String: Any] = [
            kIOHIDVendorIDKey as String: HIDPPTransport.vendorIDLogitech,
            kIOHIDPrimaryUsagePageKey as String: HIDPPTransport.hidppUsagePage
        ]
        IOHIDManagerSetDeviceMatching(mgr, matchDict as CFDictionary)

        let openResult = IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openResult == kIOReturnSuccess else {
            throw HIDPPError.managerOpenFailed(openResult)
        }

        guard let deviceSet = IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice>, !deviceSet.isEmpty else {
            throw HIDPPError.deviceNotFound
        }

        func name(of d: IOHIDDevice) -> String {
            (IOHIDDeviceGetProperty(d, kIOHIDProductKey as CFString) as? String) ?? "Logitech HID++ Gerät"
        }

        let chosen: IOHIDDevice
        if let hint = nameHint, let match = deviceSet.first(where: { name(of: $0).localizedCaseInsensitiveContains(hint) }) {
            chosen = match
        } else {
            chosen = deviceSet.first!
        }

        IOHIDDeviceScheduleWithRunLoop(chosen, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        let openDeviceResult = IOHIDDeviceOpen(chosen, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openDeviceResult == kIOReturnSuccess else {
            throw HIDPPError.deviceOpenFailed(openDeviceResult)
        }

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(
            chosen,
            inputBuffer,
            inputBufferSize,
            { context, _, _, _, reportID, report, reportLength in
                guard let context = context else { return }
                let transport = Unmanaged<HIDPPTransport>.fromOpaque(context).takeUnretainedValue()
                let bytes = Array(UnsafeBufferPointer(start: report, count: reportLength))
                transport.handleInputReport(reportID: UInt8(truncatingIfNeeded: reportID), body: bytes)
            },
            context
        )

        self.manager = mgr
        self.device = chosen
        self.productName = name(of: chosen)
        return productName
    }

    private func handleInputReport(reportID: UInt8, body: [UInt8]) {
        // body-Layout (ohne Report-ID): [deviceIndex, featureIndex, funcSw, params...]
        guard body.count >= 3 else { return }
        let swID = body[2] & 0x0F
        pendingResponses[swID] = body
    }

    /// Sendet ein HID++ Request und blockiert (mit Timeout), bis eine passende Antwort eintrifft.
    public func request(
        deviceIndex: UInt8,
        featureIndex: UInt8,
        function: UInt8,
        swID: UInt8,
        params: [UInt8] = [],
        long: Bool = false,
        timeout: TimeInterval = 2.0
    ) throws -> HIDPPResponse {
        guard let device = device else { throw HIDPPError.notConnected }

        let funcSw = (function << 4) | (swID & 0x0F)
        let bodyLength = long ? HIDPPTransport.longBodyLength : HIDPPTransport.shortBodyLength
        var body = [UInt8](repeating: 0, count: bodyLength)
        body[0] = deviceIndex
        body[1] = featureIndex
        body[2] = funcSw
        for (i, p) in params.prefix(bodyLength - 3).enumerated() {
            body[3 + i] = p
        }

        let reportID = long ? HIDPPTransport.reportIDLong : HIDPPTransport.reportIDShort
        pendingResponses.removeValue(forKey: swID)

        let sendResult = body.withUnsafeMutableBufferPointer { buf -> IOReturn in
            IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(reportID), buf.baseAddress!, buf.count)
        }
        guard sendResult == kIOReturnSuccess else {
            throw HIDPPError.sendFailed(sendResult)
        }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let responseBody = pendingResponses.removeValue(forKey: swID) {
                return try HIDPPResponse(body: responseBody, requestFeatureIndex: featureIndex, requestFunction: function)
            }
            CFRunLoopRunInMode(.defaultMode, 0.02, true)
        }
        throw HIDPPError.timeout
    }
}

/// Geparste Antwort auf einen HID++-Request.
public struct HIDPPResponse {
    public let featureIndex: UInt8
    public let function: UInt8
    public let params: [UInt8]

    /// HID++ 2.0 Fehlerantwort: [deviceIndex, 0xFF, originalFeatureIndex, originalFuncSw, errorCode, ...]
    init(body: [UInt8], requestFeatureIndex: UInt8, requestFunction: UInt8) throws {
        guard body.count >= 3 else { throw HIDPPError.malformedResponse }
        if body[1] == 0xFF {
            guard body.count >= 5 else { throw HIDPPError.malformedResponse }
            let erroredFunction = body[3] >> 4
            let errorCode = body[4]
            throw HIDPPError.protocolError(featureIndex: body[2], function: erroredFunction, errorCode: errorCode)
        }
        self.featureIndex = body[1]
        self.function = body[2] >> 4
        self.params = Array(body[3...])
    }
}
