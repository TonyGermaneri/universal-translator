#!/usr/bin/env bash
# Builds the Mac app for release: signed with a Developer ID, notarized by Apple, stapled, and zipped into dist/.
# The release workflow runs this, and so can you, to get the same zip before pushing a tag.
#
#   scripts/package-macos.sh [version]      e.g. v0.2.0 (default: git describe)
#
# Signing and notarizing depend on what's available, so the same script works on a laptop and on a runner:
#
#   SIGN_IDENTITY     codesign identity, or "-" for ad-hoc (default: the one "Developer ID Application" identity
#                     in the keychain, else ad-hoc)
#   NOTARIZE          auto (default) | required | off. A release uses "required", so a missing credential stops
#                     the build instead of shipping an app the release notes call notarized.
#   NOTARY_KEY_ID, NOTARY_ISSUER_ID
#                     the App Store Connect API key's ID and issuer, with the key itself as either
#   NOTARY_KEY_PATH   the AuthKey_XXXXXXXXXX.p8 file, or
#   NOTARY_KEY_P8     its contents (the PEM text, or base64 of the file)
#
# Leaves dist/Universal-Translator-<version>-macOS.zip, dist/SHA256SUMS.txt, and dist/signing.txt ("notarized",
# "signed" or "ad-hoc"), which the release notes read so they describe the build that was actually made.
set -euo pipefail
cd "$(dirname "$0")/.."

version="${1:-$(git describe --tags --always --dirty 2>/dev/null || echo dev)}"
notarize="${NOTARIZE:-auto}"
dist=dist
app="$dist/Universal Translator.app"
zip="$dist/Universal-Translator-$version-macOS.zip"

echo "==> Universal Translator $version"

# ------------------------------------------------------------------------------------------- signing identity

identity="${SIGN_IDENTITY:-}"
if [[ -z "$identity" ]]; then
    # Only a Developer ID can be notarized and opened on other Macs; an Apple Development identity can't.
    found="$(security find-identity -v -p codesigning 2>/dev/null \
        | grep 'Developer ID Application' | sed -E 's/^.*"(.*)".*$/\1/' || true)"
    case "$(printf '%s' "$found" | grep -c . || true)" in
        0) identity="-" ;;
        1) identity="$found" ;;
        *) echo "More than one Developer ID Application identity; set SIGN_IDENTITY to one of:" >&2
           printf '  %s\n' "$found" >&2
           exit 1 ;;
    esac
fi

# --------------------------------------------------------------------------------------- notary credentials

key_dir=""
trap 'if [[ -n "$key_dir" ]]; then rm -rf "$key_dir"; fi' EXIT
key="${NOTARY_KEY_PATH:-}"
if [[ -z "$key" && -n "${NOTARY_KEY_P8:-}" ]]; then
    key_dir="$(mktemp -d)"
    key="$key_dir/AuthKey.p8"
    (
        umask 077
        # A .p8 is PEM text, so the secret may hold it as is, or base64 of the file like the .p12 beside it.
        if printf '%s' "$NOTARY_KEY_P8" | grep -q 'BEGIN PRIVATE KEY'; then
            printf '%s\n' "$NOTARY_KEY_P8" > "$key"
        else
            printf '%s' "$NOTARY_KEY_P8" | base64 --decode > "$key" 2>/dev/null || true
        fi
    )
    grep -q 'BEGIN PRIVATE KEY' "$key" || {
        echo "NOTARY_KEY_P8 is neither an App Store Connect key nor base64 of one" >&2
        exit 1
    }
fi
have_key=0
[[ -n "$key" && -r "$key" && -n "${NOTARY_KEY_ID:-}" && -n "${NOTARY_ISSUER_ID:-}" ]] && have_key=1

case "$notarize" in
    required)
        [[ "$identity" != "-" ]] || { echo "Notarization is required, but there's no Developer ID identity" >&2; exit 1; }
        [[ "$have_key" == 1 ]] || { echo "Notarization is required, but there's no App Store Connect API key" >&2; exit 1; }
        do_notarize=1 ;;
    off) do_notarize=0 ;;
    auto) [[ "$identity" != "-" && "$have_key" == 1 ]] && do_notarize=1 || do_notarize=0 ;;
    *) echo "NOTARIZE must be auto, required or off" >&2; exit 1 ;;
esac

if [[ "$identity" == "-" ]]; then
    echo "    signing ad-hoc (no Developer ID identity)"
else
    echo "    signing as $identity"
fi
[[ "$do_notarize" == 1 ]] && echo "    notarizing" || echo "    not notarizing"

# ------------------------------------------------------------------------------------------------ build

rm -rf "$app" "$dist"/Universal-Translator-*-macOS.zip "$dist/SHA256SUMS.txt" "$dist/signing.txt"
mkdir -p "$dist"

# A version from a tag goes into the app; anything else (a commit, "dev") keeps the one in Info.plist.
plist_version=""
[[ "$version" =~ ^v?[0-9]+(\.[0-9]+){0,2}(-.*)?$ ]] && plist_version="$version"
OUT_DIR="$dist" SIGN_IDENTITY="$identity" VERSION="$plist_version" \
    SECURE_TIMESTAMP="$([[ "$identity" == "-" ]] && echo 0 || echo 1)" scripts/build-app.sh

echo "    $(lipo -archs "$app/Contents/MacOS/UniversalTranslator"), version" \
    "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")" \
    "($(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist"))"

# ditto, not zip: it keeps the framework's symlinks and the extended attributes a signed bundle relies on.
ditto -c -k --sequesterRsrc --keepParent "$app" "$zip"

# ---------------------------------------------------------------------------------------- notarize, staple

if [[ "$do_notarize" == 1 ]]; then
    nt() { xcrun notarytool "$@" --key "$key" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID"; }
    json() { python3 -c 'import json, sys; print(json.load(sys.stdin)[sys.argv[1]])' "$1"; }

    echo "==> Submitting to Apple"
    id="$(nt submit "$zip" --output-format json | json id)"
    echo "    submission $id"
    status="$(nt wait "$id" --timeout 30m --output-format json | json status)"
    echo "    $status"
    if [[ "$status" != "Accepted" ]]; then
        # The log is the only place that says which file was rejected and why.
        nt log "$id" || true
        exit 1
    fi

    # The ticket goes on the app, so Gatekeeper can check it with no network; then the zip is made again,
    # because the one that was submitted predates the ticket.
    echo "==> Stapling"
    xcrun stapler staple "$app"
    xcrun stapler validate "$app"
    rm -f "$zip"
    ditto -c -k --sequesterRsrc --keepParent "$app" "$zip"
fi

echo "==> Gatekeeper"
spctl --assess --type execute --verbose=2 "$app" 2>&1 | sed 's/^/    /' || true

if [[ "$do_notarize" == 1 ]]; then echo notarized
elif [[ "$identity" != "-" ]]; then echo signed
else echo ad-hoc
fi > "$dist/signing.txt"

(cd "$dist" && shasum -a 256 "$(basename "$zip")" > SHA256SUMS.txt)
echo "==> $zip ($(du -h "$zip" | cut -f1), $(cat "$dist/signing.txt"))"
