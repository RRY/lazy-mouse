#!/bin/bash
# Baut MXMenu und installiert es als .app-Bundle.
#
# SwiftPM erzeugt nur ein nacktes Binary. Für eine Menüleisten-App braucht es ein Bundle:
# LSUIElement=true unterdrückt das Dock-Symbol, und erst die Bundle-Identität gibt der App
# einen eigenen Eintrag in der Eingabeüberwachung.
#
# Ziel ist standardmäßig /Applications: macOS bindet die erteilte Berechtigung an Pfad und
# Signatur, ein wechselnder Pfad im Projektordner würde sie wiederholt ungültig machen.
# Abweichendes Ziel als erstes Argument, z. B.:  ./build-app.sh ./build
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
DEST_DIR="${1:-/Applications}"
APP="$DEST_DIR/MX Menu.app"
cd "$ROOT"

swift build --product MXMenu -c release
BIN="$(swift build --product MXMenu -c release --show-bin-path)/MXMenu"

# Läuft eine ältere Fassung, hält sie das Bundle offen und würde inkonsistent überschrieben.
pkill -f "MX Menu.app/Contents/MacOS/MXMenu" 2>/dev/null || true
sleep 1

# Nur ein Bundle ersetzen, das auch wirklich dieses Programm ist.
if [ -e "$APP" ]; then
    EXISTING_ID="$(defaults read "$APP/Contents/Info" CFBundleIdentifier 2>/dev/null || echo "")"
    if [ "$EXISTING_ID" != "de.ryback.mxmenu" ]; then
        echo "Abbruch: '$APP' existiert und gehört nicht zu MXMenu (Identifier: '$EXISTING_ID')." >&2
        exit 1
    fi
    rm -rf "$APP"
fi

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MXMenu"
cp "$ROOT/Sources/MXMenu/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Signieren. Mit eigenem Zertifikat lautet die Designated Requirement
#   identifier "de.ryback.mxmenu" and certificate root = H"..."
# also unabhängig vom Programm-Hash — die erteilte Eingabeüberwachung übersteht damit
# Neubauten. Eine Ad-hoc-Signatur bindet dagegen an den cdhash, der sich bei jedem Build
# ändert, sodass die Berechtigung jedes Mal neu erteilt werden müsste.
#
# Das Zertifikat ist selbstsigniert und muss nicht als vertrauenswürdig eingetragen sein;
# codesign akzeptiert es auch so. Anlegen (einmalig, siehe README):
#   openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem -days 7300 -nodes \
#     -subj "/CN=$SIGN_IDENTITY" -addext "basicConstraints=critical,CA:false" \
#     -addext "keyUsage=critical,digitalSignature" \
#     -addext "extendedKeyUsage=critical,codeSigning"
SIGN_IDENTITY="${SIGN_IDENTITY:-MX Menu Local Signing}"

# Bevorzugt eine von Apple ausgestellte Developer ID: nur damit akzeptiert Gatekeeper die
# App auch auf fremden Rechnern. Sonst das lokale Zertifikat, sonst ad hoc.
# Das abschließende `|| true` ist nötig: ohne Developer ID liefert grep Exitcode 1, was
# unter `set -e` mit `pipefail` das ganze Skript beenden würde — die App bliebe unsigniert.
DEVELOPER_ID="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)"/\1/' || true)"

if [ -n "$DEVELOPER_ID" ]; then
    # --options runtime (Hardened Runtime) ist Voraussetzung für die Notarisierung,
    # --timestamp ebenso: ohne beglaubigten Zeitstempel lehnt Apple die Einreichung ab.
    codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" "$APP"
    echo "Signiert mit: $DEVELOPER_ID"

    # Notarisierung nur auf Wunsch: sie braucht ein hinterlegtes Anmeldeprofil und
    # überträgt die App an Apple. Anlegen (einmalig, das Passwort ist ein
    # app-spezifisches Passwort von appleid.apple.com):
    #   xcrun notarytool store-credentials MXMenu --apple-id DEINE-APPLE-ID \
    #     --team-id DEINE-TEAM-ID --password APP-SPEZIFISCHES-PASSWORT
    if [ -n "${NOTARIZE_PROFILE:-}" ]; then
        ZIP="$(dirname "$APP")/MXMenu-notarize.zip"
        ditto -c -k --keepParent "$APP" "$ZIP"
        xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARIZE_PROFILE" --wait
        # Heftet das Ticket an die App, damit sie auch offline als beglaubigt gilt.
        xcrun stapler staple "$APP"
        rm -f "$ZIP"
        spctl -a -vvv -t install "$APP" || true
    else
        echo "Hinweis: nicht notarisiert. Für den Versand an andere Macs:" >&2
        echo "         NOTARIZE_PROFILE=<Profilname> ./build-app.sh" >&2
    fi
elif security find-certificate -c "$SIGN_IDENTITY" >/dev/null 2>&1; then
    codesign --force --sign "$SIGN_IDENTITY" "$APP"
else
    echo "Hinweis: Zertifikat '$SIGN_IDENTITY' nicht gefunden, signiere ad hoc." >&2
    echo "         Die Eingabeüberwachung muss dann nach jedem Build neu erteilt werden." >&2
    codesign --force --sign - "$APP"
fi

echo "Installiert: $APP"
echo "Starten mit: open '$APP'"
