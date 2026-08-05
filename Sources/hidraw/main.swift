import Foundation
import IOKit
import IOKit.hid

// Diagnose Phase 8: Gibt es Features für die Scrollrichtung beider Räder?
//
// Kandidaten laut Protokolldokumentation:
//   0x2121 HiResWheel  — vertikales Scrollrad, Modus-Flags inkl. Invertierung
//   0x2150 Thumbwheel  — horizontales Daumenrad, Status/Reporting inkl. Invertierung
//   0x2110 SmartShift  — bereits bekannt, zur Kontrolle mit aufgeführt
//
// Ermittelt wird, welche davon das Gerät kennt, in welcher Version, und wie die
// aktuellen Rohwerte aussehen.

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

// --- 0x2121 HiResWheel: welches Bit in SetWheelMode invertiert? ---
if let wheel = featureIndex(0x2121) {
    let before = request(wheel, 0x01).params ?? []
    print("HiResWheel GetWheelMode vorher: \(hexBytes(Array(before.prefix(4))))")
    print("           GetCapability:       \(hexBytes(Array((request(wheel, 0x00).params ?? []).prefix(4))))")

    for bit: UInt8 in [0x01, 0x02, 0x04, 0x08] {
        _ = request(wheel, 0x02, [bit])
        let after = request(wheel, 0x01).params ?? []
        print(String(format: "   SetWheelMode(0x%02X) -> GetWheelMode %@", bit, hexBytes(Array(after.prefix(3)))))
    }
    // Ausgangszustand wiederherstellen.
    _ = request(wheel, 0x02, [before.first ?? 0])
    print("   zurückgesetzt auf: \(hexBytes(Array((request(wheel, 0x01).params ?? []).prefix(3))))")
}

// --- 0x2150 Thumbwheel: Parameterlayout von SetThumbwheelReporting ---
if let thumb = featureIndex(0x2150) {
    let info = request(thumb, 0x00).params ?? []
    let before = request(thumb, 0x01).params ?? []
    print("\nThumbwheel GetInfo:   \(hexBytes(Array(info.prefix(8))))")
    print("           GetStatus vorher: \(hexBytes(Array(before.prefix(4))))")

    for params in [[UInt8(0x00), 0x01], [0x01, 0x00], [0x00, 0x02], [0x02, 0x00]] {
        let r = request(thumb, 0x02, params)
        let after = request(thumb, 0x01).params ?? []
        let verdict = r.error.map { "Fehler 0x\(String(format: "%02X", $0))" } ?? "OK"
        print("   SetReporting(\(hexBytes(params))) -> \(verdict), GetStatus \(hexBytes(Array(after.prefix(3))))")
    }
    // Ausgangszustand wiederherstellen.
    _ = request(thumb, 0x02, [before.count > 0 ? before[0] : 0, before.count > 1 ? before[1] : 0])
    print("   zurückgesetzt auf: \(hexBytes(Array((request(thumb, 0x01).params ?? []).prefix(3))))")
}
