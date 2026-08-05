import Foundation
import IOKit
import IOKit.hid

// Diagnose Phase 5: Verifikation des gefundenen Transportwegs.
//
// Erkenntnis aus Phase 1–4 (Bluetooth LE, MX Master 3S, macOS 26):
//   - Die HID++ Vendor-Collection liegt auf Usage Page 0xFF43 und nutzt ausschließlich
//     Report-ID 0x11 (Long, 19 Byte Body) — kein klassisches 0x10 (Short).
//   - IOHIDDeviceSetReport(Output, 0x11) liefert zwar kIOReturnSuccess, sendet aber NICHTS:
//     das Output-Element bleibt auf Null, es kommt nie eine Antwort.
//   - IOHIDDeviceSetValue auf dem 19-Byte-Output-Array-Element funktioniert dagegen.
//   - Antworten erscheinen NICHT über den InputReport-/InputValue-Callback, sondern müssen
//     per IOHIDDeviceGetValue vom Input-Array-Element gepollt werden.
//
// Dieses Tool fährt damit eine vollständige Sequenz: Root.GetFeature(0x1004) -> Feature-Index,
// dann Battery.GetStatus über diesen Index.

func hexBytes(_ b: [UInt8]) -> String { b.map { String(format: "%02X", $0) }.joined(separator: " ") }
func ioReturnName(_ r: IOReturn) -> String {
    switch r {
    case kIOReturnSuccess: return "Success"
    case kIOReturnNotFound: return "NotFound"
    case kIOReturnNotPermitted: return "NotPermitted"
    case kIOReturnUnsupported: return "Unsupported"
    case kIOReturnBadArgument: return "BadArgument"
    case kIOReturnTimeout: return "Timeout"
    case kIOReturnError: return "Error"
    default: return String(format: "0x%08X", r)
    }
}

let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey as String: 0x046D] as CFDictionary)
guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess,
      let deviceSet = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>,
      let device = deviceSet.first(where: { (IOHIDDeviceGetProperty($0, kIOHIDProductKey as CFString) as? String)?.localizedCaseInsensitiveContains("MX Master") == true }) else {
    print("MX Master nicht gefunden oder Manager-Open fehlgeschlagen (Eingabeüberwachung erteilt?).")
    exit(1)
}
IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
_ = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))

guard let elements = IOHIDDeviceCopyMatchingElements(device, nil, IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement] else {
    print("Keine Elemente.")
    exit(1)
}

// Die beiden 19-Byte-Array-Elemente auf Report 0x11 der Vendor-Page: eines Input, eines Output.
func arrayElement(type: IOHIDElementType) -> IOHIDElement? {
    elements.first { el in
        IOHIDElementGetUsagePage(el) == 0xFF43
            && IOHIDElementGetReportID(el) == 0x11
            && IOHIDElementGetType(el) == type
            && IOHIDElementGetReportCount(el) == 19
            && IOHIDElementGetReportSize(el) == 8
    }
}
guard let outElement = arrayElement(type: kIOHIDElementTypeOutput),
      let inElement = arrayElement(type: kIOHIDElementTypeInput_Button) else {
    print("HID++ Array-Elemente nicht gefunden.")
    exit(1)
}
print("Output-Element cookie=\(IOHIDElementGetCookie(outElement)), Input-Element cookie=\(IOHIDElementGetCookie(inElement))")

func readInput() -> [UInt8] {
    let valuePtr = UnsafeMutablePointer<Unmanaged<IOHIDValue>>.allocate(capacity: 1)
    defer { valuePtr.deallocate() }
    guard IOHIDDeviceGetValue(device, inElement, valuePtr) == kIOReturnSuccess else { return [] }
    let v = valuePtr.pointee.takeUnretainedValue()
    return Array(UnsafeBufferPointer(start: IOHIDValueGetBytePtr(v), count: IOHIDValueGetLength(v)))
}

/// Sendet einen HID++ Request und pollt das Input-Element, bis eine Antwort mit passender
/// Software-ID eintrifft.
///
/// Das Input-Element ist ein Cache des zuletzt empfangenen Reports, kein Stream: eine Antwort,
/// die byte-identisch mit dem Cache-Inhalt ist, wäre nicht von "keine Antwort" unterscheidbar.
/// Deshalb wird die Software-ID so gewählt, dass sie sich von der im Cache stehenden unterscheidet.
func hidppRequest(featureIndex: UInt8, function: UInt8, swID requestedSwID: UInt8, params: [UInt8], timeout: TimeInterval = 2.0) -> [UInt8]? {
    let before = readInput()
    var swID = requestedSwID == 0 ? 1 : (requestedSwID & 0x0F)
    if before.count >= 3, (before[2] & 0x0F) == swID {
        swID = swID == 0x0F ? 1 : swID + 1
    }
    var body = [UInt8](repeating: 0, count: 19)
    body[0] = 0xFF
    body[1] = featureIndex
    body[2] = (function << 4) | (swID & 0x0F)
    for (i, p) in params.prefix(16).enumerated() { body[3 + i] = p }

    let sent = body.withUnsafeMutableBufferPointer { b -> Bool in
        guard let value = IOHIDValueCreateWithBytes(kCFAllocatorDefault, outElement, 0, b.baseAddress!, b.count) else { return false }
        return IOHIDDeviceSetValue(device, outElement, value) == kIOReturnSuccess
    }
    print("  >> req feature=\(String(format: "0x%02X", featureIndex)) func=\(function) sw=\(swID) params=\(hexBytes(params)) -> \(sent ? "gesendet" : "SENDEN FEHLGESCHLAGEN")")
    guard sent else { return nil }

    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        CFRunLoopRunInMode(.defaultMode, 0.05, true)
        let now = readInput()
        if now.count >= 3, now != before, (now[2] & 0x0F) == swID {
            print("  << resp \(hexBytes(now))")
            if now[1] == 0xFF {
                print("     (HID++ Fehlerantwort, code=0x\(String(format: "%02X", now.count > 4 ? now[4] : 0)))")
                return nil
            }
            return Array(now[3...])
        }
    }
    print("  << TIMEOUT")
    return nil
}

print("\n=== 1) Root.GetFeature(0x1004 Unified Battery) ===")
guard let rootResp = hidppRequest(featureIndex: 0x00, function: 0x00, swID: 1, params: [0x10, 0x04]),
      let batteryIndex = rootResp.first, batteryIndex != 0 else {
    print("Feature 0x1004 nicht verfügbar.")
    exit(1)
}
print("   -> Battery-Feature-Index = \(batteryIndex)")

print("\n=== 2) Battery.GetStatus (Feature-Index \(batteryIndex), function 1) ===")
if let batteryResp = hidppRequest(featureIndex: batteryIndex, function: 0x01, swID: 2, params: []) {
    print("   -> Rohantwort: \(hexBytes(batteryResp))")
    if batteryResp.count >= 3 {
        print("   -> Ladestand: \(batteryResp[0])%  (Byte1=\(batteryResp[1]) Byte2=\(batteryResp[2]))")
    }
}

print("\n=== 3) Root.GetFeature(0x2201 Adjustable DPI) ===")
if let dpiFeatureResp = hidppRequest(featureIndex: 0x00, function: 0x00, swID: 3, params: [0x22, 0x01]),
   let dpiIndex = dpiFeatureResp.first, dpiIndex != 0 {
    print("   -> DPI-Feature-Index = \(dpiIndex)")
    print("\n=== 4) DPI.GetSensorDpi (Sensor 0) ===")
    if let dpiResp = hidppRequest(featureIndex: dpiIndex, function: 0x02, swID: 4, params: [0x00]) {
        print("   -> Rohantwort: \(hexBytes(dpiResp))")
        if dpiResp.count >= 3 {
            let dpi = (Int(dpiResp[1]) << 8) | Int(dpiResp[2])
            print("   -> Aktuelle DPI: \(dpi)")
        }
    }
} else {
    print("   Feature 0x2201 nicht verfügbar.")
}
