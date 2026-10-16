#!/bin/sh
# Prints the release notes for a version: its CHANGELOG.md section plus
# install instructions. Used by the Release workflow.
set -eu
cd "$(dirname "$0")/.."

VERSION=$1
SECTION=$(awk -v v="$VERSION" '
    /^## \[/ { if (found) exit; if (index($0, "## [" v "]") == 1) { found = 1; next } }
    /^\[[^]]*\]: / { next }   # link definitions at the end of the file
    found { print }
' CHANGELOG.md)

if [ -z "$SECTION" ]; then
    echo "No CHANGELOG.md section for version $VERSION" >&2
    exit 1
fi

cat <<NOTES
$SECTION

## Install

Download \`MouseLock-$VERSION.zip\`, unzip it and move \`MouseLock.app\` to
Applications.

MouseLock isn't notarized by Apple (that needs a paid developer account), so
macOS blocks it the first time: open it, click Done, then go to System
Settings -> Privacy & Security and click "Open Anyway". Or run:

    xattr -dr com.apple.quarantine /Applications/MouseLock.app

On first lock, allow MouseLock under Privacy & Security -> Accessibility.
NOTES
