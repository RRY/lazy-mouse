import Foundation
import IOKit
import IOKit.hid

// Diagnose Phase 16: Wirkt der Friendly Name (0x0007) auf den von macOS gezeigten Namen?
//
// Frühere Annahme war, dass 0x0005 DeviceNameType davon unberührt bleibt. Nach einem
// Neuverbinden zeigt macOS jedoch den gesetzten Namen. Hier werden beide Felder samt Länge
// ausgelesen, um zu klären, ob 0x0007 in 0x0005 durchschlägt und wo die Kürzung entsteht.

func ascii(_ b: [UInt8]) -> String {
    String(bytes: b.filter { $0 >= 0x20 && $0 < 0x7F }, encoding: .ascii) ?? ""
}
func hexBytes(_ b: [UInt8]) -> String { b.map { String(format: "%02X", $0) }.joined(separator: " ") }

let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey as String: 0x046D] as CFDictionary)
guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess,
      let deviceSet = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>,
      let device = deviceSet.first(where: { d in
          guard let els = IOHIDDeviceCopyMatchingElements(d, nil, IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement] else { return false }
          return els.contains { IOHIDElementGetUsagePage($0) >= 0xFF00 && IOHIDElementGetType($0) == kIOHIDElementTypeOutput
              && IOHIDElementGetReportCount($0) == 19 }
      }),
      let elements = IOHIDDeviceCopyMatchingElements(device, nil, IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement],
      let outElement = elements.first(where: {
          IOHIDElementGetUsagePage($0) >= 0xFF00 && IOHIDElementGetType($0) == kIOHIDElementTypeOutput
              && IOHIDElementGetReportCount($0) == 19 && IOHIDElementGetReportSize($0) == 8
      }) else {
    print("Kein Logitech-HID++-Gerät gefunden.")
    exit(1)
}

let hidName = (IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String) ?? "?"
print("HID-Produktname (das zeigt macOS): '\(hidName)'  (\(hidName.count) Zeichen)")

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
func request(_ featureIndex: UInt8, _ function: UInt8, _ params: [UInt8] = []) -> [UInt8]? {
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
            return b[1] == 0xFF ? nil : Array(b[3...])
        }
    }
    return nil
}

func featureIndex(_ id: UInt16) -> UInt8? {
    guard let p = request(0x00, 0x00, [UInt8(id >> 8), UInt8(id & 0xFF)]), p[0] != 0 else { return nil }
    return p[0]
}

/// Liest einen blockweise übertragenen Namen zusammen.
func readName(_ index: UInt8, function: UInt8, length: Int) -> String {
    var collected: [UInt8] = []
    var offset = 0
    while collected.count < length, offset < length {
        guard let p = request(index, function, [UInt8(offset)]), p.count > 1 else { break }
        let chunk = Array(p[1...])
        collected += chunk
        offset += chunk.count
    }
    return ascii(Array(collected.prefix(length)))
}

if let nameType = featureIndex(0x0005) {
    let count = request(nameType, 0x00)?.first ?? 0
    print("\n0x0005 DeviceNameType — gemeldete Länge: \(count)")
    // Bei 0x0005 beginnt die Antwort direkt mit den Zeichen, ohne Index davor.
    var collected: [UInt8] = []
    var offset = 0
    while collected.count < Int(count), offset < Int(count) {
        guard let p = request(nameType, 0x01, [UInt8(offset)]) else { break }
        collected += p
        offset += p.count
    }
    print("  Name: '\(ascii(Array(collected.prefix(Int(count)))))'")
    print("  roh:  \(hexBytes(Array(collected.prefix(Int(count)))))")
}

if let friendly = featureIndex(0x0007) {
    let lens = request(friendly, 0x00) ?? []
    print("\n0x0007 DeviceFriendlyName — aktuell \(lens.first ?? 0), max \(lens.count > 1 ? lens[1] : 0)")
    print("  Name: '\(readName(friendly, function: 0x01, length: Int(lens.first ?? 0)))'")
}
