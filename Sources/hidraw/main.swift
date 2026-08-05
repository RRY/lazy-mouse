import Foundation
import IOKit
import IOKit.hid

// Diagnose Phase 12: Lässt sich der Name ändern, den macOS anzeigt?
//
// Der über Feature 0x0007 gesetzte "Friendly Name" taucht in der Bluetooth-Übersicht nicht
// auf — dort steht weiter "MX Master 3S". Zu klären ist, ob Feature 0x0005 (DeviceNameType)
// diesen Namen führt und ob es dafür einen Setter gibt.

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

func featureIndex(_ id: UInt16) -> UInt8? {
    guard let p = request(0x00, 0x00, [UInt8(id >> 8), UInt8(id & 0xFF)]).params,
          p.count >= 1, p[0] != 0 else { return nil }
    return p[0]
}

// 0x0005 DeviceNameType — führt es den von macOS angezeigten Namen?
if let nameType = featureIndex(0x0005) {
    print("=== 0x0005 DeviceNameType (Index \(nameType)) ===")
    for function: UInt8 in 0...5 {
        let r = request(nameType, function, function == 1 ? [0x00] : [])
        if let p = r.params {
            print("  f\(function): \(hexBytes(Array(p.prefix(12))))  '\(ascii(Array(p.prefix(16))))'")
        } else {
            // 0x07 = INVALID_FUNCTION_ID: Funktion existiert nicht
            print("  f\(function): Fehler 0x\(String(format: "%02X", r.error ?? 0))")
        }
    }
}

// 0x0007 zum Vergleich: dort steht der geänderte Name.
if let friendly = featureIndex(0x0007) {
    if let p = request(friendly, 0x01, [0x00]).params, p.count > 1 {
        print("\n=== 0x0007 FriendlyName ===\n  '\(ascii(Array(p[1...])))'")
    }
}
