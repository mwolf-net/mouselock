#!/bin/sh
# Builds build/MouseLock.app using only the Command Line Tools (no Xcode project).
# With --install, also installs it to /Applications and (re)starts it.
set -eu
cd "$(dirname "$0")"

APP=build/MouseLock.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"
swiftc -O -swift-version 5 -o "$APP/Contents/MacOS/MouseLock" Sources/main.swift
# Ad-hoc signature: no Apple developer account needed.
codesign --force --sign - "$APP"
echo "Built $APP"

# ./build.sh --install: replace /Applications/MouseLock.app and restart it.
if [ "${1:-}" = "--install" ]; then
    pkill -x MouseLock || true
    sleep 0.5
    rm -rf /Applications/MouseLock.app
    cp -R "$APP" /Applications/
    open /Applications/MouseLock.app
    echo "Installed and started /Applications/MouseLock.app"
fi
