#!/bin/bash
# Builds "Capture Stream.app" into client/build/. Ad-hoc signed, so it runs on this Mac;
# to share a build, sign it with your own Developer ID instead.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
BIN=$(swift build -c release --show-bin-path)/CaptureStream
APP="build/Capture Stream.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/CaptureStream"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - --timestamp=none "$APP"

echo "Built $PWD/$APP"
