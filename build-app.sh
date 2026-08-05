#!/bin/bash
# Baut MXMenu und verpackt es als .app-Bundle.
#
# SwiftPM erzeugt nur ein nacktes Binary. Für eine Menüleisten-App braucht es ein Bundle:
# LSUIElement=true unterdrückt das Dock-Symbol, und erst die Bundle-Identität gibt der App
# einen stabilen Eintrag in der Eingabeüberwachung — ein loses Binary müsste dort nach
# jedem Neubau erneut freigegeben werden.
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

swift build --product MXMenu -c "$CONFIG"

BIN="$(swift build --product MXMenu -c "$CONFIG" --show-bin-path)/MXMenu"
APP="$ROOT/build/MX Menu.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MXMenu"
cp "$ROOT/Sources/MXMenu/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Ad-hoc-Signatur: ohne gültige Signatur verweigert macOS der App den HID-Zugriff.
codesign --force --sign - "$APP"

echo "Fertig: $APP"
echo "Starten mit: open '$APP'"
