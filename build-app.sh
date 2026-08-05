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

# Ad-hoc-Signatur: ohne gültige Signatur verweigert macOS den HID-Zugriff.
codesign --force --sign - "$APP"

echo "Installiert: $APP"
echo "Starten mit: open '$APP'"
