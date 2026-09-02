#!/bin/bash
# Build the local macOS application launcher using swiftc.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="$ROOT/build"
APP="$BUILD/GridNest.app"
MIN_OS="26.0"
ARCHS="arm64"

echo "==> Cleaning"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> Writing Info.plist + resources"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
[ -f "$ROOT/Resources/AppIcon.icns" ] && cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
# Localizations (.lproj/Localizable.strings)
for lproj in "$ROOT"/Resources/*.lproj; do
    [ -d "$lproj" ] && cp -R "$lproj" "$APP/Contents/Resources/"
done

slices=()
for arch in $ARCHS; do
    out="$BUILD/GridNest-$arch"
    echo "==> Compiling $arch slice"
    if swiftc \
        -swift-version 5 \
        -target "${arch}-apple-macos${MIN_OS}" \
        -O \
        -framework AppKit \
        -framework SwiftUI \
        -framework ServiceManagement \
        -framework Carbon \
        -o "$out" \
        "$ROOT"/Sources/PositionLauncher/*.swift; then
        slices+=("$out")
    else
        echo "    (skipped $arch — SDK slice unavailable on this host)"
    fi
done

if [ "${#slices[@]}" -eq 0 ]; then
    echo "ERROR: no architecture could be compiled" >&2
    exit 1
fi

echo "==> Creating universal binary (${#slices[@]} slice(s))"
lipo -create -output "$APP/Contents/MacOS/GridNest" "${slices[@]}"
rm -f "${slices[@]}"
lipo -info "$APP/Contents/MacOS/GridNest"

# Sign with a real identity by exporting CODESIGN_IDENTITY, e.g.
#   CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./build.sh
# Otherwise an ad-hoc signature is used (fine for running locally).
SIGN_ID="${CODESIGN_IDENTITY:--}"
if [ "$SIGN_ID" = "-" ]; then
    echo "==> Ad-hoc signing"
    codesign --force --sign - "$APP"
else
    echo "==> Signing with: $SIGN_ID"
    codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$APP"
fi

echo "==> Done: $APP"
echo "    Run with: open \"$APP\""
