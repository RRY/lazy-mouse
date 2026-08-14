# Lazy Mouse

Ein HID++ Konfigurator für die Logitech MX Master 3S auf macOS.

Konfiguriert eine MX Master 3S **über Bluetooth LE**, ohne Logitech Options+.
Reiner Userspace, kein Kernel-Treiber. Zwei Oberflächen auf derselben Bibliothek:
die Menüleisten-App `Lazy Mouse` und das CLI `mxctl`.

## Menüleisten-App

```
./build-app.sh          # baut und installiert nach /Applications
open "/Applications/Lazy Mouse.app"
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

### Wo die Einstellungen liegen

Die Maus behält fast nichts. Am Gerät gemessen: nach dem Aus- und Einschalten standen wieder
1000 DPI, und das umgekehrte Daumenrad war nicht mehr umgekehrt. Dauerhaft ist allein die
Bezeichnung (`0x0007`); auch die Tastenumleitung ist flüchtig.

| Einstellung | Gehalten von | Überlebt Ausschalten |
|---|---|---|
| DPI, Scrollrad-Modus, Scrollrichtung | der App | nein — bei jeder Verbindung zurückgeschrieben |
| Tastenumleitung | der App | nein — bei jeder Verbindung neu gesetzt |
| Bezeichnung | dem Gerät | ja |
| Autostart | dem System | ja |

Die App hält die gewünschten Werte deshalb in `UserDefaults` und schreibt sie bei jeder
Verbindung ins Gerät. Nie gesetzte Werte bleiben unberührt, damit ein erster Start nicht
überschreibt, was am Gerät eingestellt war.

Praktische Folge: Ohne laufende App fällt die Maus nach dem nächsten Einschalten auf ihr
Werksverhalten zurück. Der Autostart ist damit weniger Bequemlichkeit als Voraussetzung.

### Wiederverbinden nach dem Ruhezustand

macOS verwirft das `IOHIDDevice`, sobald die Maus verschwindet, und legt bei ihrer Rückkehr
ein **neues** an — nach dem Ruhezustand, nach Aus- und Einschalten, nach einem Kanalwechsel.
Ein Transport, der das Gerät einmalig greift, schreibt danach ins Leere; und weil
fehlgeschlagene Aktualisierungen stillschweigend verworfen wurden, zeigte die Oberfläche
weiter alte Werte, als sei alles in Ordnung.

Ein Gerät kann auch aufhören zu antworten, **ohne** zu verschwinden: nach einem Systemstart
läuft die App, bevor Bluetooth die Maus bereit hat, übernimmt sie, und jede Abfrage läuft
danach in den Timeout. Die Leseroutine verschluckte diese Fehler, sodass sich die App weiter
als verbunden auswies und dabei nichts anzeigte — kein Warndreieck, keine Daten. Ihre erste
Abfrage ist deshalb jetzt verbindlich; scheitert sie, gilt die Verbindung als verloren und
die App versucht es alle fünf Sekunden erneut, bis das Gerät wieder antwortet.

Der gescheiterte *erste* Versuch braucht eigene Sorgfalt. `HIDPPWorker` hielt Transport und
Gerät nur fest, wenn das Verbinden gelang — nach einem Systemstart, wo die App regelmäßig vor
der Bluetooth-Verbindung läuft, blieb die Geräte-Referenz damit für immer leer. Der Transport
meldete die auftauchende Maus zwar korrekt, aber jeder Zugriff scheiterte an `notConnected`,
auch die Wiederholung; nur ein Neustart der App half. Beides wird deshalb unabhängig vom
Ausgang festgehalten. Mit ausgeschalteter Maus beim Start nachgeprüft: derselbe Prozess nahm
sie von allein auf und schrieb die gespeicherten Einstellungen zurück.

`HIDPPTransport` meldet sich beim IOHID-Manager für Zu- und Abgänge an und übernimmt
das neue Gerät selbständig. Bei Wiederkehr liest die App alles neu und **setzt die
Tastenumleitung erneut** — die vergisst das Gerät beim Trennen, die DPI-Taste wäre sonst
wirkungslos, obwohl der Schalter sie als aktiv ausweist. Die Produkt-ID des übernommenen
Geräts wird zur Vorgabe für spätere Zugänge, damit nicht versehentlich ein zweites
Logitech-Gerät eingesammelt wird.

### Sprachen

Die App folgt der Systemsprache und bringt Deutsch und Englisch mit. Die Texte liegen in
`Resources/{de,en}.lproj/Localizable.strings`; `build-app.sh` kopiert sie direkt nach
`Contents/Resources`, sodass `Bundle.main` sie findet — SwiftUIs `Text` und
`String(localized:)` brauchen dann kein Bundle-Argument. Ein SwiftPM-Ressourcenbündel läge
dagegen in einem eigenen `.bundle` und müsste überall ausdrücklich adressiert werden.

Die andere Sprache prüfen, ohne die Systemeinstellungen zu ändern:

```
"/Applications/Lazy Mouse.app/Contents/MacOS/LazyMouse" -AppleLanguages '(en)'
```

`mxctl` ist ausschließlich englisch — bei einem Kommandozeilenwerkzeug erschweren
übersetzte Meldungen das Suchen danach.

### Signatur und dauerhafte Freigabe

macOS merkt sich die erteilte Berechtigung anhand der *Designated Requirement* der App.
Bei einer **Ad-hoc-Signatur** enthält die den `cdhash` des Programms — der ändert sich bei
jedem Neubau, sodass die Eingabeüberwachung jedes Mal neu erteilt werden müsste.

`build-app.sh` signiert deshalb mit einem selbstsignierten Zertifikat. Die Anforderung
lautet dann `identifier "com.lazysoftware.lazymouse" and certificate root = H"…"` und ist damit vom
Programm-Hash unabhängig; die Freigabe übersteht Neubauten. Fehlt das Zertifikat, weicht
das Skript auf eine Ad-hoc-Signatur aus und weist darauf hin.

Das Zertifikat muss **nicht** als vertrauenswürdig eingetragen werden — `codesign`
akzeptiert es auch mit `CSSMERR_TP_NOT_TRUSTED`. Einmalig anlegen:

```
openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem -days 7300 -nodes \
  -subj "/CN=Lazy Mouse Local Signing" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning"

# -legacy und -macalg sha1: security(1) liest die Vorgaben von OpenSSL 3 nicht.
openssl pkcs12 -export -legacy -macalg sha1 -out identity.p12 -inkey key.pem -in cert.pem \
  -name "Lazy Mouse Local Signing" -passout pass:PASSWORT

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
mxctl scroll hires <on|off>
mxctl scroll invert <wheel|thumb> <on|off>
mxctl buttons list
mxctl buttons divert <controlIdHex> <on|off>
mxctl buttons reset <controlIdHex>
mxctl buttons watch [sekunden]
mxctl name [neuer name]       # Gerätename; macOS zeigt die ersten 14 Zeichen nach Neuverbinden
mxctl dpi-cycle [--button <controlIdHex>] [--steps 1000,1600,2400]
```

## DPI-Umschaltung per Taste

`mxctl dpi-cycle` leitet eine Taste um und schaltet bei jedem Druck zur nächsten
DPI-Stufe. Vorbelegt ist die Daumentaste `0x00C3`. Welche DPI-Werte zulässig sind, meldet
das Gerät — bei der MX Master 3S **200 bis 8000 in Schritten von 50**; alles andere lehnt es
mit `INVALID_ARGUMENT` ab (an beiden Grenzen und darüber hinaus geprüft). Das
Einstellungsfenster zeigt den Bereich an und markiert Eingaben, die das Gerät verweigern
würde.

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
`Lazy Mouse` selbst. Achtung beim Testen — wird das App-Binary direkt aus einem berechtigten
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

### Zwei Gerätenamen — macOS zeigt den schreibbaren, gekürzt

Die Maus führt zwei getrennte Namensfelder:

* **`0x0005` DeviceNameType** — `MX Master 3S`, die Modellbezeichnung. Schreibgeschützt:
  Funktionen 3 und höher antworten mit `INVALID_FUNCTION_ID`. Sie bleibt unverändert.
* **`0x0007` DeviceFriendlyName** — frei beschreibbar, bis 18 Zeichen, im Gerät gespeichert.
  Das ist das Feld, das `mxctl name` und das Einstellungsfenster ändern.

**macOS zeigt den Friendly Name, nicht die Modellbezeichnung** — allerdings nur die ersten
**14 Zeichen**, und erst nachdem die Maus sich neu verbunden hat. Am Gerät gemessen, mit
`Ralles Master Maus` als Friendly Name:

| Quelle | Wert |
|---|---|
| `0x0005` DeviceNameType | `MX Master 3S` (unverändert) |
| `0x0007` DeviceFriendlyName | `Ralles Master Maus` (18 Zeichen) |
| `kIOHIDProductKey` / Bluetooth-Einstellungen | `Ralles Master ` (14 Zeichen) |

Die Kürzung passiert auf dem Weg zum Host, nicht im gespeicherten Feld — ein Rücklesen von
`0x0007` liefert weiterhin alle 18 Zeichen.

Deshalb wählt der Transport sein Gerät über die **Produkt-ID** (`0xB034` bei der
MX Master 3S) und nicht über den Produktnamen: Der Name ist beschreibbar, ein Namensfilter
greift nach einer Umbenennung also nicht mehr. Ist kein Gerät mit dieser Produkt-ID da,
kommt jedes Logitech-Gerät mit HID++-Collection in Frage — aus der Bevorzugung wird nie
eine Bedingung.

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

### Gesten: rohe Koordinaten über das virtuelle Control

Für Gesten gibt es einen eigenen Mechanismus, am Gerät nachgemessen:

* Das rawXY-Bit (`0x80` in `GetCidInfo`) trägt **ausschließlich** `0x00D7`
  ("Virtuelle Gestentaste"). Keine physische Taste hat es — auch die Daumentaste `0x00C3`
  nicht, die nur `0x31` meldet.
* Wird ein Control mit `SetCidReporting` und Flags `0x33` versehen (divert `0x01` +
  dvalid `0x02` + rawXY `0x10` + rvalid `0x20`), meldet das Gerät bei gedrückter Taste
  **keine Zeigerbewegung mehr, sondern Rohkoordinaten**. Der Zeiger bleibt sichtbar stehen —
  genau das, was eine Gestenerkennung braucht.
* Format der Meldung: `FF <featureIndex> 10 <X 16 Bit> <Y 16 Bit>`, vorzeichenbehaftet und
  big-endian. Beispiel: `FF 09 10 FF F8 00 01` = X −8, Y +1. Der Tastendruck selbst kommt
  weiterhin als `FF <featureIndex> 00 <cid>`.
* In einem Testlauf über 40 Sekunden kamen 2308 solcher Meldungen.

Eine Gestensteuerung — etwa fürs Fenstermanagement — wäre damit umsetzbar: Koordinaten
zwischen Druck und Loslassen aufsummieren, Richtung bestimmen, Aktion auslösen. Sie
erforderte zusätzlich die Bedienungshilfen-Berechtigung und liefe nur bei laufender App.
Ungeklärt ist, ob `0x00D7` seine Rohkoordinaten zwingend nur bei gedrückter Daumentaste
liefert oder auch mit anderen Tasten zusammenspielt; getestet wurde nur die Daumentaste.

### Die LED ist die Ladeanzeige

Die grüne LED neben dem Daumenrad blinkt beim Laden und bleibt sonst dunkel — auch beim
Wechsel des Easy-Switch-Kanals, für den das Gerät eine eigene Anzeige hat. Beides am Gerät
nachgeprüft. Über HID++ ist sie nicht ansprechbar: `0x18A1 LEDControl` ist in
der Feature-Liste als *technisch* markiert und beantwortet jede Leseabfrage mit Fehler
`0x05` (`LOGITECH_INTERNAL`). Zugänglich wäre sie erst nach dem Freischalten über
`0x1E00 EnableHiddenFeatures` — eine Schnittstelle für Logitechs Produktionstests, deren
Byte-Layouts hier nur zu erraten wären.

### Andere Logitech-Mäuse

Die Feature-Erkennung läuft dynamisch über `Root.GetFeature`, fehlende Features werden
übersprungen, und die Tastenauswahl kommt vom Gerät. Findet der Namensfilter kein
"MX Master", fällt der Transport auf jedes Logitech-Gerät mit HID++-Collection zurück.
Andere moderne MX-Modelle **an direkter Bluetooth-Verbindung** sollten damit ohne Änderung
laufen.

Nicht unterstützt:

* **Unifying-/Bolt-Empfänger.** Der Geräteindex ist fest `0xFF`, was nur für
  Direktverbindungen gilt; am Empfänger haben Geräte Index 1–6 und müssen erst über den
  Empfänger aufgezählt werden.
* **HID++ 1.0** (etwa MX Revolution, Performance MX). Anderes Protokoll ohne Root-Feature.

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
| `Sources/LazyMouse/` | Menüleisten-App (SwiftUI) |
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
