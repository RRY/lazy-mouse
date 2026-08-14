# Lazy Mouse

A HID++ configurator for the Logitech MX Master 3S on macOS.

Configures an MX Master 3S **over Bluetooth LE**, without Logitech Options+.
Pure userspace, no kernel driver. Two front ends on one library: the menu bar app
`Lazy Mouse` and the `mxctl` command line tool.

*(Eine deutsche Fassung dieser Datei liegt unter [README.de.md](README.de.md).)*

> Not affiliated with, endorsed by, or sponsored by Logitech. "Logitech", "MX Master" and
> "Logi Options+" are trademarks of Logitech and are used here only to identify the
> hardware this tool talks to.

## Scope and caveats

Everything here was developed and verified against **one MX Master 3S paired directly over
Bluetooth LE** on macOS 26. Other modern MX models on a direct Bluetooth connection are
likely to work — feature discovery is dynamic — but they have not been tested. Unifying and
Bolt receivers are **not** supported, nor are older HID++ 1.0 devices. See
[Other Logitech mice](#other-logitech-mice).

## Menu bar app

```
./build-app.sh          # builds and installs to /Applications
open "/Applications/Lazy Mouse.app"
```

The icon shows the battery level right in the menu bar. The menu offers DPI steps, the
scroll wheel mode, the toggle for the DPI button and launch-at-login. The settings window
(⌘,) additionally lets you pick the button and the DPI steps.

Values are refreshed once a minute.

The app deliberately installs into `/Applications`: macOS ties the Input Monitoring grant to
path and signature, so a changing path inside the project folder would invalidate it on
every rebuild. After the first launch the permission has to be granted and the app
restarted — while it is missing, the icon shows a warning triangle and the menu offers a
direct link to System Settings.

### Where settings live

The mouse keeps almost nothing. Measured on the device: after switching it off and on, DPI
was back to 1000 and the inverted thumb wheel was no longer inverted. Only the device name
(`0x0007`) survives; button diversion is volatile as well.

| Setting | Held by | Survives power off |
|---|---|---|
| DPI, scroll mode, scroll direction | the app | no — written back on every connection |
| Button diversion | the app | no — set again on every connection |
| Device name | the device | yes |
| Launch at login | the system | yes |

The app therefore stores the wanted values in `UserDefaults` and writes them to the device
whenever a connection is established. Values that were never set stay untouched, so a first
run does not overwrite whatever the device came with.

The practical consequence: without the app running, the mouse falls back to its factory
behaviour after the next power cycle. Launch at login is less a convenience than a
prerequisite.

### Reconnecting after sleep

macOS discards the `IOHIDDevice` when the mouse disconnects and creates a **new** one when
it comes back — after sleep, after the mouse is switched off and on, after a channel change.
A transport that grabs the device once therefore writes into the void from then on, and
because failed refreshes were dropped silently the UI kept showing stale values as if
nothing was wrong.

A device can also stop answering **without** disappearing: after a system restart the app
starts before Bluetooth has the mouse ready, adopts it, and every request then times out.
The refresh routine used to swallow those errors, so the app kept claiming a connection
while showing nothing — no warning triangle, no data. Its first read is therefore mandatory
now, and a failure marks the connection as lost and starts a retry every five seconds until
the device answers again.

The failed *first* attempt needs care of its own. `HIDPPWorker` used to keep transport and
device only when connecting succeeded, so after a system start — where the app regularly
runs before Bluetooth has the mouse — the device reference stayed nil forever. The transport
reported the arriving mouse correctly, but every access failed with `notConnected`, the retry
included; only a restart of the app helped. Both are therefore kept regardless of the
outcome. Verified with the mouse switched off at launch: the same process picked it up on
its own and wrote the stored settings back.

`HIDPPTransport` registers matching and removal callbacks on the IOHID manager
and adopts the new device on its own. On reconnect the app re-reads everything and **sets
the button diversion again** — the device forgets it when disconnecting, so the DPI button
would otherwise be dead while the toggle still claimed it was active. The product ID of the
adopted device becomes the preference for later arrivals, so a second Logitech device cannot
be picked up by mistake.

### Languages

The app follows the system language and ships German and English. Strings live in
`Resources/{de,en}.lproj/Localizable.strings`; `build-app.sh` copies them straight into
`Contents/Resources` so `Bundle.main` picks them up — SwiftUI's `Text` and
`String(localized:)` then need no bundle argument. A SwiftPM resource bundle would sit in a
separate `.bundle` and have to be addressed explicitly everywhere.

To check the other language without changing system settings:

```
"/Applications/Lazy Mouse.app/Contents/MacOS/LazyMouse" -AppleLanguages '(en)'
```

`mxctl` is English only — a command line tool with translated output would make its
messages harder to search for.

### Signing and a permission that sticks

macOS remembers a granted permission by the app's *designated requirement*. With an
**ad-hoc signature** that requirement contains the program's `cdhash` — which changes with
every rebuild, so Input Monitoring would have to be granted again each time.

`build-app.sh` therefore signs with a self-signed certificate. The requirement then reads
`identifier "com.lazysoftware.lazymouse" and certificate root = H"…"`, independent of the program
hash, and the grant survives rebuilds. Without the certificate the script falls back to an
ad-hoc signature and says so.

The certificate does **not** need to be marked as trusted — `codesign` accepts it even with
`CSSMERR_TP_NOT_TRUSTED`. Create it once:

```
openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem -days 7300 -nodes \
  -subj "/CN=Lazy Mouse Local Signing" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning"

# -legacy and -macalg sha1: security(1) cannot read OpenSSL 3's defaults.
openssl pkcs12 -export -legacy -macalg sha1 -out identity.p12 -inkey key.pem -in cert.pem \
  -name "Lazy Mouse Local Signing" -passout pass:PASSWORD

security import identity.p12 -k ~/Library/Keychains/login.keychain-db \
  -P PASSWORD -T /usr/bin/codesign
```

Delete `key.pem`, `cert.pem` and `identity.p12` afterwards — the private key lives in the
keychain. A different name can be set through `SIGN_IDENTITY`.

If an Apple-issued **Developer ID** is present, the script prefers it and signs with
hardened runtime and a timestamp. With `NOTARIZE_PROFILE=<name>` set it also submits the
app for notarization and staples the ticket. Notarization took 18 minutes here; Apple gives
no guaranteed turnaround.

Switching from the local certificate to a Developer ID **invalidates the granted Input
Monitoring**. The requirement changes from `certificate root = H"…"` to
`anchor apple generic and certificate leaf[subject.OU] = <team ID>`, and TCC treats that as a
different program: the app runs but cannot reach the device, and it does not write its stored
settings back. Remove the old entry under Privacy & Security → Input Monitoring with the
minus button, add the app again and restart it — toggling the existing entry is often not
enough. This happens once; later rebuilds with the same Developer ID keep the requirement.

## Distribution

```
./make-dmg.sh                              # signed disk image in dist/
NOTARIZE_PROFILE=<profile> ./make-dmg.sh   # additionally notarized and stapled
```

A disk image rather than an installer package: the program is a single bundle, the login item
registers itself through `SMAppService`, and nothing is placed outside `/Applications`. A
`.pkg` would additionally require its own *Developer ID Installer* certificate, while the
image is signed with the same *Developer ID Application* identity as the app.

The image contains a symlink to `/Applications`. That is not decoration — macOS ties the
granted Input Monitoring to the app's path, so a copy left in `~/Downloads` loses the
permission the moment it is moved.

Notarizing the image is worthwhile even though the app inside already carries its ticket:
without it Gatekeeper warns when the image is opened, before the app is ever seen.

`dist/` is not tracked; build artefacts belong in a release, not in the repository.

## CLI

```
mxctl status                  # device, battery, DPI, scroll mode
mxctl battery                 # charge level
mxctl dpi get | set <value>
mxctl scroll get | set <ratchet|freespin|auto> [--threshold N]
mxctl scroll hires <on|off>
mxctl scroll invert <wheel|thumb> <on|off>
mxctl buttons list
mxctl buttons divert <controlIdHex> <on|off>
mxctl buttons reset <controlIdHex>
mxctl buttons watch [seconds]
mxctl name [new name]         # device name; macOS shows its first 14 chars after reconnect
mxctl dpi-cycle [--button <controlIdHex>] [--steps 1000,1600,2400]
```

## Switching DPI with a button

`mxctl dpi-cycle` diverts a button and steps to the next DPI level on every press. The
thumb button `0x00C3` is the default. Valid DPI values come from the device — **200 to 8000
in steps of 50** on the MX Master 3S; anything else is rejected with `INVALID_ARGUMENT`
(verified at both ends and beyond). The settings window shows the range and flags entries
the device would refuse.

```
mxctl dpi-cycle --steps 800,1600,3200
```

It runs until stopped with Ctrl-C, resetting the button and the original DPI value on the
way out. While it runs the button loses its native function — for the thumb button that is
gesture control, which does nothing anyway without Logitech Options.

Other buttons can be chosen with `--button`, for instance the small button above the scroll
wheel: `mxctl dpi-cycle --button 00C4`. Its native function is toggling between a ratcheted
and a free-spinning wheel, so that is what you give up while it runs — and afterwards the
wheel may sit in whichever state was last selected by hand.

## Requirement: Input Monitoring

The tool matches HID devices by vendor ID alone (see below for why that is necessary). macOS
treats that as access to input devices and requires the **System Settings → Privacy &
Security → Input Monitoring** permission. Without it `IOHIDManagerOpen` fails with
`kIOReturnNotPermitted` (`0xE00002E2`).

The grant is per application: for the CLI it applies to the calling terminal, for the app to
`Lazy Mouse` itself. Watch out when testing — an app binary started directly from a permitted
terminal inherits that terminal's grant and works, while the very same app fails when
launched with `open`.

## Protocol findings (Bluetooth LE, macOS 26, MX Master 3S)

These points differ markedly from classic HID++ over a USB/Unifying receiver and were
established empirically against real hardware (the diagnostic steps are in the git history
of `Sources/hidraw`):

1. **No separate HID++ vendor collection as its own device.**
   Through a USB receiver the HID++ interface usually shows up as a separate `IOHIDDevice`
   on usage page `0xFF00`. With a direct BLE pairing there is only *one* `IOHIDDevice`,
   carrying the vendor collection as an additional usage pair — here usage page **`0xFF43`**,
   usage `0x0202`. `IOHIDManagerSetDeviceMatching` on the usage page therefore does **not**
   find the device; it has to be matched by vendor ID `0x046D` and the collection identified
   afterwards through its elements.

2. **Only report ID `0x11` (long, 19-byte body).**
   The classic short format `0x10` does not exist — `GetReport`/`SetReport` on it return
   `kIOReturnNotFound`.

3. **`IOHIDDeviceSetReport` sends nothing.**
   The call returns `kIOReturnSuccess`, but the output element stays zero and no answer ever
   arrives. The only thing that works is **`IOHIDDeviceSetValue`** on the 19-byte output
   array element of the vendor collection.

4. **Receiving goes through `IOHIDDeviceRegisterInputReportCallback`.**
   The callback delivers the report including the leading report ID, so the HID++ body
   starts at index 1. (An earlier iteration considered the callback non-functional — a
   fallacy: it was tested at a time when `SetReport` was still used for sending, so no
   answer was arriving at all.)

5. **The input *element* is not usable as a receive source.**
   It only caches the most recently received report. Many SET calls trigger a notification
   right after their answer — measured about 15 ms later — which overwrites the cache. A
   20 ms polling interval therefore loses the answer reproducibly, even though the write
   itself succeeded. On top of that, an answer byte-identical to the cached content would be
   indistinguishable from "no answer yet".

6. **CoreBluetooth is not a way in.** Once macOS claims the mouse as a HID input device it
   appears neither in `retrieveConnectedPeripherals` nor in advertisements — direct GATT
   access is ruled out (see `Sources/gattscan`).

7. **The MX Master 3S USB-C port is charge-only.** Nothing appears in the IORegistry when
   connected; the cable is not available as a transport.

8. **No on-device remapping.** `SetCidReporting` (feature `0x1B04` v5) has the layout
   `cid(2), flags(1), reserved(1), remap(2)`; the reserved byte must be 0 or the device
   answers `INVALID_ARGUMENT`. The flag bits work reliably (divert `0x01`/valid `0x02`,
   persist `0x04`/`0x08`, rawXY `0x10`/`0x20`), but the remap field is never applied —
   `GetCidReporting` keeps returning `0x0000`. Both byte layouts and every flag bit were
   tested. Button remapping as in Logi Options+ consequently does not happen on the device
   but through divert plus host software.

9. **Diverted buttons report press and release separately.** Notification format:
   `FF <featureIndex> 00 <cid_hi> <cid_lo>` on press, with CID `0x0000` on release.

10. **The setter for the device name is function 3, not 2.** On feature `0x0007`, function 2
    returns the *default* name — a write attempt against it is acknowledged without
    complaint and changes nothing. Function 3 writes and reports back how many characters
    were accepted, function 4 restores the factory name. Reading back after writing is what
    exposes such silent failures.

### Reentrancy: no run loop blocks for HID jobs

`HIDPPTransport.request` pumps the run loop while waiting for the device's answer. If jobs
are queued via `CFRunLoopPerformBlock`, that pump executes **the next waiting block inside
the running one**. The inner call clears the transport's receive buffer, so the outer call's
answer is lost — depending on the nesting either as a silently wrong result or as a hang.

This only surfaced once two reads were queued back to back (device info and status on
connect): the firmware arrived as `nil` while serial number and name from the same block
were read correctly. `HIDPPWorker` therefore keeps its own queue and takes jobs only at the
top level of its thread loop, outside any run loop call.

### Two device names — macOS shows the writable one, truncated

The mouse keeps two separate name fields:

* **`0x0005` DeviceNameType** — `MX Master 3S`, the model designation. Read-only: functions
  3 and up answer `INVALID_FUNCTION_ID`. It stays put no matter what.
* **`0x0007` DeviceFriendlyName** — freely writable, up to 18 characters, stored in the
  device. This is the field `mxctl name` and the settings window change.

**macOS displays the friendly name, not the model designation** — but only the first
**14 characters**, and only after the mouse reconnects. Measured on the device with the
friendly name set to `Ralles Master Maus`:

| Source | Value |
|---|---|
| `0x0005` DeviceNameType | `MX Master 3S` (unchanged) |
| `0x0007` DeviceFriendlyName | `Ralles Master Maus` (18 chars) |
| `kIOHIDProductKey` / Bluetooth settings | `Ralles Master ` (14 chars) |

The truncation happens on the way out to the host, not in the stored field — reading
`0x0007` back still yields all 18 characters.

This is why the transport picks its device by **product ID** (`0xB034` for the MX Master 3S),
not by product name: the name is writable, so a name-based filter stops matching the moment
the device is renamed. If no device with that product ID is present, any Logitech device
carrying a HID++ collection is accepted — the preference never becomes a requirement.

### Scroll resolution: 1 or 15, nothing in between

Feature `0x2121` has a resolution bit; in fine mode the wheel reports 15 steps per detent
instead of one (multiplier from `GetWheelCapability`). There are no intermediate steps:

* `0x2121` has functions 0–4, beyond that `INVALID_FUNCTION_ID`. A multiplier passed as the
  second byte of `SetWheelMode` is acknowledged, but the capability still reports 15.
* The **standard HID resolution multiplier** (generic desktop, usage `0x48`) that exists for
  exactly this purpose is absent from the device.
* The neighbouring, undocumented `0x2251` only offers read values.

In practice fine mode therefore does not feel like finer scrolling but like 15× faster
scrolling — macOS treats every step as a full impulse. The settings window does not offer
it; `mxctl scroll hires` remains for experiments.

A real intermediate step would only be possible by diverting the wheel to HID++ via the
`target` bit and generating the scroll events yourself. That requires the Accessibility
permission and leaves the wheel dead whenever the process is not running. Tools such as Mac
Mouse Fix take that route and can be run alongside: they operate on the events, this project
on the device configuration.

### Gestures: raw coordinates through the virtual control

Gestures have a mechanism of their own, measured on the device:

* The rawXY bit (`0x80` in `GetCidInfo`) is carried **exclusively** by `0x00D7` ("virtual
  gesture button"). No physical button has it — not even the thumb button `0x00C3`, which
  reports only `0x31`.
* When a control is set through `SetCidReporting` with flags `0x33` (divert `0x01` +
  dvalid `0x02` + rawXY `0x10` + rvalid `0x20`), the device stops reporting pointer movement
  while the button is held and **reports raw coordinates instead**. The pointer visibly
  stands still — exactly what gesture recognition needs.
* Notification format: `FF <featureIndex> 10 <X 16 bit> <Y 16 bit>`, signed and big-endian.
  Example: `FF 09 10 FF F8 00 01` = X −8, Y +1. The button press itself still arrives as
  `FF <featureIndex> 00 <cid>`.
* A 40-second test run produced 2308 such notifications.

Gesture control — for window management, say — would be feasible on this basis: accumulate
coordinates between press and release, determine the direction, trigger an action. It would
additionally require the Accessibility permission and would only work while the app runs.
Still open is whether `0x00D7` delivers its raw coordinates only while the thumb button is
held or also in combination with other buttons; only the thumb button was tested.

### The LED is the charging indicator

The green LED next to the thumb wheel blinks while charging and stays dark otherwise —
including when switching the Easy-Switch channel, for which the device has its own display.
Both verified on the device. It cannot be addressed over HID++: `0x18A1 LEDControl` is
flagged *engineering* in the feature list and answers every read with error `0x05`
(`LOGITECH_INTERNAL`). It would only become accessible after unlocking through
`0x1E00 EnableHiddenFeatures` — an interface meant for Logitech's production tests, whose
byte layouts would be pure guesswork here.

### Other Logitech mice

Feature discovery runs dynamically through `Root.GetFeature`, missing features are skipped,
and the button list comes from the device. If the name filter finds no "MX Master", the
transport falls back to any Logitech device with a HID++ collection. Other modern MX models
**on a direct Bluetooth connection** should therefore work unchanged.

Not supported:

* **Unifying/Bolt receivers.** The device index is hard-coded to `0xFF`, which only holds for
  direct connections; behind a receiver devices have index 1–6 and must be enumerated
  through the receiver first.
* **HID++ 1.0** (MX Revolution, Performance MX and similar). A different protocol without a
  root feature.

### What the MX Master 3S cannot do

The device's feature list (36 entries, obtained through feature `0x0001`) contains neither
`0x8060` (report rate) nor `0x8100` (on-board profiles) — this mouse simply does not have
them, unlike Logitech's gaming models. Nor is there an acceleration or curve setting; that
belongs to macOS. Most of the remaining features are flagged *hidden* or *engineering*
(firmware update, SPI direct access, LED control) and are irrelevant in daily use.

## MenuBarExtra in menu style

Three limitations this app had to work around — all of them specific to menu style, not to
`.menuBarExtraStyle(.window)`:

* The **label is not redrawn** when only its content changes. The battery level stayed
  invisible because of it; an `.id(...)` derived from the value forces the rebuild.
* **`SettingsLink` does not work.** The widely used detour through the undocumented
  `showSettingsWindow:` selector depends on the macOS version as well. Instead,
  `SettingsWindowController` keeps an `NSWindow` of its own.
* Only a **limited set of views** is rendered (Text, Button, Toggle, Menu, Divider) — more
  complex layouts do not appear.

## Layout

| Path | Purpose |
|---|---|
| `Sources/HIDPPKit/HIDPPTransport.swift` | IOKit transport (points 1–5 above) |
| `Sources/HIDPPKit/HIDPPDevice.swift` | Feature discovery via root feature `0x0000`, generic call |
| `Sources/HIDPPKit/Features/` | Battery `0x1004`, DPI `0x2201`, SmartShift `0x2110`, buttons `0x1B04` |
| `Sources/HIDPPKit/HIDPPWorker.swift` | HID access on its own thread so the GUI does not block |
| `Sources/LazyMouse/` | Menu bar app (SwiftUI) |
| `Sources/mxctl/` | CLI |
| `build-app.sh` | Builds and installs the app into `/Applications` |
| `Sources/hidraw/` | Diagnostic tool for the IOKit/HID++ layer |
| `Sources/gattscan/` | Diagnostic tool for the (failed) CoreBluetooth route |

## Status

Every command is verified against real hardware:

| Area | Verification |
|---|---|
| Feature discovery | Indices for `0x1004`, `0x2201`, `0x2110`, `0x1B04` resolved |
| Battery | 85 % read, status byte plausible (discharging) |
| DPI | Read and written: 1000 → 1600 → 1000 |
| SmartShift | Read and written: ratchet → freespin → ratchet |
| Button enumeration | 8 controls including groups and group masks |
| Divert | Diversion set, press/release notifications received, reset |
| `dpi-cycle` | Four button presses stepped 1000 → 1600 → 2400 → 1000 → 1600 |

Not possible: on-device remapping (see point 8 above) — the hardware does not support it.
Button actions therefore need a running process; `dpi-cycle` is the first implementation of
that pattern and can serve as a template for further actions.

## License

MIT — see [LICENSE](LICENSE).
