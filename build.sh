#!/bin/bash
# Builds Cotypist.app (menu-bar only, ad-hoc signed).
set -e
cd "$(dirname "$0")"
swift build -c release
APP=Cotypist.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
cp .build/release/Cotypist "$APP/Contents/MacOS/"
mkdir -p "$APP/Contents/Frameworks"
cp -R Vendor/build-apple/llama.xcframework/macos-arm64_x86_64/llama.framework "$APP/Contents/Frameworks/"
cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.cotypist.clone</string>
<key>CFBundleName</key><string>Cotypist</string>
<key>CFBundleExecutable</key><string>Cotypist</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSUIElement</key><true/>
<key>NSAppleEventsUsageDescription</key><string>Needed to insert suggestions.</string>
</dict></plist>
PL
codesign --force --deep --sign - "$APP"
echo "Built $APP"
