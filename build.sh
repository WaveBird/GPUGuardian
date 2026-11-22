#!/bin/bash
# GPU Guardian — one-shot build script
#
# Compiles the C/IOKit bridge and Swift sources with the macOS toolchain,
# assembles GPUGuardian.app, and ad-hoc signs it. No Xcode project required.
#
# Usage:  ./build.sh
# Output: ./GPUGuardian.app  (see README.md for details)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$ROOT_DIR/build"
APP_BUNDLE="$ROOT_DIR/GPUGuardian.app"
MACOS_DIR="$APP_BUNDLE/Contents/MacOS"
RESOURCES_DIR="$APP_BUNDLE/Contents/Resources"

rm -rf "$BUILD_DIR" "$APP_BUNDLE"
mkdir -p "$BUILD_DIR" "$MACOS_DIR" "$RESOURCES_DIR"

echo "Compiling GPUMux.c..."
clang -c -O2 -Wall -Wextra \
    -mmacosx-version-min=10.15 \
    -o "$BUILD_DIR/GPUMux.o" \
    "$ROOT_DIR/Sources/GPUMux.c"

echo "Compiling Swift sources..."
swiftc -O \
    -target x86_64-apple-macosx10.15 \
    -import-objc-header "$ROOT_DIR/Sources/GPUGuardian-Bridging-Header.h" \
    -framework Cocoa \
    -framework IOKit \
    -framework CoreFoundation \
    "$BUILD_DIR/GPUMux.o" \
    "$ROOT_DIR/Sources/GPUProcessMonitor.swift" \
    "$ROOT_DIR/Sources/MainPanelController.swift" \
    "$ROOT_DIR/Sources/AppDelegate.swift" \
    "$ROOT_DIR/Sources/main.swift" \
    -o "$MACOS_DIR/GPUGuardian"

cp "$ROOT_DIR/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

echo "Ad-hoc signing GPUGuardian.app..."
codesign --force --deep --sign - "$APP_BUNDLE"

echo "Build succeeded: $APP_BUNDLE"
