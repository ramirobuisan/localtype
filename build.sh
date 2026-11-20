#!/bin/bash
# Builds LocalType.app (menu-bar only, ad-hoc signed).
set -e
cd "$(dirname "$0")"
# Map source paths to "." so the binary doesn't carry this Mac's folder layout.
swift build -c release -Xswiftc -file-prefix-map -Xswiftc "$PWD=."
APP=LocalType.app
VERSION=$(cat VERSION)
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 1)
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
cp .build/release/LocalType "$APP/Contents/MacOS/"
mkdir -p "$APP/Contents/Frameworks"
cp -R Vendor/build-apple/llama.xcframework/macos-arm64_x86_64/llama.framework "$APP/Contents/Frameworks/"
mkdir -p "$APP/Contents/Resources"
cp LICENSE "$APP/Contents/Resources/LICENSE"
[ -f Vendor/LICENSE-llama.cpp ] && cp Vendor/LICENSE-llama.cpp "$APP/Contents/Resources/LICENSE-llama.cpp"
cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>io.github.ramirobuisan.localtype</string>
<key>CFBundleName</key><string>LocalType</string>
<key>CFBundleExecutable</key><string>LocalType</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$BUILD</string>
<key>CFBundleURLTypes</key><array><dict>
  <key>CFBundleURLName</key><string>LocalType settings</string>
  <key>CFBundleURLSchemes</key><array><string>localtype</string></array>
</dict></array>
<key>LSUIElement</key><true/>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSAppleEventsUsageDescription</key><string>Needed to insert suggestions.</string>
</dict></plist>
PL
# Drop debug symbols (they list build paths) before signing.
strip -S -x "$APP/Contents/MacOS/LocalType"
# SIGN_ID: name of a code-signing certificate (keeps the Accessibility grant across rebuilds); "-" = ad-hoc
codesign --force --deep --sign "${SIGN_ID:--}" "$APP"
echo "Built $APP"
