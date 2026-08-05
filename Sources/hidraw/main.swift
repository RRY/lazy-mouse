import Foundation
import IOKit
import IOKit.hid

// Diagnose Phase 15: Liefert das virtuelle Gesten-Control rohe Koordinaten?
//
// Erster Versuch scheiterte, weil nur das Divert-Bit gesetzt war. Für rohe X/Y-Meldungen
// braucht SetCidReporting zusätzlich das rawXY-Bit (Wert 0x10, gültig ab 0x20).
// Gesetzt wird es hier auf dem virtuellen Control 0x00D7 und auf der physischen
// Daumentaste 0x00C3; am Ende wird beides zurückgesetzt.

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

final class Inbox {
    var bodies: [[UInt8]] = []
    var notifications: [[UInt8]] = []
}
let inbox = Inbox()
let inBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
IOHIDDeviceRegisterInputReportCallback(device, inBuf, 64, { context, _, _, _, reportID, report, length in
    guard let context = context, UInt8(truncatingIfNeeded: reportID) == 0x11 else { return }
    let inbox = Unmanaged<Inbox>.fromOpaque(context).takeUnretainedValue()
    let raw = Array(UnsafeBufferPointer(start: report, count: length))
    guard raw.count > 1 else { return }
    let body = Array(raw.dropFirst())
    inbox.bodies.append(body)
    if body.count >= 3, (body[2] & 0x0F) == 0 { inbox.notifications.append(body) }
}, Unmanaged.passUnretained(inbox).toOpaque())

var swCounter: UInt8 = 0
@discardableResult
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

guard let root = request(0x00, 0x00, [0x1B, 0x04]).params, root[0] != 0 else {
    print("0x1B04 nicht vorhanden."); exit(1)
}
let buttons = root[0]

// divert (0x01) + dvalid (0x02) + rawXY (0x10) + rvalid (0x20) = 0x33
let divertAndRaw: UInt8 = 0x33
// alle Wert-Bits zurück auf 0, alle valid-Bits gesetzt = 0x2A
let reset: UInt8 = 0x2A

for cid: UInt16 in [0x00D7, 0x00C3] {
    let hi = UInt8(cid >> 8), lo = UInt8(cid & 0xFF)
    let r = request(buttons, 0x03, [hi, lo, divertAndRaw, 0x00, 0x00, 0x00])
    let state = request(buttons, 0x02, [hi, lo]).params ?? []
    print(String(format: "cid=0x%04X setzen -> %@, Status danach: %@",
                 cid,
                 r.error.map { "Fehler 0x\(String(format: "%02X", $0))" } ?? "OK",
                 hexBytes(Array(state.prefix(5)))))
}

print("\nLausche 40s — Daumentaste halten und Maus bewegen …")
inbox.notifications.removeAll()
let deadline = Date().addingTimeInterval(40)
var shown = 0
while Date() < deadline {
    CFRunLoopRunInMode(.defaultMode, 0.05, true)
    while shown < inbox.notifications.count {
        let n = inbox.notifications[shown]
        shown += 1
        if shown <= 40 { print("  \(hexBytes(Array(n.prefix(10))))") }
    }
}
print("Meldungen gesamt: \(inbox.notifications.count)")

for cid: UInt16 in [0x00D7, 0x00C3] {
    request(buttons, 0x03, [UInt8(cid >> 8), UInt8(cid & 0xFF), reset, 0x00, 0x00, 0x00])
}
print("Beide Controls zurückgesetzt.")
