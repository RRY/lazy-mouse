import Foundation
import IOKit
import IOKit.hid

// Diagnose Phase 11: welche Funktion von 0x0007 (DeviceFriendlyName) schreibt wirklich?
//
// Ein Aufruf von function 2 mit [byteIndex, Zeichen] lief fehlerfrei durch, ließ den Namen
// aber unverändert. Verdacht: function 2 ist getDefaultFriendlyName (ein Getter), der
// Setter liegt auf function 3.

func hexBytes(_ b: [UInt8]) -> String { b.map { String(format: "%02X", $0) }.joined(separator: " ") }
func ascii(_ b: [UInt8]) -> String {
    String(bytes: b.filter { $0 >= 0x20 && $0 < 0x7F }, encoding: .ascii) ?? ""
}

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

guard let root = request(0x00, 0x00, [0x00, 0x07]).params, root[0] != 0 else {
    print("0x0007 nicht vorhanden."); exit(1)
}
let name = root[0]

func currentName() -> String {
    guard let p = request(name, 0x01, [0x00]).params, p.count > 1 else { return "?" }
    return ascii(Array(p[1...]))
}

print("Name jetzt: '\(currentName())'")
print("Längen: \(hexBytes(Array((request(name, 0x00).params ?? []).prefix(3))))")

// Alle Funktionen ohne Parameter abklopfen, um Getter von Settern zu trennen.
print("\n--- Funktionen ohne Parameter ---")
for function: UInt8 in 0...5 {
    let r = request(name, function)
    if let p = r.params {
        print("  f\(function): \(hexBytes(Array(p.prefix(10))))  '\(ascii(Array(p.prefix(16))))'")
    } else {
        print("  f\(function): Fehler 0x\(String(format: "%02X", r.error ?? 0))")
    }
}

// Schreibversuch auf f2 und f3, jeweils mit Kontrolle.
let probe: [UInt8] = Array("ZZTest".utf8)
for function: UInt8 in [2, 3] {
    let r = request(name, function, [0x00] + probe)
    let verdict = r.error.map { "Fehler 0x\(String(format: "%02X", $0))" } ?? "OK \(hexBytes(Array((r.params ?? []).prefix(4))))"
    print("\n  setze über f\(function): \(verdict)")
    print("  Name danach: '\(currentName())'")
}

// In jedem Fall den ursprünglichen Namen wiederherstellen.
let original: [UInt8] = Array("MX Master 3S".utf8)
for function: UInt8 in [3, 2] {
    _ = request(name, function, [0x00] + original)
}
print("\nName am Ende: '\(currentName())'")
