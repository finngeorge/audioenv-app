#!/bin/bash
set -euo pipefail

# AudioEnv Release Script
# Usage: ./scripts/release.sh 1.0.0-beta.1

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
ARCHIVE_PATH="$PROJECT_DIR/.build/release/$APP_NAME.xcarchive"
APP_PATH="$PROJECT_DIR/.build/release/$APP_NAME.app"
DMG_PATH="$PROJECT_DIR/.build/release/$APP_NAME-$VERSION.dmg"
APPCAST_PATH="$PROJECT_DIR/.build/release/appcast.xml"
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

# Check notarytool credentials (stored in keychain profile)
if ! xcrun notarytool history --keychain-profile "audioenv" --page-size 1 &>/dev/null 2>&1; then
    echo "WARNING: notarytool keychain profile 'audioenv' not found."
    echo "Store credentials with:"
    echo "  xcrun notarytool store-credentials audioenv --apple-id <email> --team-id <team> --password <app-specific-password>"
    echo ""
    echo "Continuing without notarization check..."
fi

# Check Sparkle signing key
SPARKLE_BIN="$PROJECT_DIR/.build/artifacts/sparkle/Sparkle/bin"
if [ ! -d "$SPARKLE_BIN" ]; then
    # Try to find generate_appcast from the SPM build
    SPARKLE_BIN=$(find "$PROJECT_DIR/.build" -name "generate_appcast" -type f 2>/dev/null | head -1 | xargs dirname 2>/dev/null || echo "")
fi
if [ -z "$SPARKLE_BIN" ] || [ ! -f "$SPARKLE_BIN/generate_appcast" ]; then
    echo "WARNING: Sparkle tools not found at $SPARKLE_BIN"
    echo "They'll be available after the first xcodebuild."
    echo "If this is your first release, run: swift build first."
fi

echo "    Version: $VERSION"
echo ""

# ─── Step 2: Set version ──────────────────────────────────────────────────────

echo "==> Setting version to $VERSION..."

# Update project.yml
sed -i '' "s/MARKETING_VERSION: .*/MARKETING_VERSION: \"$VERSION\"/" project.yml 2>/dev/null || true

# Update Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" Sources/AudioEnv/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" Sources/AudioEnv/Info.plist

echo ""

# ─── Step 3: Build ────────────────────────────────────────────────────────────

echo "==> Generating Xcode project..."
if command -v xcodegen &>/dev/null; then
    xcodegen generate
else
    echo "WARNING: xcodegen not found, using existing .xcodeproj"
fi

echo "==> Building release archive..."
mkdir -p .build/release

xcodebuild archive \
    -project "$APP_NAME.xcodeproj" \
    -scheme "$APP_NAME" \
    -configuration Release \
    -archivePath "$ARCHIVE_PATH" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
    CODE_SIGN_ENTITLEMENTS="$ENTITLEMENTS" \
    PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
    MARKETING_VERSION="$VERSION" \
    CURRENT_PROJECT_VERSION="$VERSION" \
    OTHER_CODE_SIGN_FLAGS="--timestamp" \
    | tail -5

# Export the .app from the archive
echo "==> Exporting app from archive..."
rm -rf "$APP_PATH"
cp -R "$ARCHIVE_PATH/Products/Applications/$APP_NAME.app" "$APP_PATH"

# Re-sign with timestamp (belt and suspenders)
codesign --force --sign "$SIGN_IDENTITY" \
    --entitlements "$ENTITLEMENTS" \
    --options runtime \
    --timestamp \
    --deep \
    "$APP_PATH"

echo ""

# ─── Step 4: Notarize ─────────────────────────────────────────────────────────

echo "==> Creating ZIP for notarization..."
NOTARIZE_ZIP="$PROJECT_DIR/.build/release/$APP_NAME-notarize.zip"
ditto -c -k --keepParent "$APP_PATH" "$NOTARIZE_ZIP"

echo "==> Submitting for notarization..."
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

# ─── Step 5: Package DMG ──────────────────────────────────────────────────────

echo "==> Creating DMG..."
rm -f "$DMG_PATH"

# Create a temporary directory for DMG contents
DMG_STAGING="$PROJECT_DIR/.build/release/dmg-staging"
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

# Sign the DMG too
codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG_PATH"

echo "    DMG: $DMG_PATH"
echo ""

# ─── Step 6: Generate Sparkle appcast ─────────────────────────────────────────

echo "==> Generating Sparkle appcast..."

# Find generate_appcast
GENERATE_APPCAST=""
for candidate in \
    "$SPARKLE_BIN/generate_appcast" \
    "$(find "$PROJECT_DIR/.build" -name "generate_appcast" -type f 2>/dev/null | head -1)" \
    "$(find ~/Library/Developer/Xcode/DerivedData -name "generate_appcast" -type f 2>/dev/null | head -1)"; do
    if [ -n "$candidate" ] && [ -f "$candidate" ]; then
        GENERATE_APPCAST="$candidate"
        break
    fi
done

if [ -n "$GENERATE_APPCAST" ]; then
    # generate_appcast needs a directory containing the DMG
    APPCAST_DIR="$PROJECT_DIR/.build/release/appcast-staging"
    mkdir -p "$APPCAST_DIR"
    cp "$DMG_PATH" "$APPCAST_DIR/"

    # Copy existing appcast if we have one (to append new version)
    if [ -f "$APPCAST_PATH" ]; then
        cp "$APPCAST_PATH" "$APPCAST_DIR/"
    fi

    "$GENERATE_APPCAST" "$APPCAST_DIR" \
        --download-url-prefix "https://github.com/$GITHUB_REPO/releases/download/v$VERSION/"

    # Move the generated appcast
    if [ -f "$APPCAST_DIR/appcast.xml" ]; then
        mv "$APPCAST_DIR/appcast.xml" "$APPCAST_PATH"
    fi
    rm -rf "$APPCAST_DIR"
    echo "    Appcast: $APPCAST_PATH"
else
    echo "WARNING: generate_appcast not found. Skipping appcast generation."
    echo "You can generate it manually later with:"
    echo "  /path/to/generate_appcast /path/to/dmg/directory"
fi

echo ""

# ─── Step 7: Upload to GitHub Releases ────────────────────────────────────────

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
echo "  Next steps:"
echo "  - Download the DMG and verify Gatekeeper accepts it"
echo "  - Check that Sparkle picks up the appcast URL"
echo ""

# ─── First-time setup reminder ────────────────────────────────────────────────

if ! "$GENERATE_APPCAST" 2>/dev/null | grep -q "." 2>/dev/null; then
    echo "  NOTE: If this is your first release, generate your Sparkle EdDSA key:"
    echo "    .build/artifacts/sparkle/Sparkle/bin/generate_keys"
    echo ""
    echo "  Then add the public key to Info.plist (SUPublicEDKey)."
    echo "  The private key is stored in your Keychain automatically."
fi
