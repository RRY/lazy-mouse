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
      mxctl scroll hires <on|off>
      mxctl scroll invert <wheel|thumb> <on|off>
      mxctl buttons list
      mxctl buttons divert <controlIdHex> <on|off>
      mxctl buttons reset <controlIdHex>
      mxctl buttons watch [sekunden]
      mxctl dpi-cycle [--button <controlIdHex>] [--steps 1000,1600,2400]

    Hinweis: Die MX Master 3S kann Tasten nicht geräteseitig umbelegen. Eine umgeleitete
    ("diverted") Taste löst ihre native Aktion nicht mehr aus, sondern meldet den Druck an
    den Host — die eigentliche Aktion führt dann ein laufender Prozess aus, siehe dpi-cycle.
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
    if let name = try? FriendlyNameFeature(device: device).name() {
        print("Name: \(name)")
    }
    let info = DeviceInfoFeature(device: device)
    if let firmware = try? info.firmwareVersion() {
        print("Firmware: \(firmware ?? "?")")
    }
    if let serial = try? info.serialNumber() {
        print("Seriennummer: \(serial ?? "?")")
    }
    if let host = try? HostChannelFeature(device: device).current() {
        print("Kanal: \(host.channel) von \(host.total)")
    }
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
            let wheel = HiResWheelFeature(device: device)
            if let inverted = try? wheel.isInverted(), let hires = try? wheel.isHighResolution() {
                print("Vertikal umgekehrt: \(inverted ? "ja" : "nein"), Feinauflösung: \(hires ? "ein" : "aus")")
            }
            if let thumb = try? ThumbwheelFeature(device: device).isInverted() {
                print("Daumenrad umgekehrt: \(thumb ? "ja" : "nein")")
            }
        } catch {
            fail("Scroll-Status konnte nicht gelesen werden: \(error)")
        }
    case "hires":
        guard args.count >= 3, ["on", "off"].contains(args[2]) else {
            fail("Nutzung: mxctl scroll hires <on|off>")
        }
        do {
            try HiResWheelFeature(device: device).setHighResolution(args[2] == "on")
            print("Feinauflösung \(args[2] == "on" ? "eingeschaltet" : "ausgeschaltet").")
        } catch {
            fail("Feinauflösung konnte nicht gesetzt werden: \(error)")
        }
    case "invert":
        guard args.count >= 4, ["wheel", "thumb"].contains(args[2]), ["on", "off"].contains(args[3]) else {
            fail("Nutzung: mxctl scroll invert <wheel|thumb> <on|off>")
        }
        do {
            let enabled = args[3] == "on"
            if args[2] == "wheel" {
                try HiResWheelFeature(device: device).setInverted(enabled)
            } else {
                try ThumbwheelFeature(device: device).setInverted(enabled)
            }
            print("Umkehrung für \(args[2]) \(enabled ? "ein" : "aus").")
        } catch {
            fail("Umkehrung konnte nicht gesetzt werden: \(error)")
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
            let hex = { (v: UInt16) in String(format: "0x%04X", v) }
            for c in controls {
                let current = try? buttons.reporting(controlID: c.controlID)
                // Aktuelle Zuordnung nur ausweisen, wenn sie von der nativen abweicht.
                let remapNote: String
                if let current = current, current.remappedTaskID != 0, current.remappedTaskID != c.taskID {
                    remapNote = "  -> aktuell \(hex(current.remappedTaskID))"
                } else {
                    remapNote = ""
                }
                print("CID \(hex(c.controlID))  TID \(hex(c.taskID))  flags=0x\(String(c.flags, radix: 16))  group=\(c.group)\(remapNote)")
            }
        } catch {
            fail("Tasten konnten nicht gelesen werden: \(error)")
        }
    case "divert":
        guard args.count >= 4,
              let cid = UInt16(args[2].replacingOccurrences(of: "0x", with: ""), radix: 16),
              ["on", "off"].contains(args[3]) else {
            fail("Nutzung: mxctl buttons divert <controlIdHex> <on|off>")
        }
        do {
            try buttons.setDivert(controlID: cid, enabled: args[3] == "on")
            print("Control \(args[2]): Umleitung \(args[3] == "on" ? "aktiviert" : "deaktiviert").")
        } catch {
            fail("Umleitung fehlgeschlagen: \(error)")
        }
    case "reset":
        guard args.count >= 3,
              let cid = UInt16(args[2].replacingOccurrences(of: "0x", with: ""), radix: 16) else {
            fail("Nutzung: mxctl buttons reset <controlIdHex>")
        }
        do {
            try buttons.resetReporting(controlID: cid)
            print("Control \(args[2]) auf Auslieferungszustand zurückgesetzt.")
        } catch {
            fail("Zurücksetzen fehlgeschlagen: \(error)")
        }
    case "watch":
        let seconds = args.count >= 3 ? (Double(args[2]) ?? 10) : 10
        // Tastendrücke kommen als Notification des Buttons-Features; alles andere bleibt roh.
        let buttonsIndex = try? device.featureIndex(for: SpecialButtonsFeature.featureID)
        print("Lausche \(Int(seconds))s auf Notifications … (umgeleitete Tasten drücken)")
        device.listen(duration: seconds) { body in
            if let buttonsIndex = buttonsIndex, body.count >= 5, body[1] == buttonsIndex {
                let cid = (UInt16(body[3]) << 8) | UInt16(body[4])
                // Eine Meldung mit CID 0 signalisiert das Loslassen der zuvor gemeldeten Taste.
                print(cid == 0 ? "  losgelassen" : String(format: "  gedrückt  CID 0x%04X", cid))
            } else {
                print("  Notification: \(body.map { String(format: "%02X", $0) }.joined(separator: " "))")
            }
        }
        print("Fertig.")
    default:
        printUsage(); exit(1)
    }

case "name":
    let device = connectedDevice()
    let feature = FriendlyNameFeature(device: device)
    guard args.count >= 2 else {
        print((try? feature.name()) ?? "?")
        exit(0)
    }
    do {
        try feature.setName(args[1])
        print("Name gesetzt: \(try feature.name())")
    } catch {
        fail("Name konnte nicht gesetzt werden: \(error)")
    }

case "dpi-cycle":
    // Standard: die Daumentaste. Sie ist ohne Logitech Options ungenutzt, während die
    // kleine Taste oberhalb des Scrollrads (0x00C4) nativ die Rasterung umschaltet.
    var buttonCID: UInt16 = 0x00C3
    var steps = [1000, 1600, 2400]
    if let idx = args.firstIndex(of: "--button"), args.count > idx + 1,
       let parsed = UInt16(args[idx + 1].replacingOccurrences(of: "0x", with: ""), radix: 16) {
        buttonCID = parsed
    }
    if let idx = args.firstIndex(of: "--steps"), args.count > idx + 1 {
        let parsed = args[idx + 1].split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        if parsed.count >= 2 { steps = parsed } else { fail("--steps braucht mindestens zwei Werte, z. B. 1000,1600,2400") }
    }

    let device = connectedDevice()
    let dpiFeature = AdjustableDPIFeature(device: device)
    let buttons = SpecialButtonsFeature(device: device)
    let buttonsIndex = try? device.featureIndex(for: SpecialButtonsFeature.featureID)

    let originalDPI = (try? dpiFeature.currentDPI().current) ?? steps[0]
    // Beim nächsten Druck auf den Schritt wechseln, der auf den aktuellen Wert folgt.
    var stepIndex = steps.firstIndex(of: originalDPI) ?? 0

    do {
        try buttons.setDivert(controlID: buttonCID, enabled: true)
    } catch {
        fail("Taste konnte nicht umgeleitet werden: \(error)")
    }

    // Aufräumen ist Pflicht: eine umgeleitete Taste bleibt sonst dauerhaft wirkungslos.
    func cleanup() {
        try? buttons.resetReporting(controlID: buttonCID)
        try? dpiFeature.setDPI(originalDPI)
    }

    var stopping = false
    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)
    let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    sigintSource.setEventHandler { stopping = true }
    sigtermSource.setEventHandler { stopping = true }
    sigintSource.resume()
    sigtermSource.resume()

    print(String(format: "DPI-Umschaltung aktiv auf Taste 0x%04X. Stufen: %@ (aktuell %d).",
                 buttonCID, steps.map(String.init).joined(separator: ", "), originalDPI))
    print("Beenden mit Strg-C — die Taste wird dabei zurückgesetzt.")

    device.listen(duration: .greatestFiniteMagnitude, shouldStop: { stopping }) { body in
        guard let buttonsIndex = buttonsIndex, body.count >= 5, body[1] == buttonsIndex else { return }
        let cid = (UInt16(body[3]) << 8) | UInt16(body[4])
        // Nur der Druck schaltet; das Loslassen meldet CID 0 und wird übergangen.
        guard cid == buttonCID else { return }
        stepIndex = (stepIndex + 1) % steps.count
        do {
            try dpiFeature.setDPI(steps[stepIndex])
            print("  DPI \(steps[stepIndex])")
        } catch {
            print("  DPI-Wechsel fehlgeschlagen: \(error)")
        }
    }

    cleanup()
    print("Beendet, Taste und DPI zurückgesetzt.")

default:
    printUsage()
    exit(command == "help" || command == "--help" ? 0 : 1)
}
