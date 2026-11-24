#!/bin/bash
# Builds MacAwake.app into ./build. Needs Xcode or the Command Line Tools (xcode-select --install).
#
# Optional settings (environment variables):
#   VERSION=1.2.3          Version shown in Finder/About (CFBundleShortVersionString). Default: VERSION file + "-dev".
#   BUILD_NUMBER=42        CFBundleVersion. Default: 1.
#   UNIVERSAL=1            Build for Apple silicon and Intel and merge them with lipo. Default: this Mac's arch only.
#   SIGN_IDENTITY="Developer ID Application: …"
#                          Sign with hardened runtime + entitlements (needed for notarization).
#                          Default "-" = ad-hoc signature, fine for running on your own Mac.
#   ZIP=1                  Also write build/MacAwake.zip, ready to upload.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="MacAwake"
APP_DIR="build/${APP_NAME}.app"
VERSION="${VERSION:-$(tr -d '[:space:]' < VERSION)-dev}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

if [[ "${UNIVERSAL:-0}" == "1" ]]; then
    bins=()
    for arch in arm64 x86_64; do
        # Separate scratch folders, so one arch's output can't overwrite the other's.
        swift build -c release --arch "$arch" --scratch-path ".build/$arch"
        bins+=("$(swift build -c release --arch "$arch" --scratch-path ".build/$arch" --show-bin-path)/${APP_NAME}")
    done
    BIN_PATH="build/${APP_NAME}-universal"
    mkdir -p build
    lipo -create "${bins[@]}" -output "$BIN_PATH"
else
    swift build -c release
    BIN_PATH="$(swift build -c release --show-bin-path)/${APP_NAME}"
fi

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/${APP_NAME}"
cp Info.plist "$APP_DIR/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP_DIR/Contents/Resources/AppIcon.icns"
cp Helper/wake-helper.sh "$APP_DIR/Contents/Resources/wake-helper.sh"
cp Helper/lid-helper.sh "$APP_DIR/Contents/Resources/lid-helper.sh"

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD_NUMBER}" "$APP_DIR/Contents/Info.plist"

if [[ "$SIGN_IDENTITY" == "-" ]]; then
    # Ad-hoc signature so macOS shows the calendar permission prompt.
    codesign --force --sign - "$APP_DIR"
else
    codesign --force --timestamp --options runtime \
        --entitlements MacAwake.entitlements \
        --sign "$SIGN_IDENTITY" "$APP_DIR"
fi
codesign --verify --strict "$APP_DIR"

if [[ "${ZIP:-0}" == "1" ]]; then
    rm -f "build/${APP_NAME}.zip"
    ditto -c -k --keepParent "$APP_DIR" "build/${APP_NAME}.zip"
    echo "Zipped build/${APP_NAME}.zip"
fi

echo "Built $APP_DIR (version ${VERSION}, build ${BUILD_NUMBER}, $(lipo -archs "$APP_DIR/Contents/MacOS/${APP_NAME}"))"
echo "Install:  rm -rf /Applications/${APP_NAME}.app && cp -R \"$APP_DIR\" /Applications/ && open /Applications/${APP_NAME}.app"
