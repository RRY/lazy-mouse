import Foundation
import IOKit
import IOKit.hid

// Diagnose Phase 7: Warum lehnt SetCidReporting (Feature 0x1B04, function 3) mit
// INVALID_ARGUMENT (0x02) ab?
//
// Offene Fragen:
//   a) Welche Version hat Feature 0x1B04 auf diesem Gerät? (Parameter-Layout ist
//      versionsabhängig.)
//   b) Wie lauten die vollständigen GetCidInfo-Rohdaten, insbesondere die Gruppenmaske?
//      Ein Remap ist nur auf Tasks von Controls erlaubt, deren Gruppe in der Maske steckt.
//   c) Welches Flags-Byte akzeptiert das Gerät?

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
/// Gibt (params, errorCode) zurück — errorCode != nil bedeutet HID++ Fehlerantwort.
@discardableResult
func request(_ featureIndex: UInt8, _ function: UInt8, _ params: [UInt8], quiet: Bool = false) -> (params: [UInt8]?, error: UInt8?) {
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
            if b[1] == 0xFF {
                if !quiet { print("     -> FEHLER code=0x\(String(format: "%02X", b[4]))") }
                return (nil, b[4])
            }
            if !quiet { print("     -> \(hexBytes(Array(b[3...])))") }
            return (Array(b[3...]), nil)
        }
    }
    if !quiet { print("     -> TIMEOUT") }
    return (nil, nil)
}

print("=== a) Feature 0x1B04 auflösen (Index + Version) ===")
guard let rootResp = request(0x00, 0x00, [0x1B, 0x04]).params, rootResp.count >= 3, rootResp[0] != 0 else {
    print("Feature 0x1B04 nicht vorhanden.")
    exit(1)
}
let cidFeature = rootResp[0]
print("   Feature-Index=\(cidFeature) type=0x\(String(format: "%02X", rootResp[1])) version=\(rootResp[2])")

print("\n=== b) GetCount + GetCidInfo (Rohdaten) ===")
guard let countResp = request(cidFeature, 0x00, [], quiet: true).params, let count = countResp.first else {
    print("GetCount fehlgeschlagen.")
    exit(1)
}
print("   \(count) Controls")
struct Info { let index: Int; let cid: UInt16; let tid: UInt16; let flags: UInt8; let group: UInt8; let gmask: UInt8 }
var infos: [Info] = []
for i in 0..<Int(count) {
    guard let p = request(cidFeature, 0x01, [UInt8(i)], quiet: true).params, p.count >= 8 else { continue }
    let info = Info(
        index: i,
        cid: (UInt16(p[0]) << 8) | UInt16(p[1]),
        tid: (UInt16(p[2]) << 8) | UInt16(p[3]),
        flags: p[4],
        group: p[6],
        gmask: p[7]
    )
    infos.append(info)
    print(String(format: "   [%d] cid=0x%04X tid=0x%04X flags=0x%02X pos=%d group=%d gmask=0x%02X  roh=%@",
                 i, info.cid, info.tid, info.flags, p[5], info.group, info.gmask, hexBytes(p)))
}

print("\n   Remap-Möglichkeiten (Ziel-Gruppe muss in gmask der Quelle stecken):")
for src in infos where src.gmask != 0 {
    let targets = infos.filter { $0.group != 0 && (src.gmask & (1 << ($0.group - 1))) != 0 }
    let list = targets.map { String(format: "0x%04X", $0.tid) }.joined(separator: ", ")
    print(String(format: "   cid=0x%04X (gmask=0x%02X) -> [%@]", src.cid, src.gmask, list))
}

print("\n=== c) GetCidReporting je Control (Rohdaten) ===")
for info in infos {
    let r = request(cidFeature, 0x02, [UInt8(info.cid >> 8), UInt8(info.cid & 0xFF)], quiet: true)
    if let p = r.params {
        print(String(format: "   cid=0x%04X -> %@", info.cid, hexBytes(p)))
    } else {
        print(String(format: "   cid=0x%04X -> Fehler 0x%02X", info.cid, r.error ?? 0))
    }
}

print("\n=== d) SetCidReporting: Flags-Varianten durchprobieren ===")
// Quelle: eine Taste mit gmask != 0. Ziel: ein laut gmask erlaubtes Task.
guard let src = infos.first(where: { $0.gmask != 0 && $0.cid != 0x0050 && $0.cid != 0x0051 }),
      let dst = infos.first(where: { $0.group != 0 && (src.gmask & (1 << ($0.group - 1))) != 0 && $0.tid != src.tid }) else {
    print("Keine remap-fähige Kombination gefunden.")
    exit(0)
}
print(String(format: "   Quelle cid=0x%04X (nativ tid=0x%04X, gmask=0x%02X), Ziel tid=0x%04X",
             src.cid, src.tid, src.gmask, dst.tid))

let cidHi = UInt8(src.cid >> 8), cidLo = UInt8(src.cid & 0xFF)
let tidHi = UInt8(dst.tid >> 8), tidLo = UInt8(dst.tid & 0xFF)
let srcTidHi = UInt8(src.tid >> 8), srcTidLo = UInt8(src.tid & 0xFF)

// Das 6-Byte-Layout cid(2), flags(1), flags2(1), remap(2) wird akzeptiert; die Flag-Bits
// greifen nachweislich (divert 0x01/dvalid 0x02, persist 0x04/pvalid 0x08,
// rawXY 0x10/rvalid 0x20). Offen ist, welches Bit das Remap-Feld gültig schaltet —
// getestet werden die verbliebenen Bits in Byte 3 und im bisherigen Füllbyte 4.
func remapState() -> (flags: UInt8, remap: UInt16)? {
    guard let p = request(cidFeature, 0x02, [cidHi, cidLo], quiet: true).params, p.count >= 5 else { return nil }
    return (p[2], (UInt16(p[3]) << 8) | UInt16(p[4]))
}

var success: String?
for (label, body) in [
    ("flags=0x40", [cidHi, cidLo, 0x40, 0x00, tidHi, tidLo]),
    ("flags=0x80", [cidHi, cidLo, 0x80, 0x00, tidHi, tidLo]),
    ("flags2=0x01", [cidHi, cidLo, 0x00, 0x01, tidHi, tidLo]),
    ("flags2=0x02", [cidHi, cidLo, 0x00, 0x02, tidHi, tidLo]),
    ("flags2=0x04", [cidHi, cidLo, 0x00, 0x04, tidHi, tidLo]),
    ("flags2=0x08", [cidHi, cidLo, 0x00, 0x08, tidHi, tidLo]),
    ("flags2=0x10", [cidHi, cidLo, 0x00, 0x10, tidHi, tidLo]),
    ("flags2=0x20", [cidHi, cidLo, 0x00, 0x20, tidHi, tidLo]),
    ("flags2=0x40", [cidHi, cidLo, 0x00, 0x40, tidHi, tidLo]),
    ("flags2=0x80", [cidHi, cidLo, 0x00, 0x80, tidHi, tidLo]),
    ("7 Byte, remap am Ende", [cidHi, cidLo, 0x00, 0x00, 0x00, tidHi, tidLo])
] {
    let r = request(cidFeature, 0x03, body, quiet: true)
    let verdict = r.error.map { "Fehler 0x\(String(format: "%02X", $0))" } ?? (r.params != nil ? "OK" : "Timeout")
    let state = remapState()
    let stateText = state.map { String(format: "flags=0x%02X remap=0x%04X", $0.flags, $0.remap) } ?? "?"
    print("   \(label.padding(toLength: 22, withPad: " ", startingAt: 0)) -> \(verdict.padding(toLength: 12, withPad: " ", startingAt: 0)) \(stateText)")
    if state?.remap == dst.tid, success == nil { success = label }
    // Nach jedem Treffer sofort auf nativ zurück.
    if state?.remap == dst.tid {
        var restore = body
        restore[restore.count - 2] = srcTidHi
        restore[restore.count - 1] = srcTidLo
        _ = request(cidFeature, 0x03, restore, quiet: true)
    }
}

if let s = success {
    print("\n   => Remap gesetzt durch: \(s)")
} else {
    print("\n   => Kein Bit setzt das Remap-Feld. Das Gerät akzeptiert die Funktion,")
    print("      wendet aber ausschließlich die Divert-/RawXY-Flags an.")
}

// Aufräumen: alle Flag-Bits auf Default (divert/persist/rawXY aus), remap nativ.
print("\n=== e) Aufräumen: Flags aller Controls auf Default ===")
for info in infos {
    let hi = UInt8(info.cid >> 8), lo = UInt8(info.cid & 0xFF)
    // Jeweils valid-Bit setzen, Wert-Bit auf 0 => divert/persist/rawXY ausschalten.
    _ = request(cidFeature, 0x03, [hi, lo, 0x2A, 0x00, 0x00, 0x00], quiet: true)
    if let p = request(cidFeature, 0x02, [hi, lo], quiet: true).params, p.count >= 5 {
        print(String(format: "   cid=0x%04X -> %@", info.cid, hexBytes(Array(p.prefix(5)))))
    }
}
