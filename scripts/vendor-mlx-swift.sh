#!/usr/bin/env bash
# Puts a copy of mlx-swift at .build/vendor/mlx-swift for toolchains older than Swift 6.3 (Xcode 26.3 and earlier,
# the newest Xcode that runs on macOS 15).
#
# mlx-swift 0.31.5 and later declare swift-tools-version 6.3 only for an experimental C-generation feature its
# Linux/CUDA build uses; the Apple build needs nothing from 6.3. The copy is the exact revision Package.resolved pins,
# with only that header line changed to 6.2. Package.swift points at it under `#if !compiler(>=6.3)`, which overrides
# the remote mlx-swift that mlx-swift-lm asks for. With Swift 6.3 or later this script isn't needed.
#
# Idempotent: re-running with the same pin does nothing; a changed pin re-fetches.
set -euo pipefail
cd "$(dirname "$0")/.."

DEST=".build/vendor/mlx-swift"
REV="$(/usr/bin/python3 -I -c '
import json, sys
pins = json.load(open("Package.resolved"))["pins"]
print(next(p["state"]["revision"] for p in pins if p["identity"] == "mlx-swift"))
')"

if [[ -f "$DEST/.vendored-rev" && "$(cat "$DEST/.vendored-rev")" == "$REV" ]]; then
    exit 0
fi

echo "Fetching mlx-swift $REV into $DEST (Swift < 6.3 toolchain)"
rm -rf "$DEST"
mkdir -p "$(dirname "$DEST")"
git clone --quiet --filter=blob:none https://github.com/ml-explore/mlx-swift "$DEST"
git -C "$DEST" -c advice.detachedHead=false checkout --quiet "$REV"
git -C "$DEST" submodule update --quiet --init --recursive
# The only change: the tools-version header. Everything after the first line is byte-for-byte upstream.
sed -i '' -E '1s|^// swift-tools-version: *6\.3[^[:space:]]*|// swift-tools-version: 6.2|' "$DEST/Package.swift"
head -1 "$DEST/Package.swift" | grep -q '^// swift-tools-version: 6.2$' || {
    echo "mlx-swift's Package.swift header isn't what this script expects; check $DEST/Package.swift" >&2
    exit 1
}
echo "$REV" > "$DEST/.vendored-rev"
