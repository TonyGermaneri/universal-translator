#!/usr/bin/env bash
# Writes the body of a GitHub release to stdout.
#
#   scripts/release-notes.sh <tag> [previous-tag]
#
# SIGNING is what scripts/package-macos.sh recorded in dist/signing.txt (notarized, signed or ad-hoc), so the
# notes describe the build that was made, not the one the workflow meant to make.
set -euo pipefail
cd "$(dirname "$0")/.."

tag="${1:?usage: release-notes.sh <tag> [previous-tag]}"
prev="${2:-$(git describe --tags --abbrev=0 "$tag^" 2>/dev/null || true)}"
repo="${GITHUB_REPOSITORY:-TonyGermaneri/universal-translator}"
signing="${SIGNING:-ad-hoc}"

cat <<'EOF'
Universal Translator listens to your microphone or to audio playing on your Mac, and shows live captions
translated into your language over everything on screen. Speech recognition and translation run on your Mac.

## Install

Unzip, move **Universal Translator.app** to Applications, and open it. It lives in the menu bar; the first time
you start listening, macOS asks for permission to use the microphone, speech recognition, or system audio.

Needs a Mac with Apple silicon and macOS 26.4 or later.
EOF

case "$signing" in
    notarized)
        printf '\nSigned with a Developer ID and notarized by Apple, so it opens without a warning.\n' ;;
    signed)
        cat <<'EOF'

Signed with a Developer ID but **not notarized**, so macOS blocks it the first time: open it from Finder with
right-click ▸ Open, or clear the quarantine flag after unzipping:

```sh
xattr -dr com.apple.quarantine "/Applications/Universal Translator.app"
```
EOF
        ;;
    *)
        cat <<'EOF'

This build is **not signed with a Developer ID or notarized**, so macOS refuses to open it until the quarantine
flag is cleared. After unzipping and moving it to Applications:

```sh
xattr -dr com.apple.quarantine "/Applications/Universal Translator.app"
```

macOS also asks for the permissions again after each update, since an unsigned app has no stable identity.
EOF
        ;;
esac

cat <<EOF

The iPhone and iPad app isn't part of the release yet: build it from source with Xcode
([instructions](https://github.com/$repo#iphone-and-ipad)).
EOF

if [[ -n "$prev" ]]; then
    printf '\n## Changes since %s\n\n' "$prev"
    git log --no-merges --format='- %s' "$prev..$tag"
    printf '\n[Full diff](https://github.com/%s/compare/%s...%s)\n' "$repo" "$prev" "$tag"
else
    printf '\n## Changes\n\nFirst release.\n'
fi

if [[ -f dist/SHA256SUMS.txt ]]; then
    printf '\n## Checksum\n\n```\n'
    cat dist/SHA256SUMS.txt
    printf '```\n'
fi
