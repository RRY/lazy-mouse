# mxctl — HID++ Konfigurator für die Logitech MX Master 3S auf macOS

Schlankes, natives CLI-Tool zum Konfigurieren einer MX Master 3S **über Bluetooth LE**,
ohne Logitech Options+. Reiner Userspace, kein Kernel-Treiber.

```
mxctl status                  # Gerät, Batterie, DPI, Scroll-Modus
mxctl battery                 # Ladezustand
mxctl dpi get | set <wert>
mxctl scroll get | set <ratchet|freespin|auto> [--threshold N]
mxctl buttons list | set <controlIdHex> <taskIdHex>
```

## Voraussetzung: Eingabeüberwachung

Das Tool matcht HID-Geräte nur über die Vendor-ID (siehe unten, warum das nötig ist).
macOS wertet das als Zugriff auf Eingabegeräte und verlangt die Berechtigung
**Systemeinstellungen → Datenschutz & Sicherheit → Eingabeüberwachung** für die
aufrufende Anwendung (Terminal, IDE o. ä.). Ohne sie schlägt `IOHIDManagerOpen`
mit `kIOReturnNotPermitted` (`0xE00002E2`) fehl.

## Protokoll-Erkenntnisse (Bluetooth LE, macOS 26, MX Master 3S)

Diese Punkte weichen deutlich vom klassischen HID++ über USB/Unifying-Empfänger ab und
wurden empirisch gegen echte Hardware ermittelt (die Diagnose-Schritte stecken in der
Git-Historie von `Sources/hidraw`):

1. **Keine eigene HID++ Vendor-Collection als separates Gerät.**
   Über einen USB-Empfänger erscheint die HID++-Schnittstelle üblicherweise als eigenes
   `IOHIDDevice` auf Usage Page `0xFF00`. Bei direkter BLE-Kopplung gibt es nur *ein*
   `IOHIDDevice`, das die Vendor-Collection als zusätzliches Usage-Pair mitführt — hier
   Usage Page **`0xFF43`**, Usage `0x0202`. `IOHIDManagerSetDeviceMatching` auf die
   Usage Page findet das Gerät deshalb **nicht**; es muss über die Vendor-ID `0x046D`
   gematcht und die Collection anschließend über die Elemente identifiziert werden.

2. **Nur Report-ID `0x11` (Long, 19 Byte Body).**
   Das klassische Short-Format `0x10` existiert nicht — `GetReport`/`SetReport` darauf
   liefern `kIOReturnNotFound`.

3. **`IOHIDDeviceSetReport` sendet nichts.**
   Der Aufruf liefert `kIOReturnSuccess`, aber das Output-Element bleibt auf Null und es
   kommt nie eine Antwort. Funktionierend ist ausschließlich **`IOHIDDeviceSetValue`** auf
   dem 19-Byte-Output-Array-Element der Vendor-Collection.

4. **Antworten kommen nicht per Callback.**
   Weder `IOHIDDeviceRegisterInputReportCallback` noch `RegisterInputValueCallback` feuern
   für diese Collection. Die Antwort muss per `IOHIDDeviceGetValue` vom Input-Array-Element
   **gepollt** werden.

5. **Das Input-Element ist ein Cache, kein Stream.**
   Es hält immer den zuletzt empfangenen Report. Eine Antwort, die byte-identisch mit dem
   Cache-Inhalt ist (z. B. dieselbe Anfrage zweimal hintereinander), ist damit nicht von
   "noch keine Antwort" unterscheidbar. `HIDPPTransport.request` wählt deshalb die
   Software-ID gezielt so, dass sie sich von der im Cache stehenden unterscheidet.

6. **CoreBluetooth ist kein Weg.** Sobald macOS die Maus als HID-Eingabegerät übernimmt,
   taucht sie weder in `retrieveConnectedPeripherals` auf noch advertised sie noch — ein
   direkter GATT-Zugriff ist damit ausgeschlossen (siehe `Sources/gattscan`).

7. **Der USB-C-Anschluss der MX Master 3S ist reiner Ladeanschluss.** Angeschlossen
   erscheint kein USB-Gerät in der IORegistry; der Kabelweg steht als Transport nicht
   zur Verfügung.

## Aufbau

| Pfad | Zweck |
|---|---|
| `Sources/HIDPPKit/HIDPPTransport.swift` | IOKit-Transport (Punkte 1–5 oben) |
| `Sources/HIDPPKit/HIDPPDevice.swift` | Feature-Discovery via Root-Feature `0x0000`, generischer Aufruf |
| `Sources/HIDPPKit/Features/` | Battery `0x1004`, DPI `0x2201`, SmartShift `0x2110`, Buttons `0x1B04` |
| `Sources/mxctl/` | CLI |
| `Sources/hidraw/` | Diagnose-Tool für die IOKit/HID++-Ebene |
| `Sources/gattscan/` | Diagnose-Tool für den (gescheiterten) CoreBluetooth-Weg |

## Stand

Verifiziert gegen echte Hardware: Feature-Discovery, Batterie (85 %), DPI lesen **und
schreiben** (1000 → 1600 → 1000), SmartShift-Status, Enumeration der 8 programmierbaren
Tasten.

Noch nicht gegen Hardware verifiziert: `buttons set` (On-Device-Remap) und
`scroll set`. Software-interpretierte Gesten (wie der Gesten-Button in Logitech Options)
bräuchten zusätzlich einen dauerhaft laufenden Daemon und sind nicht Teil dieses Tools.
