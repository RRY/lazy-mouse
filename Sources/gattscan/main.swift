import Foundation
import CoreBluetooth

// Diagnostic tool: connects to the MX Master 3S over CoreBluetooth and lists ALL GATT
// services and characteristics. Purpose: find out whether HID++ runs over a separate,
// non-standard service that IOHIDManager and HID-over-GATT do not pass through.
//
// Outcome: it does not. Once macOS claims the mouse as a HID input device, it appears
// neither in retrieveConnectedPeripherals nor in advertisements. Kept as a record of the
// dead end.

final class Scanner: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var central: CBCentralManager!
    var target: CBPeripheral?
    var expectedServiceCount = 0
    var discoveredCharCount = 0

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        print("Bluetooth-Status: \(central.state.rawValue)")
        guard central.state == .poweredOn else { return }

        let hidService = CBUUID(string: "1812")
        let connected = central.retrieveConnectedPeripherals(withServices: [hidService])
        print("Verbundene Peripherals mit HID-Service: \(connected.count)")
        for p in connected {
            print(" - \(p.name ?? "unbenannt") \(p.identifier)")
        }

        if let mouse = connected.first(where: { ($0.name ?? "").localizedCaseInsensitiveContains("MX Master") }) ?? connected.first {
            target = mouse
            mouse.delegate = self
            print("Verbinde mit \(mouse.name ?? "?")...")
            central.connect(mouse, options: nil)
        } else {
            print("Keine verbundene Maus über retrieveConnectedPeripherals gefunden — versuche Scan (10s)...")
            central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? "?"
        print("Scan-Treffer: \(name) \(peripheral.identifier) RSSI=\(RSSI)")
        if name.localizedCaseInsensitiveContains("MX Master") {
            central.stopScan()
            target = peripheral
            peripheral.delegate = self
            central.connect(peripheral, options: nil)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        print("Verbunden mit \(peripheral.name ?? "?"). Entdecke Services...")
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        print("Verbindung fehlgeschlagen: \(String(describing: error))")
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            print("Fehler bei Service-Discovery: \(error)")
            return
        }
        guard let services = peripheral.services else { return }
        expectedServiceCount = services.count
        print("Services (\(services.count)):")
        for s in services {
            print("  Service \(s.uuid)  (isPrimary=\(s.isPrimary))")
            peripheral.discoverCharacteristics(nil, for: s)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        discoveredCharCount += 1
        if let error = error {
            print("    Fehler bei Char-Discovery für \(service.uuid): \(error)")
        } else if let chars = service.characteristics {
            for c in chars {
                print("    Char \(c.uuid)  properties=\(c.properties.rawValue)")
                if c.properties.contains(.read) {
                    peripheral.readValue(for: c)
                }
            }
        }
        if discoveredCharCount >= expectedServiceCount {
            print("--- Discovery abgeschlossen ---")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let data = characteristic.value {
            print("      Wert \(characteristic.uuid): \(data as NSData)")
        }
    }
}

let scanner = Scanner()
DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
    print("--- Timeout, beende ---")
    exit(0)
}
CFRunLoopRun()
