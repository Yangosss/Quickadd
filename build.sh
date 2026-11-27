#!/bin/bash
# Builds a universal (arm64 + x86_64) build/QuickAdd.app.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/QuickAdd.app"
rm -rf build
mkdir -p "$APP/Contents/MacOS"

for ARCH in arm64 x86_64; do
  swiftc -O -swift-version 5 -target "$ARCH-apple-macos13.0" \
    Sources/main.swift -o "build/QuickAdd-$ARCH"
done
lipo -create build/QuickAdd-arm64 build/QuickAdd-x86_64 -output "$APP/Contents/MacOS/QuickAdd"
rm build/QuickAdd-arm64 build/QuickAdd-x86_64

cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
echo "Built $APP"
