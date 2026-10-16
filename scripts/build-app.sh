#!/bin/sh
# Builds build/MouseLock.app as a universal (Apple silicon + Intel) binary,
# using only the Command Line Tools: no Xcode project needed.
set -eu
cd "$(dirname "$0")/.."

APP=build/MouseLock.app
MIN_MACOS=13.0

for arch in arm64 x86_64; do
    swift build -c release --triple "$arch-apple-macosx$MIN_MACOS" \
        --scratch-path ".build/$arch"
done

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Support/Info.plist "$APP/Contents/Info.plist"
lipo -create -output "$APP/Contents/MacOS/MouseLock" \
    .build/arm64/release/MouseLock .build/x86_64/release/MouseLock

# Ad-hoc signature: no Apple developer account needed.
codesign --force --sign - "$APP"
echo "Built $APP"
