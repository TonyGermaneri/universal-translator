#!/usr/bin/env bash
# Builds "Universal Translator.app" into ./build and signs it.
#
#   scripts/build-app.sh            build only
#   scripts/build-app.sh --run      build and launch
#   scripts/build-app.sh --install  build, copy to /Applications, and launch
#
# Environment:
#   SIGN_IDENTITY     codesigning identity, or "-" for ad-hoc (default: first "Developer ID Application" or
#                     "Apple Development" identity in the keychain, else ad-hoc)
#   SECURE_TIMESTAMP  1 to timestamp the signature with Apple's server, which notarization requires (needs the
#                     network, so it's off for everyday builds)
#   VERSION           marketing version, e.g. 0.2.0 or v0.2.0 (default: the one in Resources/Info.plist)
#   OUT_DIR           where the app goes (default: build)
#   BUNDLE_ID         bundle identifier (default: com.germaneri.UniversalTranslator)
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Universal Translator"
BUNDLE_ID="${BUNDLE_ID:-com.germaneri.UniversalTranslator}"
OUT_DIR="${OUT_DIR:-build}"
APP="$OUT_DIR/$APP_NAME.app"

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
# ditto keeps the framework's Versions/Current symlinks.
ditto "$BIN_DIR/llama.framework" "$APP/Contents/Frameworks/llama.framework"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/UniversalTranslator"
# The packages' resource bundles (MLX's compiled shaders, FluidAudio's and swift-transformers' data files). Their
# Bundle.module looks in Contents/Resources and stops the app if a bundle isn't there, so every one is copied,
# including those only read on rare paths.
for bundle in "$BIN_DIR"/*.bundle; do
    ditto "$bundle" "$APP/Contents/Resources/$(basename "$bundle")"
done
# "v0.2.0-rc1" → "0.2.0": the marketing version is numbers and dots only.
SHORT_VERSION="${VERSION:-}"
SHORT_VERSION="${SHORT_VERSION#v}"
SHORT_VERSION="${SHORT_VERSION%%-*}"
SHORT_VERSION="${SHORT_VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)}"
if [[ ! "$SHORT_VERSION" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
    echo "VERSION must look like 1.2.3 or v1.2.3, not ${VERSION:-}" >&2
    exit 1
fi
sed -e "s/__BUNDLE_ID__/$BUNDLE_ID/" -e "s/__BUILD_NUMBER__/$(date +%Y%m%d%H%M)/" \
    Resources/Info.plist > "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $SHORT_VERSION" "$APP/Contents/Info.plist"
if [[ ! -f Resources/AppIcon.icns ]]; then
    swift scripts/make-icon.swift Resources/AppIcon.icns
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

IDENTITY="${SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
    IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | grep -E '"(Developer ID Application|Apple Development):' | head -1 | sed -E 's/.*"(.*)"/\1/' || true)"
fi
TIMESTAMP=--timestamp=none
[[ "${SECURE_TIMESTAMP:-}" == 1 ]] && TIMESTAMP=--timestamp
if [[ -n "$IDENTITY" && "$IDENTITY" != "-" ]]; then
    echo "Signing with: $IDENTITY"
    # Inside out: the framework first, then the app, whose signature seals it.
    codesign --force --options runtime "$TIMESTAMP" --sign "$IDENTITY" "$APP/Contents/Frameworks/llama.framework"
    codesign --force --options runtime "$TIMESTAMP" \
        --entitlements Resources/UniversalTranslator.entitlements --sign "$IDENTITY" "$APP"
else
    echo "No signing identity found; signing ad-hoc (macOS will re-ask for permissions after each rebuild)."
    codesign --force --sign - "$APP/Contents/Frameworks/llama.framework"
    codesign --force --sign - --entitlements Resources/UniversalTranslator.entitlements "$APP"
fi
codesign --verify --deep --strict "$APP"
echo "Built $APP ($SHORT_VERSION)"

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
