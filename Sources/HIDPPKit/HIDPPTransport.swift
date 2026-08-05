import Foundation
import IOKit
import IOKit.hid

/// Low-level transport für HID++ 2.0 über IOKit.
///
/// Wichtig für Bluetooth LE auf macOS (empirisch an einer MX Master 3S ermittelt):
///
/// * Die HID++ Vendor-Collection erscheint NICHT als eigenes IOHIDDevice, sondern als
///   zusätzliches Usage-Pair auf demselben Gerät wie die Standard-Maus-Collection
///   (bei der MX Master 3S: Usage Page 0xFF43). Ein Matching-Dictionary, das auf die
///   Usage Page filtert, findet das Gerät deshalb nicht — es muss über die Vendor-ID
///   gematcht und die Collection danach über die Elemente gefunden werden.
///
/// * Es existiert nur Report-ID 0x11 (Long, 19 Byte Body), kein klassisches 0x10 (Short).
///
/// * `IOHIDDeviceSetReport` liefert zwar kIOReturnSuccess, sendet aber faktisch nichts.
///   Nur `IOHIDDeviceSetValue` auf dem 19-Byte-Output-Array-Element kommt beim Gerät an.
///
/// * Antworten werden nicht über Input-Callbacks zugestellt; sie müssen per
///   `IOHIDDeviceGetValue` vom Input-Array-Element gepollt werden. Dieses Element ist ein
///   Cache des zuletzt empfangenen Reports, kein Stream — siehe `request(...)`.
///
/// Da das Matching die Vendor-ID ohne Usage-Page-Einschränkung verwendet, verlangt macOS
/// die Berechtigung "Eingabeüberwachung" (Input Monitoring) für die aufrufende Anwendung.
public final class HIDPPTransport {

    public static let vendorIDLogitech = 0x046D
    /// Body-Länge eines HID++ Long-Reports ohne Report-ID.
    static let reportBodyLength = 19

    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private var outputElement: IOHIDElement?
    private var inputElement: IOHIDElement?

    public private(set) var productName: String = "unbekannt"
    /// Usage Page der gefundenen HID++ Vendor-Collection (z. B. 0xFF43 bei BLE).
    public private(set) var vendorUsagePage: UInt32 = 0

    public init() {}

    deinit {
        if let device = device {
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        }
    }

    @discardableResult
    public func connect(nameHint: String? = "MX Master") throws -> String {
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(mgr, [kIOHIDVendorIDKey as String: HIDPPTransport.vendorIDLogitech] as CFDictionary)

        let openResult = IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openResult == kIOReturnSuccess else {
            throw HIDPPError.managerOpenFailed(openResult)
        }
        guard let deviceSet = IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice>, !deviceSet.isEmpty else {
            throw HIDPPError.deviceNotFound
        }

        func name(of d: IOHIDDevice) -> String {
            (IOHIDDeviceGetProperty(d, kIOHIDProductKey as CFString) as? String) ?? "Logitech-Gerät"
        }

        let candidates: [IOHIDDevice]
        if let hint = nameHint {
            let matching = deviceSet.filter { name(of: $0).localizedCaseInsensitiveContains(hint) }
            candidates = matching.isEmpty ? Array(deviceSet) : Array(matching)
        } else {
            candidates = Array(deviceSet)
        }

        for candidate in candidates {
            guard let elements = IOHIDDeviceCopyMatchingElements(candidate, nil, IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement] else {
                continue
            }
            // Das HID++ Array-Element: Vendor-Usage-Page, 19 Bytes à 8 Bit.
            func arrayElement(_ type: IOHIDElementType) -> IOHIDElement? {
                elements.first { el in
                    IOHIDElementGetUsagePage(el) >= 0xFF00
                        && IOHIDElementGetType(el) == type
                        && IOHIDElementGetReportCount(el) == UInt32(HIDPPTransport.reportBodyLength)
                        && IOHIDElementGetReportSize(el) == 8
                }
            }
            guard let out = arrayElement(kIOHIDElementTypeOutput),
                  let inp = arrayElement(kIOHIDElementTypeInput_Button) else {
                continue
            }

            IOHIDDeviceScheduleWithRunLoop(candidate, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
            let openDeviceResult = IOHIDDeviceOpen(candidate, IOOptionBits(kIOHIDOptionsTypeNone))
            guard openDeviceResult == kIOReturnSuccess else {
                throw HIDPPError.deviceOpenFailed(openDeviceResult)
            }

            self.manager = mgr
            self.device = candidate
            self.outputElement = out
            self.inputElement = inp
            self.productName = name(of: candidate)
            self.vendorUsagePage = IOHIDElementGetUsagePage(out)
            return productName
        }

        throw HIDPPError.deviceNotFound
    }

    private func readInputElement() -> [UInt8] {
        guard let device = device, let inputElement = inputElement else { return [] }
        let valuePtr = UnsafeMutablePointer<Unmanaged<IOHIDValue>>.allocate(capacity: 1)
        defer { valuePtr.deallocate() }
        guard IOHIDDeviceGetValue(device, inputElement, valuePtr) == kIOReturnSuccess else { return [] }
        let value = valuePtr.pointee.takeUnretainedValue()
        return Array(UnsafeBufferPointer(start: IOHIDValueGetBytePtr(value), count: IOHIDValueGetLength(value)))
    }

    /// Sendet einen HID++ Request und wartet auf die zugehörige Antwort.
    ///
    /// Das Input-Element ist ein Cache des zuletzt empfangenen Reports, kein Stream: eine
    /// Antwort, die byte-identisch mit dem Cache-Inhalt ist, wäre nicht von "noch keine
    /// Antwort" unterscheidbar. Deshalb wird die Software-ID (unteres Nibble von Byte 2)
    /// bei Bedarf so verschoben, dass sie sich von der im Cache stehenden unterscheidet.
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

        let cached = readInputElement()
        var effectiveSwID = (swID & 0x0F) == 0 ? 1 : (swID & 0x0F)
        if cached.count >= 3, (cached[2] & 0x0F) == effectiveSwID {
            effectiveSwID = effectiveSwID == 0x0F ? 1 : effectiveSwID + 1
        }

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
            CFRunLoopRunInMode(.defaultMode, 0.02, true)
            let current = readInputElement()
            if current.count >= 3, current != cached, (current[2] & 0x0F) == effectiveSwID {
                return try HIDPPResponse(body: current)
            }
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
