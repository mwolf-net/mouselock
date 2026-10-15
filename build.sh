#!/bin/sh
# Builds build/MouseLock.app using only the Command Line Tools (no Xcode project).
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
