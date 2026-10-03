#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --product SweepApp
app=".build/Sweep.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .build/debug/SweepApp "$app/Contents/MacOS/SweepApp"
cp Sources/SweepApp/Info.plist "$app/Contents/Info.plist"
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
open "$app"
