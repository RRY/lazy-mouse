# mxctl — HID++ Konfigurator für die Logitech MX Master 3S auf macOS

Schlankes, natives CLI-Tool zum Konfigurieren einer MX Master 3S **über Bluetooth LE**,
ohne Logitech Options+. Reiner Userspace, kein Kernel-Treiber.

```
mxctl status                  # Gerät, Batterie, DPI, Scroll-Modus
mxctl battery                 # Ladezustand
mxctl dpi get | set <wert>
mxctl scroll get | set <ratchet|freespin|auto> [--threshold N]
mxctl buttons list
mxctl buttons divert <controlIdHex> <on|off>
mxctl buttons reset <controlIdHex>
mxctl buttons watch [sekunden]
mxctl dpi-cycle [--button <controlIdHex>] [--steps 1000,1600,2400]
```

## DPI-Umschaltung per Taste

`mxctl dpi-cycle` leitet eine Taste um und schaltet bei jedem Druck zur nächsten
DPI-Stufe. Vorbelegt ist die Daumentaste `0x00C3`:

```
mxctl dpi-cycle --steps 800,1600,3200
```

Läuft, bis es mit Strg-C beendet wird; dabei werden Taste und ursprünglicher DPI-Wert
zurückgesetzt. Solange es läuft, entfällt die native Funktion der Taste — bei der
Daumentaste ist das die Gestensteuerung, die ohne Logitech Options ohnehin ungenutzt ist.

Andere Tasten lassen sich mit `--button` wählen, etwa die kleine Taste oberhalb des
Scrollrads: `mxctl dpi-cycle --button 00C4`. Deren native Funktion ist allerdings die
Umschaltung zwischen gerastertem und freilaufendem Scrollrad — die entfällt dann während
der Laufzeit, und nach dem Beenden kann das Rad im zuletzt per Hand gewählten Zustand
stehen.

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

4. **Empfangen läuft über `IOHIDDeviceRegisterInputReportCallback`.**
   Der Callback liefert den Report inklusive führender Report-ID, der HID++-Body beginnt
   also bei Index 1. (Ein früherer Zwischenstand hielt den Callback für funktionslos — das
   war ein Trugschluss: getestet wurde er zu einem Zeitpunkt, als noch `SetReport` zum
   Senden verwendet wurde und deshalb überhaupt keine Antwort eintraf.)

5. **Das Input-*Element* taugt nicht als Empfangsquelle.**
   Es cacht nur den zuletzt empfangenen Report. Viele SET-Aufrufe lösen unmittelbar nach
   ihrer Antwort eine Notification aus — gemessen ~15 ms später —, die den Cache
   überschreibt. Ein Polling-Intervall von 20 ms verliert die Antwort dadurch
   reproduzierbar, obwohl der Schreibvorgang selbst erfolgreich war. Zusätzlich wäre eine
   Antwort, die byte-identisch mit dem Cache-Inhalt ist, nicht von "noch keine Antwort"
   unterscheidbar.

6. **CoreBluetooth ist kein Weg.** Sobald macOS die Maus als HID-Eingabegerät übernimmt,
   taucht sie weder in `retrieveConnectedPeripherals` auf noch advertised sie noch — ein
   direkter GATT-Zugriff ist damit ausgeschlossen (siehe `Sources/gattscan`).

7. **Der USB-C-Anschluss der MX Master 3S ist reiner Ladeanschluss.** Angeschlossen
   erscheint kein USB-Gerät in der IORegistry; der Kabelweg steht als Transport nicht
   zur Verfügung.

8. **Kein On-Device-Remapping.** `SetCidReporting` (Feature `0x1B04` v5) hat das Layout
   `cid(2), flags(1), reserved(1), remap(2)`; das reservierte Byte muss 0 sein, sonst
   antwortet das Gerät mit `INVALID_ARGUMENT`. Die Flag-Bits greifen zuverlässig
   (divert `0x01`/valid `0x02`, persist `0x04`/`0x08`, rawXY `0x10`/`0x20`), das Remap-Feld
   wird jedoch nie übernommen — `GetCidReporting` liefert danach unverändert `0x0000`.
   Getestet wurden beide Byte-Layouts und alle Flag-Bits. Tastenbelegung wie in Logi Options+
   läuft folglich nicht auf dem Gerät, sondern über Divert plus Host-Software.

9. **Diverted Tasten melden Press und Release getrennt.** Notification-Format:
   `FF <featureIndex> 00 <cid_hi> <cid_lo>` beim Druck, mit CID `0x0000` beim Loslassen.

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

Alle Befehle sind gegen echte Hardware verifiziert:

| Bereich | Verifikation |
|---|---|
| Feature-Discovery | Indizes für `0x1004`, `0x2201`, `0x2110`, `0x1B04` aufgelöst |
| Batterie | 85 % gelesen, Statusbyte plausibel (entlädt) |
| DPI | gelesen und geschrieben: 1000 → 1600 → 1000 |
| SmartShift | gelesen und geschrieben: ratchet → freespin → ratchet |
| Tasten-Enumeration | 8 Controls inkl. Gruppen und Gruppenmasken |
| Divert | Umleitung gesetzt, Press/Release-Notifications empfangen, zurückgesetzt |
| `dpi-cycle` | vier Tastendrücke schalteten 1000 → 1600 → 2400 → 1000 → 1600 |

Nicht möglich: On-Device-Remapping (siehe Punkt 8 oben) — die Hardware unterstützt es nicht.
Tastenaktionen brauchen deshalb einen laufenden Prozess; `dpi-cycle` ist die erste
Umsetzung dieses Musters und lässt sich als Vorlage für weitere Aktionen verwenden.
