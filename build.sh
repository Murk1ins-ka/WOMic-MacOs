#!/bin/bash
# ==============================================================================
# Сборка WO Mic для macOS 11+ (Universal: Intel + Apple Silicon)
#
# Использование:
#   ./build.sh          - собрать бинарник womic и WOMic.app
#   ./build.sh --dmg    - дополнительно собрать WOMic-macOS.dmg
#
# Минимальную версию macOS можно изменить: MACOS_MIN=12.0 ./build.sh
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

MACOS_MIN="${MACOS_MIN:-11.0}"
BUILD_DIR="$SCRIPT_DIR/.build"
APP="$SCRIPT_DIR/WOMic.app"
SOURCES=(
    src/AudioEngine.swift
    src/OpusDecoder.swift
    src/WOMicClient.swift
    src/DriverInstaller.swift
    src/MainWindowController.swift
    src/AppDelegate.swift
    src/main.swift
)

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

for ARCH in x86_64 arm64; do
    echo "==> Компиляция ($ARCH, macOS $MACOS_MIN+)..."
    swiftc -O -target "$ARCH-apple-macos$MACOS_MIN" \
        -framework Cocoa -framework AudioToolbox -framework CoreAudio \
        "${SOURCES[@]}" -o "$BUILD_DIR/womic-$ARCH"
done

lipo -create "$BUILD_DIR/womic-x86_64" "$BUILD_DIR/womic-arm64" -output "$SCRIPT_DIR/womic"
codesign -s - -f --entitlements entitlements.plist "$SCRIPT_DIR/womic"

echo "==> Сборка WOMic.app..."
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Driver"
cp "$SCRIPT_DIR/womic" "$APP/Contents/MacOS/WOMic"
rm -rf "$APP/Contents/Resources/Driver/VBCable.driver"
cp -R driver/VBCable.driver "$APP/Contents/Resources/Driver/"
CUR_MIN=$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "$APP/Contents/Info.plist" 2>/dev/null || true)
if [ "$CUR_MIN" != "$MACOS_MIN" ]; then
    plutil -replace LSMinimumSystemVersion -string "$MACOS_MIN" "$APP/Contents/Info.plist"
fi
codesign -s - -f --deep --entitlements entitlements.plist "$APP"
codesign --verify --deep "$APP"

if [ "${1:-}" == "--dmg" ]; then
    echo "==> Сборка WOMic-macOS.dmg..."
    STAGE="$BUILD_DIR/dmg"
    mkdir -p "$STAGE"
    cp -R "$APP" "$STAGE/"
    cp README.md "$STAGE/"
    ln -s /Applications "$STAGE/Applications"
    rm -f WOMic-macOS.dmg
    hdiutil create -volname "WO Mic" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov WOMic-macOS.dmg >/dev/null
fi

rm -rf "$BUILD_DIR"
echo "✅ Готово (минимальная версия macOS: $MACOS_MIN)"
