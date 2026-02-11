#!/bin/bash

# Build and run AudioEnv as a proper macOS .app bundle
# This ensures text input works correctly

set -e

echo "Creating AudioEnv.app bundle..."
./create-app-bundle.sh debug

echo ""
echo "Launching AudioEnv..."
open AudioEnv.app

echo ""
echo "✅ AudioEnv is now running!"
echo "   Text input should work correctly."
echo ""
echo "To rebuild and relaunch:"
echo "  ./run-app.sh"
