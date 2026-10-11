#!/usr/bin/env bash
# Builds "Universal Translator.app" into ./build and signs it.
#
#   scripts/build-app.sh            build only
#   scripts/build-app.sh --run      build and launch
#   scripts/build-app.sh --install  build, copy to /Applications, and launch
#
# Environment:
#   SIGN_IDENTITY  codesigning identity (default: first "Developer ID Application" or
#                  "Apple Development" identity in the keychain, else ad-hoc)
#   BUNDLE_ID      bundle identifier (default: com.germaneri.UniversalTranslator)
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Universal Translator"
BUNDLE_ID="${BUNDLE_ID:-com.germaneri.UniversalTranslator}"
APP="build/$APP_NAME.app"

# xcodebuild rather than `swift build`: only xcodebuild compiles MLX's Metal shaders. (On a fresh Xcode, run
# `sudo xcodebuild -runFirstLaunch` and `xcodebuild -downloadComponent MetalToolchain` once.)
DERIVED=".build/xcode"
xcodebuild build -scheme UniversalTranslator -configuration Release -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$DERIVED" -skipMacroValidation -skipPackagePluginValidation -quiet
BIN_DIR="$DERIVED/Build/Products/Release"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN_DIR/UniversalTranslator" "$APP/Contents/MacOS/UniversalTranslator"
# llama.cpp (on-device translation models) is a dynamic framework; embed it and point the binary at it.
cp -R "$BIN_DIR/llama.framework" "$APP/Contents/Frameworks/"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/UniversalTranslator"
# MLX's compiled shaders (default.metallib); MLX looks for this bundle in Contents/Resources.
cp -R "$BIN_DIR/mlx-swift_Cmlx.bundle" "$APP/Contents/Resources/"
sed -e "s/__BUNDLE_ID__/$BUNDLE_ID/" -e "s/__BUILD_NUMBER__/$(date +%Y%m%d%H%M)/" \
    Resources/Info.plist > "$APP/Contents/Info.plist"
if [[ ! -f Resources/AppIcon.icns ]]; then
    swift scripts/make-icon.swift Resources/AppIcon.icns
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

IDENTITY="${SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
    IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | grep -E '"(Developer ID Application|Apple Development):' | head -1 | sed -E 's/.*"(.*)"/\1/' || true)"
fi
if [[ -n "$IDENTITY" ]]; then
    echo "Signing with: $IDENTITY"
    codesign --force --options runtime --timestamp=none --sign "$IDENTITY" "$APP/Contents/Frameworks/llama.framework"
    codesign --force --options runtime --timestamp=none \
        --entitlements Resources/UniversalTranslator.entitlements --sign "$IDENTITY" "$APP"
else
    echo "No signing identity found; signing ad-hoc (macOS will re-ask for permissions after each rebuild)."
    codesign --force --sign - "$APP/Contents/Frameworks/llama.framework"
    codesign --force --sign - --entitlements Resources/UniversalTranslator.entitlements "$APP"
fi
codesign --verify --strict "$APP"
echo "Built $APP"

case "${1:-}" in
    --run)
        pkill -x UniversalTranslator 2>/dev/null || true
        open "$APP"
        ;;
    --install)
        pkill -x UniversalTranslator 2>/dev/null || true
        rm -rf "/Applications/$APP_NAME.app"
        cp -R "$APP" /Applications/
        open "/Applications/$APP_NAME.app"
        ;;
esac
