#!/bin/bash
set -euo pipefail

# AudioEnv Release Script
# Usage: ./scripts/release.sh 1.0.0-beta.1
#
# Builds with swift build, assembles .app bundle, signs with Developer ID,
# notarizes, creates DMG, generates Sparkle appcast, uploads to GitHub Releases.

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
    echo "Usage: ./scripts/release.sh <version>"
    echo "Example: ./scripts/release.sh 1.0.0-beta.1"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
APP_NAME="AudioEnv"
BUNDLE_ID="com.audioenv.app"
IDENTITY="Developer ID Application"
ENTITLEMENTS="$PROJECT_DIR/AudioEnv-release.entitlements"
BUILD_DIR="$PROJECT_DIR/.build/release"
APP_PATH="$BUILD_DIR/$APP_NAME.app"
DMG_PATH="$BUILD_DIR/$APP_NAME-$VERSION.dmg"
APPCAST_PATH="$BUILD_DIR/appcast.xml"
GITHUB_REPO="finngeorge/audioenv-app"

cd "$PROJECT_DIR"

# ─── Step 1: Validate ─────────────────────────────────────────────────────────

echo "==> Validating environment..."

# Check Developer ID cert
if ! security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
    echo "ERROR: No '$IDENTITY' certificate found."
    echo "Install your Developer ID Application certificate from developer.apple.com"
    exit 1
fi

# Get the full signing identity
SIGN_IDENTITY=$(security find-identity -v -p codesigning | grep "$IDENTITY" | head -1 | sed 's/.*"\(.*\)"/\1/')
echo "    Signing identity: $SIGN_IDENTITY"

# Check gh CLI
if ! command -v gh &>/dev/null; then
    echo "ERROR: gh CLI not found. Install with: brew install gh"
    exit 1
fi
if ! gh auth status &>/dev/null; then
    echo "ERROR: gh CLI not authenticated. Run: gh auth login"
    exit 1
fi

# Check notarytool credentials
if ! xcrun notarytool history --keychain-profile "audioenv" &>/dev/null 2>&1; then
    echo "WARNING: notarytool keychain profile 'audioenv' may not be configured."
    echo "If notarization fails, store credentials with:"
    echo "  xcrun notarytool store-credentials audioenv --apple-id <email> --team-id <team> --password <app-specific-password>"
    echo ""
fi

# Sparkle tools location
SPARKLE_BIN="$PROJECT_DIR/.build/artifacts/sparkle/Sparkle/bin"

echo "    Version: $VERSION"
echo ""

# ─── Step 2: Set version ──────────────────────────────────────────────────────

echo "==> Setting version to $VERSION..."

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" Sources/AudioEnv/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" Sources/AudioEnv/Info.plist

echo ""

# ─── Step 3: Build ────────────────────────────────────────────────────────────

echo "==> Building release binary with swift build..."
swift build --configuration release 2>&1

echo ""
echo "==> Assembling .app bundle..."
mkdir -p "$BUILD_DIR"
rm -rf "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS"
mkdir -p "$APP_PATH/Contents/Resources"

# Copy executable
cp ".build/release/$APP_NAME" "$APP_PATH/Contents/MacOS/$APP_NAME"

# Copy SPM resource bundle
RESOURCE_BUNDLE=".build/arm64-apple-macosx/release/AudioEnv_AudioEnv.bundle"
if [ ! -d "$RESOURCE_BUNDLE" ]; then
    # Fallback: try to find it
    RESOURCE_BUNDLE=$(find .build -path "*/release/AudioEnv_AudioEnv.bundle" -type d 2>/dev/null | head -1)
fi
if [ -d "$RESOURCE_BUNDLE" ]; then
    cp -R "$RESOURCE_BUNDLE" "$APP_PATH/Contents/Resources/"
fi

# Copy app icon
if [ -f "audioenv.icns" ]; then
    cp "audioenv.icns" "$APP_PATH/Contents/Resources/audioenv.icns"
fi

# Copy Sparkle framework from SPM artifacts
SPARKLE_FW="$PROJECT_DIR/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
if [ -d "$SPARKLE_FW" ]; then
    mkdir -p "$APP_PATH/Contents/Frameworks"
    cp -R "$SPARKLE_FW" "$APP_PATH/Contents/Frameworks/"
fi

# Write Info.plist with version baked in
cat > "$APP_PATH/Contents/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.music</string>
    <key>CFBundleIconFile</key>
    <string>audioenv</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSUIElement</key>
    <false/>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026. All rights reserved.</string>
    <key>SUFeedURL</key>
    <string>https://github.com/$GITHUB_REPO/releases/latest/download/appcast.xml</string>
    <key>SUPublicEDKey</key>
    <string>/m0SETg14kym6SS2PJQJK+kyAMT1RAtmTjvgRSHkOIY=</string>
    <key>SUEnableAutomaticChecks</key>
    <true/>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>
            <string>$BUNDLE_ID</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>audioenv</string>
                <string>com.audioenv.app</string>
                <string>com.googleusercontent.apps.809075910499-o01a42a6k9vo2e6a1sfcnifpei3bqnv9</string>
            </array>
        </dict>
    </array>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSExceptionDomains</key>
        <dict>
            <key>api.audioenv.com</key>
            <dict>
                <key>NSExceptionAllowsInsecureHTTPLoads</key>
                <true/>
                <key>NSIncludesSubdomains</key>
                <true/>
            </dict>
        </dict>
    </dict>
</dict>
</plist>
EOF

echo ""

# ─── Step 4: Sign ─────────────────────────────────────────────────────────────

echo "==> Signing with Developer ID..."

# Sign all nested binaries inside Sparkle.framework (inside-out)
if [ -d "$APP_PATH/Contents/Frameworks/Sparkle.framework" ]; then
    SPARKLE_DIR="$APP_PATH/Contents/Frameworks/Sparkle.framework"

    # Sign XPC services
    find "$SPARKLE_DIR" -name "*.xpc" -type d | while read -r xpc; do
        codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp "$xpc"
    done

    # Sign nested apps (Updater.app)
    find "$SPARKLE_DIR" -name "*.app" -type d | while read -r app; do
        codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp "$app"
    done

    # Sign standalone executables (Autoupdate)
    find "$SPARKLE_DIR" -type f -perm +111 ! -name ".*" | while read -r bin; do
        # Skip already-signed bundles and non-Mach-O files
        if file "$bin" | grep -q "Mach-O"; then
            codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp "$bin"
        fi
    done

    # Sign the framework itself
    codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp "$SPARKLE_DIR"
fi

# Sign the main app
codesign --force --sign "$SIGN_IDENTITY" \
    --entitlements "$ENTITLEMENTS" \
    --options runtime \
    --timestamp \
    "$APP_PATH"

echo "    Signed: $APP_PATH"
echo ""

# ─── Step 5: Notarize ─────────────────────────────────────────────────────────

echo "==> Creating ZIP for notarization..."
NOTARIZE_ZIP="$BUILD_DIR/$APP_NAME-notarize.zip"
ditto -c -k --keepParent "$APP_PATH" "$NOTARIZE_ZIP"

echo "==> Submitting for notarization (this may take a few minutes)..."
xcrun notarytool submit "$NOTARIZE_ZIP" \
    --keychain-profile "audioenv" \
    --wait

echo "==> Stapling notarization ticket..."
xcrun stapler staple "$APP_PATH"

# Verify
echo "==> Verifying notarization..."
spctl -a -vvv "$APP_PATH" 2>&1 | head -3

rm -f "$NOTARIZE_ZIP"
echo ""

# ─── Step 6: Package DMG ──────────────────────────────────────────────────────

echo "==> Creating DMG..."
rm -f "$DMG_PATH"

DMG_STAGING="$BUILD_DIR/dmg-staging"
rm -rf "$DMG_STAGING"
mkdir -p "$DMG_STAGING"
cp -R "$APP_PATH" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"

hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$DMG_STAGING" \
    -ov \
    -format UDZO \
    "$DMG_PATH"

rm -rf "$DMG_STAGING"

# Sign the DMG
codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG_PATH"

echo "    DMG: $DMG_PATH"
echo ""

# ─── Step 7: Generate Sparkle appcast ─────────────────────────────────────────

echo "==> Generating Sparkle appcast..."

GENERATE_APPCAST="$SPARKLE_BIN/generate_appcast"

if [ -f "$GENERATE_APPCAST" ]; then
    APPCAST_DIR="$BUILD_DIR/appcast-staging"
    mkdir -p "$APPCAST_DIR"
    cp "$DMG_PATH" "$APPCAST_DIR/"

    # Copy existing appcast if we have one (to append new version)
    if [ -f "$APPCAST_PATH" ]; then
        cp "$APPCAST_PATH" "$APPCAST_DIR/"
    fi

    "$GENERATE_APPCAST" "$APPCAST_DIR" \
        --download-url-prefix "https://github.com/$GITHUB_REPO/releases/download/v$VERSION/"

    if [ -f "$APPCAST_DIR/appcast.xml" ]; then
        mv "$APPCAST_DIR/appcast.xml" "$APPCAST_PATH"
    fi
    rm -rf "$APPCAST_DIR"
    echo "    Appcast: $APPCAST_PATH"
else
    echo "WARNING: generate_appcast not found at $GENERATE_APPCAST"
    echo "Skipping appcast generation."
fi

echo ""

# ─── Step 8: Upload to GitHub Releases ────────────────────────────────────────

echo "==> Creating GitHub release v$VERSION..."

RELEASE_NOTES="AudioEnv v$VERSION

Beta release. Includes automatic updates via Sparkle."

UPLOAD_FILES=("$DMG_PATH")
if [ -f "$APPCAST_PATH" ]; then
    UPLOAD_FILES+=("$APPCAST_PATH")
fi

gh release create "v$VERSION" \
    --repo "$GITHUB_REPO" \
    --title "AudioEnv v$VERSION" \
    --notes "$RELEASE_NOTES" \
    --prerelease \
    "${UPLOAD_FILES[@]}"

echo ""

# ─── Done ─────────────────────────────────────────────────────────────────────

echo "============================================"
echo "  Released AudioEnv v$VERSION"
echo "============================================"
echo ""
echo "  Download: https://github.com/$GITHUB_REPO/releases/tag/v$VERSION"
echo "  DMG:      https://github.com/$GITHUB_REPO/releases/download/v$VERSION/$(basename "$DMG_PATH")"
if [ -f "$APPCAST_PATH" ]; then
    echo "  Appcast:  https://github.com/$GITHUB_REPO/releases/download/v$VERSION/appcast.xml"
fi
echo ""
