#!/bin/bash
# Builds Lazy Mouse and installs it as an .app bundle.
#
# SwiftPM only produces a bare binary. A menu bar app needs a bundle: LSUIElement=true
# suppresses the dock icon, and only the bundle identity gives the app its own entry in
# Input Monitoring.
#
# The destination defaults to /Applications: macOS ties the granted permission to path and
# signature, so a changing path inside the project folder would invalidate it again and
# again. Pass a different destination as the first argument, e.g. ./build-app.sh ./build
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
DEST_DIR="${1:-/Applications}"
APP="$DEST_DIR/Lazy Mouse.app"
cd "$ROOT"

# Built for both architectures so the app also runs on Intel Macs. SwiftPM merges the slices
# into one binary itself; `lipo` is not needed.
ARCHS=(--arch arm64 --arch x86_64)
swift build --product LazyMouse -c release "${ARCHS[@]}"
BIN="$(swift build --product LazyMouse -c release "${ARCHS[@]}" --show-bin-path)/LazyMouse"

# A running older copy holds the bundle open and would be overwritten inconsistently.
pkill -f "Lazy Mouse.app/Contents/MacOS/LazyMouse" 2>/dev/null || true
sleep 1

# Only replace a bundle that really is this program.
if [ -e "$APP" ]; then
    EXISTING_ID="$(defaults read "$APP/Contents/Info" CFBundleIdentifier 2>/dev/null || echo "")"
    if [ "$EXISTING_ID" != "com.lazysoftware.lazymouse" ]; then
        echo "Aborting: '$APP' exists and does not belong to Lazy Mouse (identifier: '$EXISTING_ID')." >&2
        exit 1
    fi
    rm -rf "$APP"
fi

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/LazyMouse"
cp "$ROOT/Sources/LazyMouse/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# String files go straight into Contents/Resources rather than through SwiftPM resources:
# that way `Bundle.main` finds them, which SwiftUI and String(localized:) use by default. A
# SwiftPM resource bundle would sit in its own .bundle and would have to be addressed
# explicitly everywhere.
cp -R "$ROOT/Resources/"*.lproj "$APP/Contents/Resources/"

# Signing. With an own certificate the designated requirement reads
#   identifier "com.lazysoftware.lazymouse" and certificate root = H"..."
# and is therefore independent of the program hash — the granted Input Monitoring survives
# rebuilds. An ad-hoc signature binds to the cdhash instead, which changes with every build,
# so the permission would have to be granted again each time.
#
# The certificate is self-signed and does not have to be marked as trusted; codesign accepts
# it either way. Create it once (see the README):
#   openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem -days 7300 -nodes \
#     -subj "/CN=$SIGN_IDENTITY" -addext "basicConstraints=critical,CA:false" \
#     -addext "keyUsage=critical,digitalSignature" \
#     -addext "extendedKeyUsage=critical,codeSigning"
SIGN_IDENTITY="${SIGN_IDENTITY:-Lazy Mouse Local Signing}"

# Prefers a Developer ID issued by Apple: only with it does Gatekeeper accept the app on
# other machines. Otherwise the local certificate, otherwise ad hoc.
# The trailing `|| true` is required: without a Developer ID grep returns exit code 1, which
# under `set -e` with `pipefail` would end the whole script — leaving the app unsigned.
DEVELOPER_ID="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)"/\1/' || true)"

if [ -n "$DEVELOPER_ID" ]; then
    # --options runtime (hardened runtime) is a prerequisite for notarization, and so is
    # --timestamp: without a trusted timestamp Apple rejects the submission.
    codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" "$APP"
    echo "Signed with: $DEVELOPER_ID"

    # Notarization only on request: it needs a stored credential profile and uploads the app
    # to Apple. Create it once (the password is an app-specific password from
    # appleid.apple.com):
    #   xcrun notarytool store-credentials LazyMouse --apple-id YOUR-APPLE-ID \
    #     --team-id YOUR-TEAM-ID --password APP-SPECIFIC-PASSWORD
    if [ -n "${NOTARIZE_PROFILE:-}" ]; then
        ZIP="$(dirname "$APP")/LazyMouse-notarize.zip"
        ditto -c -k --keepParent "$APP" "$ZIP"
        xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARIZE_PROFILE" --wait
        # Staples the ticket to the app so it counts as notarized offline as well.
        xcrun stapler staple "$APP"
        rm -f "$ZIP"
        spctl -a -vvv -t install "$APP" || true
    else
        echo "Note: not notarized. To hand it to other Macs:" >&2
        echo "      NOTARIZE_PROFILE=<profile name> ./build-app.sh" >&2
    fi
elif security find-certificate -c "$SIGN_IDENTITY" >/dev/null 2>&1; then
    codesign --force --sign "$SIGN_IDENTITY" "$APP"
else
    echo "Note: certificate '$SIGN_IDENTITY' not found, signing ad hoc." >&2
    echo "      Input Monitoring then has to be granted again after every build." >&2
    codesign --force --sign - "$APP"
fi

echo "Installed: $APP"
echo "Start with: open '$APP'"
