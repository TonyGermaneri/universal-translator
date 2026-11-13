#!/usr/bin/env bash
# Tier 1: the unit tests (`swift test`): TranslatorCore's logic and the Mac app's own decisions (engine choices with
# and without Apple's macOS 26 models, the Dock). Below Swift 6.3 it first puts the patched mlx-swift copy in place
# and keeps Package.resolved as committed (resolution with the copy drops mlx-swift's pin).
#
#   Tests/tier1/run.sh [swift test arguments]     e.g. --filter EngineChoiceTests
set -euo pipefail
cd "$(dirname "$0")/../.."

read -r major minor <<< "$(xcrun swift -version 2>&1 | sed -nE 's/.*Apple Swift version ([0-9]+)\.([0-9]+).*/\1 \2/p')"
if (( major < 6 || (major == 6 && minor < 3) )); then
    scripts/vendor-mlx-swift.sh
    backup="$(mktemp)"
    cp Package.resolved "$backup"
    trap 'cp "$backup" Package.resolved; rm -f "$backup"' EXIT
fi
swift test "$@"
