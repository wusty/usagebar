#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="UsageBar"
APP_BUNDLE="$APP_NAME.app"
BIN_DIR=".build"
BIN_PATH="$BIN_DIR/$APP_NAME"

echo "Compiling $APP_NAME (release)…"
mkdir -p "$BIN_DIR"

# Compile all Swift sources in one invocation. Avoids SwiftPM because the
# Command Line Tools install on this machine has a broken PackageDescription
# linker setup (the SPM manifest fails with "Undefined symbols"). swiftc handles
# multi-file builds fine on its own.
xcrun swiftc \
    -O \
    -target arm64-apple-macos14.0 \
    -framework AppKit \
    -framework WebKit \
    Sources/UsageBar/main.swift \
    Sources/UsageBar/AppDelegate.swift \
    Sources/UsageBar/UsageParser.swift \
    Sources/UsageBar/UsageScraper.swift \
    Sources/UsageBarLogic/ThresholdEvaluator.swift \
    -o "$BIN_PATH"

echo "Assembling ${APP_BUNDLE}…"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BIN_PATH" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "Resources/gauge.svg" "$APP_BUNDLE/Contents/Resources/gauge.svg"

# Ad-hoc sign so WebKit's persistent data store (which expects a stable app
# identity) reliably persists cookies across launches.
codesign --force --deep --sign - "$APP_BUNDLE" >/dev/null

echo "Done: $APP_BUNDLE"
