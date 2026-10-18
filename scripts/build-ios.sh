#!/usr/bin/env bash
# Builds the iPhone/iPad app (iOS/UniversalTranslator.xcodeproj).
#
#   scripts/build-ios.sh            build for a connected device (or, with none, check that it compiles)
#   scripts/build-ios.sh --run      build, install on the connected iPhone or iPad, and launch
#
# Signing is automatic with the team set in the project: add your Apple ID in Xcode → Settings → Accounts
# once, and Xcode creates the development certificate and provisioning profile. The device needs Developer
# Mode on (Settings → Privacy & Security → Developer Mode).
#
# Environment:
#   DEVICE  UDID of the device to use (default: the first paired iPhone or iPad that's connected)
set -euo pipefail
cd "$(dirname "$0")/.."

PROJECT="iOS/UniversalTranslator.xcodeproj"
BUNDLE_ID="com.germaneri.UniversalTranslator"
# Reuses the Mac build's package checkouts.
FLAGS=(-project "$PROJECT" -scheme UniversalTranslator -configuration Release -derivedDataPath .build/ios
       -clonedSourcePackagesDirPath .build/xcode/SourcePackages -skipMacroValidation -skipPackagePluginValidation)

DEVICE="${DEVICE:-}"
if [[ -z "$DEVICE" ]]; then
    JSON="$(mktemp)"
    xcrun devicectl list devices --json-output "$JSON" >/dev/null 2>&1 || true
    DEVICE="$(python3 -c '
import json, sys
try:
    devices = json.load(open(sys.argv[1]))["result"]["devices"]
except Exception:
    devices = []
for d in devices:
    if d["hardwareProperties"].get("platform") == "iOS" and d["connectionProperties"].get("tunnelState") != "unavailable":
        print(d["hardwareProperties"]["udid"])
        break
' "$JSON")"
    rm -f "$JSON"
fi

if [[ -z "$DEVICE" ]]; then
    if [[ "${1:-}" == "--run" ]]; then
        echo "No iPhone or iPad is connected. Connect one (USB, or the same Wi-Fi once paired) and try again." >&2
        exit 1
    fi
    echo "No device connected: checking that the app compiles (unsigned)."
    xcodebuild build "${FLAGS[@]}" -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO -quiet
    echo "Build succeeded."
    exit 0
fi

echo "Building for device $DEVICE"
# Registers the device with the team the first time, as Xcode's Run button does.
xcodebuild build "${FLAGS[@]}" -destination "id=$DEVICE" -allowProvisioningUpdates -allowProvisioningDeviceRegistration -quiet
APP=".build/ios/Build/Products/Release-iphoneos/Universal Translator.app"
echo "Built $APP"

if [[ "${1:-}" == "--run" ]]; then
    xcrun devicectl device install app --device "$DEVICE" "$APP"
    xcrun devicectl device process launch --device "$DEVICE" --terminate-existing "$BUNDLE_ID"
fi
