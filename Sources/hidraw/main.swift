import Foundation
import IOKit
import IOKit.hid

// Diagnose Phase 13: Gibt es Zwischenstufen zwischen normaler und Feinauflösung?
//
// 0x2121 meldet einen festen Multiplikator von 15, das Modus-Bit ist binär. Zu prüfen:
//   a) Hat 0x2121 weitere Funktionen jenseits von 0..3 (etwa zum Setzen des Multiplikators)?
//   b) Was verbirgt sich hinter dem in der Feature-Liste unbekannten 0x2251?
//   c) Bietet die Standard-HID-Ebene einen Resolution Multiplier (Usage 0x48)?

func hexBytes(_ b: [UInt8]) -> String { b.map { String(format: "%02X", $0) }.joined(separator: " ") }

let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey as String: 0x046D] as CFDictionary)
guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess,
      let deviceSet = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>,
      let device = deviceSet.first(where: { (IOHIDDeviceGetProperty($0, kIOHIDProductKey as CFString) as? String)?.localizedCaseInsensitiveContains("MX Master") == true }),
      let elements = IOHIDDeviceCopyMatchingElements(device, nil, IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement],
      let outElement = elements.first(where: {
          IOHIDElementGetUsagePage($0) >= 0xFF00 && IOHIDElementGetType($0) == kIOHIDElementTypeOutput
              && IOHIDElementGetReportCount($0) == 19 && IOHIDElementGetReportSize($0) == 8
      }) else {
    print("MX Master nicht gefunden.")
    exit(1)
}

IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
_ = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))

final class Inbox { var bodies: [[UInt8]] = [] }
let inbox = Inbox()
let inBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
IOHIDDeviceRegisterInputReportCallback(device, inBuf, 64, { context, _, _, _, reportID, report, length in
    guard let context = context, UInt8(truncatingIfNeeded: reportID) == 0x11 else { return }
    let inbox = Unmanaged<Inbox>.fromOpaque(context).takeUnretainedValue()
    let raw = Array(UnsafeBufferPointer(start: report, count: length))
    if raw.count > 1 { inbox.bodies.append(Array(raw.dropFirst())) }
}, Unmanaged.passUnretained(inbox).toOpaque())

var swCounter: UInt8 = 0
func request(_ featureIndex: UInt8, _ function: UInt8, _ params: [UInt8] = []) -> (params: [UInt8]?, error: UInt8?) {
    swCounter = swCounter >= 0x0F ? 1 : swCounter + 1
    let swID = swCounter
    inbox.bodies.removeAll()
    var body = [UInt8](repeating: 0, count: 19)
    body[0] = 0xFF
    body[1] = featureIndex
    body[2] = (function << 4) | swID
    for (i, p) in params.prefix(16).enumerated() { body[3 + i] = p }
    _ = body.withUnsafeMutableBufferPointer { b -> Bool in
        guard let v = IOHIDValueCreateWithBytes(kCFAllocatorDefault, outElement, 0, b.baseAddress!, b.count) else { return false }
        return IOHIDDeviceSetValue(device, outElement, v) == kIOReturnSuccess
    }
    let deadline = Date().addingTimeInterval(2.0)
    while Date() < deadline {
        CFRunLoopRunInMode(.defaultMode, 0.01, true)
        for b in inbox.bodies where b.count >= 4 {
            let funcSw = b[1] == 0xFF ? b[3] : b[2]
            guard (funcSw & 0x0F) == swID else { continue }
            if b[1] == 0xFF { return (nil, b[4]) }
            return (Array(b[3...]), nil)
        }
    }
    return (nil, nil)
}

func featureIndex(_ id: UInt16) -> UInt8? {
    guard let p = request(0x00, 0x00, [UInt8(id >> 8), UInt8(id & 0xFF)]).params,
          p.count >= 1, p[0] != 0 else { return nil }
    return p[0]
}

// a) Alle Funktionen von 0x2121 — Fehler 0x07 bedeutet: Funktion existiert nicht.
if let wheel = featureIndex(0x2121) {
    print("=== 0x2121 HiResWheel: Funktionsumfang ===")
    for function: UInt8 in 0...7 {
        let r = request(wheel, function)
        if let p = r.params {
            print("  f\(function): \(hexBytes(Array(p.prefix(6))))")
        } else {
            print("  f\(function): Fehler 0x\(String(format: "%02X", r.error ?? 0))")
        }
    }
    // Versuch, den Multiplikator zu setzen: als zweites Byte hinter dem Modus.
    print("  Versuch setWheelMode mit zweitem Byte (Multiplikator 5):")
    let r = request(wheel, 0x02, [0x02, 0x05])
    print("    -> \(r.error.map { "Fehler 0x\(String(format: "%02X", $0))" } ?? "OK \(hexBytes(Array((r.params ?? []).prefix(4))))")")
    print("    Capability danach: \(hexBytes(Array((request(wheel, 0x00).params ?? []).prefix(4))))")
    // Modus wieder auf normal.
    _ = request(wheel, 0x02, [0x00])
}

// b) 0x2251 — in der Feature-Liste ohne Namen.
if let unknown = featureIndex(0x2251) {
    print("\n=== 0x2251 (unbekannt), Index \(unknown) ===")
    for function: UInt8 in 0...3 {
        let r = request(unknown, function)
        if let p = r.params {
            print("  f\(function): \(hexBytes(Array(p.prefix(10))))")
        } else {
            print("  f\(function): Fehler 0x\(String(format: "%02X", r.error ?? 0))")
        }
    }
}

// c) Standard-HID: Resolution Multiplier (Generic Desktop, Usage 0x48)?
print("\n=== Standard-HID-Elemente: Resolution Multiplier (Usage 0x48) ===")
let resolutionElements = elements.filter { IOHIDElementGetUsagePage($0) == 0x01 && IOHIDElementGetUsage($0) == 0x48 }
if resolutionElements.isEmpty {
    print("  keine — das Gerät bietet keinen HID-Resolution-Multiplier an")
} else {
    for el in resolutionElements {
        print(String(format: "  cookie=%d type=%d reportID=0x%02X min=%d max=%d",
                     IOHIDElementGetCookie(el), IOHIDElementGetType(el).rawValue,
                     IOHIDElementGetReportID(el),
                     IOHIDElementGetLogicalMin(el), IOHIDElementGetLogicalMax(el)))
    }
}
