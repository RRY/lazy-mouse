#!/bin/bash
# Packs the installed app into a distributable disk image.
#
# A DMG rather than a PKG: the program is a single bundle, the login item registers itself
# through SMAppService, and nothing is placed outside /Applications. A PKG would additionally
# need its own "Developer ID Installer" certificate, whereas the disk image is signed with the
# same "Developer ID Application" identity as the app.
#
# The image carries a symlink to /Applications. That is not decoration: macOS ties the granted
# Input Monitoring to the app's path, so a copy left in ~/Downloads would lose the permission
# as soon as it is moved.
#
# Notarizing the image as well is worthwhile even though the app inside already carries its
# ticket — without it Gatekeeper warns when the image is opened, before the app is ever seen.
#   NOTARIZE_PROFILE=<profile name> ./make-dmg.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="${1:-/Applications/Lazy Mouse.app}"
OUT_DIR="$ROOT/dist"
VOL_NAME="Lazy Mouse"
cd "$ROOT"

if [ ! -d "$APP" ]; then
    echo "Not found: '$APP' — run ./build-app.sh first." >&2
    exit 1
fi

VERSION="$(defaults read "$APP/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "0.0")"
DMG="$OUT_DIR/LazyMouse-$VERSION.dmg"

# Refuse to ship a bundle that is not properly signed — the point of the image is distribution
# to other Macs, where an ad-hoc signature is rejected outright.
if ! codesign -v --strict "$APP" 2>/dev/null; then
    echo "Aborting: '$APP' has no valid signature." >&2
    exit 1
fi
# The output is captured first rather than piped into `grep -q`: grep exits at the first match,
# codesign dies of SIGPIPE, and under `pipefail` that turns the whole pipeline into a failure —
# reliably, so the check would always report a missing Developer ID.
APP_SIGNATURE="$(codesign -dv --verbose=2 "$APP" 2>&1)"
if ! grep -q "Authority=Developer ID Application" <<<"$APP_SIGNATURE"; then
    echo "Warning: the app is not signed with a Developer ID." >&2
    echo "         Other Macs will refuse to open it. Continuing anyway." >&2
fi

mkdir -p "$OUT_DIR"
rm -f "$DMG"

# Assemble in a staging directory: hdiutil takes the folder as it stands, so only what belongs
# in the image may be in it.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
# ditto rather than cp: it preserves extended attributes and the code signature.
ditto "$APP" "$STAGE/$(basename "$APP")"
ln -s /Applications "$STAGE/Applications"

# UDZO is the compressed read-only format that every macOS version mounts without extra tools.
hdiutil create -volname "$VOL_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
echo "Created: $DMG"

DEVELOPER_ID="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)"/\1/' || true)"

if [ -n "$DEVELOPER_ID" ]; then
    codesign --force --sign "$DEVELOPER_ID" "$DMG"
    echo "Signed with: $DEVELOPER_ID"

    if [ -n "${NOTARIZE_PROFILE:-}" ]; then
        # The image is submitted directly, no zip: notarytool accepts .dmg as it is.
        xcrun notarytool submit "$DMG" --keychain-profile "$NOTARIZE_PROFILE" --wait
        xcrun stapler staple "$DMG"
        spctl -a -vvv -t open --context context:primary-signature "$DMG" || true
    else
        echo "Note: image not notarized. Gatekeeper will warn when it is opened:" >&2
        echo "      NOTARIZE_PROFILE=<profile name> ./make-dmg.sh" >&2
    fi
else
    echo "Note: no Developer ID found, image left unsigned." >&2
fi

echo
echo "Size: $(du -h "$DMG" | cut -f1)"
echo "SHA-256: $(shasum -a 256 "$DMG" | cut -d' ' -f1)"
