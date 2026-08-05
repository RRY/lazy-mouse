import Foundation
import HIDPPKit

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

func connectedDevice() -> HIDPPDevice {
    let transport = HIDPPTransport()
    let device = HIDPPDevice(transport: transport)
    do {
        let name = try device.connect()
        FileHandle.standardError.write("Verbunden mit: \(name)\n".data(using: .utf8)!)
    } catch {
        fail("Verbindung fehlgeschlagen: \(error)")
    }
    return device
}

func printUsage() {
    print("""
    mxctl — schlanker HID++ Konfigurator für die Logitech MX Master 3S (Bluetooth)

    Verwendung:
      mxctl status
      mxctl battery
      mxctl dpi get
      mxctl dpi set <wert>
      mxctl scroll get
      mxctl scroll set <ratchet|freespin|auto> [--threshold N]
      mxctl buttons list
      mxctl buttons set <controlIdHex> <taskIdHex>
    """)
}

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else {
    printUsage()
    exit(0)
}

switch command {
case "status":
    let device = connectedDevice()
    print("Produkt: \(device.productName)")
    if let battery = try? BatteryFeature(device: device).status() {
        print("Batterie: \(battery.percentage)% (\(battery.chargingStatus))")
    }
    if let dpi = try? AdjustableDPIFeature(device: device).currentDPI() {
        print("DPI: \(dpi.current) (Standard: \(dpi.default))")
    }
    if let scroll = try? SmartShiftFeature(device: device).status() {
        print("Scrollrad: \(scroll.mode)")
    }

case "battery":
    let device = connectedDevice()
    do {
        let status = try BatteryFeature(device: device).status()
        print("\(status.percentage)% — \(status.chargingStatus)\(status.externalPowerConnected ? ", Netzteil verbunden" : "")")
    } catch {
        fail("Batteriestatus konnte nicht gelesen werden: \(error)")
    }

case "dpi":
    let device = connectedDevice()
    let dpiFeature = AdjustableDPIFeature(device: device)
    guard args.count >= 2 else { printUsage(); exit(1) }
    switch args[1] {
    case "get":
        do {
            let dpi = try dpiFeature.currentDPI()
            print("Aktuell: \(dpi.current) DPI (Standard: \(dpi.default))")
            if let list = try? dpiFeature.dpiList() {
                if let range = list.range {
                    print("Gültiger Bereich: \(range.min)–\(range.max), Schrittweite \(range.step)")
                }
                if !list.fixedValues.isEmpty {
                    print("Feste Stufen: \(list.fixedValues)")
                }
            }
        } catch {
            fail("DPI konnte nicht gelesen werden: \(error)")
        }
    case "set":
        guard args.count >= 3, let value = Int(args[2]) else { fail("Nutzung: mxctl dpi set <wert>") }
        do {
            try dpiFeature.setDPI(value)
            print("DPI auf \(value) gesetzt.")
        } catch {
            fail("DPI konnte nicht gesetzt werden: \(error)")
        }
    default:
        printUsage(); exit(1)
    }

case "scroll":
    let device = connectedDevice()
    let smartShift = SmartShiftFeature(device: device)
    guard args.count >= 2 else { printUsage(); exit(1) }
    switch args[1] {
    case "get":
        do {
            let status = try smartShift.status()
            print("Modus: \(status.mode), Auto-Schwelle: \(status.autoDisengageThreshold)")
        } catch {
            fail("Scroll-Status konnte nicht gelesen werden: \(error)")
        }
    case "set":
        guard args.count >= 3 else { fail("Nutzung: mxctl scroll set <ratchet|freespin|auto> [--threshold N]") }
        let mode: SmartShiftFeature.Mode
        switch args[2] {
        case "ratchet": mode = .ratchet
        case "freespin": mode = .freespin
        case "auto": mode = .auto
        default: fail("Unbekannter Modus '\(args[2])' — erlaubt: ratchet, freespin, auto")
        }
        var threshold = 0
        if let idx = args.firstIndex(of: "--threshold"), args.count > idx + 1, let t = Int(args[idx + 1]) {
            threshold = t
        }
        do {
            try smartShift.setMode(mode, threshold: threshold)
            print("Scrollrad-Modus auf \(mode) gesetzt.")
        } catch {
            fail("Scroll-Modus konnte nicht gesetzt werden: \(error)")
        }
    default:
        printUsage(); exit(1)
    }

case "buttons":
    let device = connectedDevice()
    let buttons = SpecialButtonsFeature(device: device)
    guard args.count >= 2 else { printUsage(); exit(1) }
    switch args[1] {
    case "list":
        do {
            let controls = try buttons.listControls()
            for c in controls {
                let hex = { (v: UInt16) in String(format: "0x%04X", v) }
                print("CID \(hex(c.controlID))  TID \(hex(c.taskID))  flags=0x\(String(c.flags, radix: 16))  group=\(c.group)")
            }
        } catch {
            fail("Tasten konnten nicht gelesen werden: \(error)")
        }
    case "set":
        guard args.count >= 4,
              let cid = UInt16(args[2].replacingOccurrences(of: "0x", with: ""), radix: 16),
              let tid = UInt16(args[3].replacingOccurrences(of: "0x", with: ""), radix: 16) else {
            fail("Nutzung: mxctl buttons set <controlIdHex> <taskIdHex>")
        }
        do {
            try buttons.remap(controlID: cid, toTaskID: tid)
            print("Control \(args[2]) auf Task \(args[3]) umgemappt.")
        } catch {
            fail("Remap fehlgeschlagen: \(error)")
        }
    default:
        printUsage(); exit(1)
    }

default:
    printUsage()
    exit(command == "help" || command == "--help" ? 0 : 1)
}
