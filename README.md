# HID++ Konfigurator für die Logitech MX Master 3S auf macOS

Konfiguriert eine MX Master 3S **über Bluetooth LE**, ohne Logitech Options+.
Reiner Userspace, kein Kernel-Treiber. Zwei Oberflächen auf derselben Bibliothek:
die Menüleisten-App `MX Menu` und das CLI `mxctl`.

## Menüleisten-App

```
./build-app.sh          # baut und installiert nach /Applications
open "/Applications/MX Menu.app"
```

Das Symbol zeigt den Batteriestand direkt in der Menüleiste. Das Menü bietet DPI-Stufen,
den Scrollrad-Modus, den Schalter für die DPI-Taste und den Autostart. Das
Einstellungsfenster (⌘,) erlaubt zusätzlich die Wahl der Taste und der DPI-Stufen.

Die Werte werden einmal pro Minute aktualisiert.

Die App installiert bewusst nach `/Applications`: macOS bindet die Freigabe der
Eingabeüberwachung an Pfad und Signatur, ein wechselnder Pfad im Projektordner würde sie
bei jedem Neubau ungültig machen. Nach dem ersten Start muss die Berechtigung erteilt und
die App neu gestartet werden — bei fehlender Freigabe zeigt das Symbol ein Warndreieck und
das Menü einen Direktlink in die Systemeinstellungen.

### Signatur und dauerhafte Freigabe

macOS merkt sich die erteilte Berechtigung anhand der *Designated Requirement* der App.
Bei einer **Ad-hoc-Signatur** enthält die den `cdhash` des Programms — der ändert sich bei
jedem Neubau, sodass die Eingabeüberwachung jedes Mal neu erteilt werden müsste.

`build-app.sh` signiert deshalb mit einem selbstsignierten Zertifikat. Die Anforderung
lautet dann `identifier "de.ryback.mxmenu" and certificate root = H"…"` und ist damit vom
Programm-Hash unabhängig; die Freigabe übersteht Neubauten. Fehlt das Zertifikat, weicht
das Skript auf eine Ad-hoc-Signatur aus und weist darauf hin.

Das Zertifikat muss **nicht** als vertrauenswürdig eingetragen werden — `codesign`
akzeptiert es auch mit `CSSMERR_TP_NOT_TRUSTED`. Einmalig anlegen:

```
openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem -days 7300 -nodes \
  -subj "/CN=MX Menu Local Signing" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning"

# -legacy und -macalg sha1: security(1) liest die Vorgaben von OpenSSL 3 nicht.
openssl pkcs12 -export -legacy -macalg sha1 -out identity.p12 -inkey key.pem -in cert.pem \
  -name "MX Menu Local Signing" -passout pass:PASSWORT

security import identity.p12 -k ~/Library/Keychains/login.keychain-db \
  -P PASSWORT -T /usr/bin/codesign
```

Danach `key.pem`, `cert.pem` und `identity.p12` löschen — der private Schlüssel liegt im
Schlüsselbund. Ein abweichender Name lässt sich über `SIGN_IDENTITY` setzen.

## CLI

```
mxctl status                  # Gerät, Batterie, DPI, Scroll-Modus
mxctl battery                 # Ladezustand
mxctl dpi get | set <wert>
mxctl scroll get | set <ratchet|freespin|auto> [--threshold N]
mxctl buttons list
mxctl buttons divert <controlIdHex> <on|off>
mxctl buttons reset <controlIdHex>
mxctl buttons watch [sekunden]
mxctl name [neuer name]       # interner Gerätename (nicht der in den BT-Einstellungen)
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
**Systemeinstellungen → Datenschutz & Sicherheit → Eingabeüberwachung**. Ohne sie schlägt
`IOHIDManagerOpen` mit `kIOReturnNotPermitted` (`0xE00002E2`) fehl.

Die Freigabe gilt pro Anwendung: beim CLI für das aufrufende Terminal, bei der App für
`MX Menu` selbst. Achtung beim Testen — wird das App-Binary direkt aus einem berechtigten
Terminal gestartet, erbt es dessen Freigabe und funktioniert, während dieselbe App per
`open` scheitert.

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

10. **Der Setter für den Gerätenamen liegt auf Funktion 3, nicht 2.** Bei Feature `0x0007`
    liefert Funktion 2 den *Standard*namen — ein Schreibversuch darauf wird klaglos
    quittiert, ändert aber nichts. Funktion 3 schreibt und meldet die Zahl der übernommenen
    Zeichen zurück, Funktion 4 setzt auf den Werksnamen zurück. Ein Rücklesen nach dem
    Schreiben deckt solche stillen Fehlschläge auf.

### Reentranz: keine RunLoop-Blöcke für HID-Aufträge

`HIDPPTransport.request` pumpt beim Warten auf die Geräteantwort die RunLoop. Werden
Aufträge über `CFRunLoopPerformBlock` eingereiht, führt diese Pumpe **den nächsten
wartenden Block innerhalb des laufenden aus**. Der innere Aufruf leert dabei den
Empfangspuffer des Transports, sodass die Antwort des äußeren verloren geht — je nach
Verschachtelung mit stillschweigend falschem Ergebnis oder als Hänger.

Aufgefallen ist das erst, als zwei Lesevorgänge unmittelbar nacheinander eingereiht wurden
(Geräteinfo und Statusabfrage beim Verbinden): Die Firmware kam als `nil` an, während
Seriennummer und Name aus demselben Block korrekt gelesen wurden. `HIDPPWorker` führt
deshalb eine eigene Warteschlange und entnimmt Aufträge nur auf oberster Ebene der
Thread-Schleife, außerhalb jedes RunLoop-Aufrufs.

### Zwei Gerätenamen, nur einer ist schreibbar

Die Maus führt zwei getrennte Namensfelder:

* **`0x0005` DeviceNameType** — `MX Master 3S`. Diesen Namen zeigt macOS in den
  Bluetooth-Einstellungen. Das Feature hat **keinen Setter**: Funktionen 3 und höher
  antworten mit `INVALID_FUNCTION_ID`. Über HID++ ist er nicht änderbar.
* **`0x0007` DeviceFriendlyName** — frei beschreibbar, im Gerät gespeichert, von Logitechs
  eigener Software zur Beschriftung genutzt. Das ist das Feld, das `mxctl name` und das
  Einstellungsfenster ändern.

Ein über `0x0007` gesetzter Name taucht in der Bluetooth-Übersicht deshalb nicht auf. Das
Einstellungsfenster bietet ihn aus diesem Grund nicht an — wer das Feld dennoch setzen
will, nimmt `mxctl name`.

### Scrollauflösung: nur 1 oder 15, nichts dazwischen

Feature `0x2121` kennt ein Auflösungs-Bit; im Feinmodus meldet das Rad 15 Schritte je Raste
statt einem (Multiplikator aus `GetWheelCapability`). Zwischenstufen gibt es nicht:

* `0x2121` hat die Funktionen 0–4, danach `INVALID_FUNCTION_ID`. Ein Multiplikator als
  zweites Byte von `SetWheelMode` wird quittiert, die Capability meldet aber unverändert 15.
* Der dafür vorgesehene **Standard-HID Resolution Multiplier** (Generic Desktop, Usage
  `0x48`) fehlt dem Gerät.
* Das benachbarte, undokumentierte `0x2251` bietet nur Lesewerte.

In der Praxis wirkt der Feinmodus dadurch nicht wie feineres, sondern wie 15-fach
schnelleres Scrollen — macOS behandelt jeden Schritt als vollen Impuls. Das
Einstellungsfenster bietet ihn deshalb nicht an; für Versuche bleibt `mxctl scroll hires`.

Eine echte Zwischenstufe ginge nur, indem das Rad per `target`-Bit auf HID++ umgeleitet und
die Scroll-Ereignisse selbst erzeugt werden. Das erfordert die Bedienungshilfen-Berechtigung
und lässt das Rad tot zurück, sobald der Prozess nicht läuft. Werkzeuge wie Mac Mouse Fix
gehen diesen Weg und lassen sich parallel betreiben: sie setzen an den Ereignissen an,
dieses Projekt an der Gerätekonfiguration.

### Die LED ist die Ladeanzeige

Die grüne LED neben dem Daumenrad blinkt beim Laden und bleibt sonst dunkel — auch beim
Wechsel des Easy-Switch-Kanals, für den das Gerät eine eigene Anzeige hat. Beides am Gerät
nachgeprüft. Über HID++ ist sie nicht ansprechbar: `0x18A1 LEDControl` ist in
der Feature-Liste als *technisch* markiert und beantwortet jede Leseabfrage mit Fehler
`0x05` (`LOGITECH_INTERNAL`). Zugänglich wäre sie erst nach dem Freischalten über
`0x1E00 EnableHiddenFeatures` — eine Schnittstelle für Logitechs Produktionstests, deren
Byte-Layouts hier nur zu erraten wären.

### Was die MX Master 3S nicht kann

Die Feature-Liste des Geräts (36 Einträge, ermittelt über Feature `0x0001`) enthält weder
`0x8060` (Abtastrate) noch `0x8100` (Profile im Gerät) — beides gibt es bei dieser Maus
schlicht nicht, anders als bei Logitechs Gaming-Modellen. Ebenso wenig eine Beschleunigungs-
oder Kurveneinstellung; die liegt bei macOS. Der überwiegende Teil der übrigen Features ist
als *versteckt* oder *technisch* markiert (Firmware-Update, SPI-Direktzugriff, LED-Steuerung)
und für den Alltag ohne Belang.

## MenuBarExtra in Menü-Darstellung

Drei Einschränkungen, die in dieser App umgangen werden mussten — alle nur in der
Menü-Darstellung, nicht bei `.menuBarExtraStyle(.window)`:

* Das **Label wird nicht neu gezeichnet**, wenn sich ausschließlich sein Inhalt ändert. Der
  Batteriestand blieb dadurch unsichtbar; eine vom Wert abhängige `.id(...)` erzwingt den
  Neuaufbau.
* **`SettingsLink` funktioniert nicht.** Der verbreitete Umweg über den undokumentierten
  Selektor `showSettingsWindow:` hängt zudem von der macOS-Version ab. Stattdessen hält
  `SettingsWindowController` ein eigenes `NSWindow`.
* Es wird nur eine **begrenzte Auswahl an Views** gerendert (Text, Button, Toggle, Menu,
  Divider) — komplexere Layouts erscheinen nicht.

## Aufbau

| Pfad | Zweck |
|---|---|
| `Sources/HIDPPKit/HIDPPTransport.swift` | IOKit-Transport (Punkte 1–5 oben) |
| `Sources/HIDPPKit/HIDPPDevice.swift` | Feature-Discovery via Root-Feature `0x0000`, generischer Aufruf |
| `Sources/HIDPPKit/Features/` | Battery `0x1004`, DPI `0x2201`, SmartShift `0x2110`, Buttons `0x1B04` |
| `Sources/HIDPPKit/HIDPPWorker.swift` | HID-Zugriffe auf eigenem Thread, damit die GUI nicht blockiert (siehe Reentranz unten) |
| `Sources/MXMenu/` | Menüleisten-App (SwiftUI) |
| `Sources/mxctl/` | CLI |
| `build-app.sh` | baut und installiert die App nach `/Applications` |
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
