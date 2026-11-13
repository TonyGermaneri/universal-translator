#!/usr/bin/env bash
# Tier 2: build and environment health. What a build must have to run on macOS 15, and what this Mac must have for
# the app to work, the kind of thing no unit test sees. scripts/build-app.sh runs it on
# every build.
#
#   Tests/tier2/check.sh [app]              default: build/Universal Translator.app
#   Tests/tier2/check.sh --network [app]    also check that the app's model downloads can reach Hugging Face
#
# Exits 1 if any check fails. Skips say why.
# shellcheck disable=SC2015  # `test && pass || fail`: pass always succeeds, so fail runs only when the test fails
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1

network=0
if [[ "${1:-}" == "--network" ]]; then network=1; shift; fi
app="${1:-build/Universal Translator.app}"
bin="$app/Contents/MacOS/UniversalTranslator"
failures=0

pass() { echo "  pass  $1"; }
fail() { echo "  FAIL  $1"; failures=$((failures + 1)); }
skip() { echo "  skip  $1"; }

echo "tier2: $(sw_vers -productName) $(sw_vers -productVersion), $(xcrun swift -version 2>&1 | head -1 | sed -E 's/.*(Apple Swift version [0-9.]+).*/\1/')"

# --- source floors: macOS 15 for the Mac app, iOS 26.4
grep -q 'platforms: \[.macOS(.v15), .iOS("26.4")\]' Package.swift \
    && pass "Package.swift floors: macOS 15, iOS 26.4" || fail "Package.swift floors aren't .macOS(.v15), .iOS(\"26.4\")"
v="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Resources/Info.plist 2>/dev/null)"
[[ "$v" == "15.0" ]] && pass "Resources/Info.plist LSMinimumSystemVersion 15.0" \
    || fail "Resources/Info.plist LSMinimumSystemVersion is '$v', not 15.0"

# --- Package.resolved: the checked-in pins, untouched by a Swift < 6.3 resolution (which drops mlx-swift's pin)
if grep -q '"identity" : "mlx-swift"' Package.resolved; then pass "Package.resolved pins mlx-swift"
else fail "Package.resolved lost its mlx-swift pin (a Swift < 6.3 resolution dropped it): git checkout Package.resolved"; fi
if git rev-parse --git-dir >/dev/null 2>&1; then
    git diff --quiet HEAD -- Package.resolved && pass "Package.resolved matches the commit" \
        || fail "Package.resolved differs from the commit (originHash or pins rewritten): git checkout Package.resolved"
fi

# --- toolchain: below Swift 6.3, the patched mlx-swift copy stands in for the published one (scripts/vendor-mlx-swift.sh)
read -r major minor <<< "$(xcrun swift -version 2>&1 | sed -nE 's/.*Apple Swift version ([0-9]+)\.([0-9]+).*/\1 \2/p')"
if (( major < 6 || (major == 6 && minor < 3) )); then
    vendor=.build/vendor/mlx-swift
    pin="$(/usr/bin/python3 -I -c 'import json; print(next(p["state"]["revision"] for p in json.load(open("Package.resolved"))["pins"] if p["identity"] == "mlx-swift"))' 2>/dev/null)"
    if [[ -f "$vendor/Package.swift" && "$(head -1 "$vendor/Package.swift")" == "// swift-tools-version: 6.2" \
          && "$(cat "$vendor/.vendored-rev" 2>/dev/null)" == "$pin" ]]; then
        pass "vendored mlx-swift at the pinned revision, tools-version 6.2"
    else
        fail "vendored mlx-swift missing, stale or unpatched: run scripts/vendor-mlx-swift.sh"
    fi
    if [[ -n "$pin" ]] && git -C "$vendor" diff --quiet "$pin" -- . ':!Package.swift' 2>/dev/null; then
        pass "vendored mlx-swift differs from upstream only in Package.swift"
    else
        fail "vendored mlx-swift has changes beyond its Package.swift header"
    fi
else
    skip "vendored mlx-swift (Swift $major.$minor reads mlx-swift's own manifest)"
fi

# --- the built app
if [[ ! -x "$bin" ]]; then
    fail "no app at $app (build it: scripts/build-app.sh)"
else
    v="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$app/Contents/Info.plist" 2>/dev/null)"
    [[ "$v" == "15.0" ]] && pass "app Info.plist LSMinimumSystemVersion 15.0" || fail "app Info.plist LSMinimumSystemVersion is '$v'"
    minos="$(vtool -show-build "$bin" 2>/dev/null | awk '/minos/ {print $2; exit}')"
    [[ "$minos" == "15.0" ]] && pass "binary deployment target 15.0" || fail "binary deployment target is '$minos', not 15.0"

    # FoundationModels doesn't exist before macOS 26: a strong link stops the app at launch on 15.
    fm="$(otool -L "$bin" | grep FoundationModels.framework || true)"
    if [[ -z "$fm" ]]; then pass "FoundationModels not linked"
    elif [[ "$fm" == *weak* ]]; then pass "FoundationModels weak-linked"
    else fail "FoundationModels is strongly linked (a macOS 26 API is used without @available)"; fi

    # Every strongly linked system framework must exist here (meaningful on the oldest supported macOS).
    missing=""
    while read -r lib; do
        dir="${lib%%.framework/*}.framework"
        [[ -d "$dir" ]] || missing+=" $(basename "$dir")"
    done < <(otool -L "$bin" | tail -n +2 | grep -v '(.*weak)' | awk '{print $1}' | grep -E '^/System/Library/(Private)?Frameworks/')
    [[ -z "$missing" ]] && pass "every strongly linked system framework exists on this macOS" \
        || fail "strongly linked frameworks missing on this macOS:$missing"

    llama="$app/Contents/Frameworks/llama.framework/llama"
    lminos="$(vtool -show-build "$llama" 2>/dev/null | awk '/minos/ {print $2; exit}')"
    if [[ -z "$lminos" ]]; then fail "llama.framework missing from the app"
    elif [[ "$(printf '%s\n15.0\n' "$lminos" | sort -V | tail -1)" == "15.0" ]]; then pass "llama.framework deployment target $lminos"
    else fail "llama.framework needs macOS $lminos"; fi

    # MLX's shaders: only xcodebuild compiles them (with the Metal toolchain); without them MLX stops at load.
    if find "$app/Contents/Resources" -path '*Cmlx*.bundle*' -name default.metallib 2>/dev/null | grep -q .; then
        pass "MLX Metal shaders bundled"
    else
        fail "MLX's default.metallib isn't in the app (build with xcodebuild and the Metal toolchain)"
    fi

    codesign --verify --deep --strict "$app" 2>/dev/null && pass "signature valid" || fail "signature invalid"

    # The build's identity, shown in Settings → Permissions & About and naming the release zip (2026-10-27: every
    # build said only "0.1.0", so nobody could tell which one was installed).
    stamp="$(/usr/libexec/PlistBuddy -c 'Print :UTBuildDescription' "$app/Contents/Info.plist" 2>/dev/null)"
    want="${BUILD_DESCRIBE:-$(git describe --tags --always --dirty 2>/dev/null)}"
    if [[ -z "$stamp" ]]; then fail "the app has no build identity (UTBuildDescription)"
    elif [[ "$stamp" == "$want" ]]; then pass "build identity $stamp"
    else fail "the app says it's build $stamp, but this is $want"; fi
fi

# --- network: the app downloads models with URLSession, which trusts only the keychain's roots. A TLS-inspecting
# proxy without its root installed (seen with Hugging Face's CDN, 2026-10) breaks every download.
if (( network )); then
    url="https://huggingface.co/FluidInference/silero-vad-coreml/resolve/b419383c55c110e2c9271fa6ee0ea83d03c70d96/silero-vad-unified-v6.0.0.mlmodelc/weights/weight.bin"
    # nscurl (URLSession, like the app) exits 0 even when the load fails, so judge by its output and the file.
    out="$(mktemp)"
    said="$(nscurl -o "$out" "$url" 2>&1)"
    got="$(stat -f %z "$out" 2>/dev/null || echo 0)"
    rm -f "$out"
    if (( got > 0 )) && [[ "$said" != *"Load failed"* ]]; then
        pass "Hugging Face model downloads reachable with the system's trust (URLSession, $got bytes)"
    else
        fail "Hugging Face's CDN isn't trusted from this Mac: a TLS-inspecting proxy without its root certificate in the keychain. In-app downloads will fail; install the proxy's root CA or bypass *.hf.co"
    fi
else
    skip "network (pass --network)"
fi

echo "tier2: $failures failed"
exit $(( failures > 0 ))
