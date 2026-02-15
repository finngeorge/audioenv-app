#!/bin/bash

# Create a proper macOS .app bundle for AudioEnv
# This ensures text input works correctly by launching as a GUI app

set -e

CONFIG="${1:-debug}"

echo "Building AudioEnv ($CONFIG)..."
swift build --configuration "$CONFIG"

APP_NAME="AudioEnv.app"
APP_DIR="$APP_NAME/Contents/MacOS"
PLIST_DIR="$APP_NAME/Contents"

echo "Creating .app bundle structure..."
rm -rf "$APP_NAME"
mkdir -p "$APP_DIR"

echo "Copying executable..."
cp ".build/$CONFIG/AudioEnv" "$APP_DIR/AudioEnv"

echo "Copying resources..."
mkdir -p "$APP_NAME/Contents/Resources"
if [ -d ".build/arm64-apple-macosx/$CONFIG/AudioEnv_AudioEnv.bundle" ]; then
    cp -R ".build/arm64-apple-macosx/$CONFIG/AudioEnv_AudioEnv.bundle" "$APP_NAME/Contents/Resources/"
fi

echo "Copying app icon..."
if [ -f "audioenv.icns" ]; then
    cp "audioenv.icns" "$APP_NAME/Contents/Resources/audioenv.icns"
fi

echo "Creating Info.plist..."
cat > "$PLIST_DIR/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>AudioEnv</string>
    <key>CFBundleIdentifier</key>
    <string>com.audioenv.app</string>
    <key>CFBundleName</key>
    <string>AudioEnv</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>CFBundleIconFile</key>
    <string>audioenv</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSUIElement</key>
    <false/>
</dict>
</plist>
EOF

echo "Codesigning with entitlements..."
codesign --force --sign - --entitlements AudioEnv-adhoc.entitlements --deep "$APP_NAME"

echo ""
echo "✅ $APP_NAME created successfully!"
echo ""
echo "To run the app with working text input:"
echo "  open $APP_NAME"
echo ""
echo "Or double-click $APP_NAME in Finder"
