#!/bin/zsh
# Build Good Frame in Release mode, replace the app in Applications, and open it.
# Run from Terminal: ./install.sh
set -euo pipefail
cd "$(dirname "$0")"

app_name="Good Frame.app"
installed="/Applications/$app_name"
build="$(mktemp -d)"
trap 'rm -rf "$build"' EXIT

# Build
echo "Building Good Frame in Release mode…"
xcodebuild -project GoodFrame.xcodeproj -scheme GoodFrame -configuration Release \
    -derivedDataPath "$build" build -quiet
built="$build/Build/Products/Release/$app_name"
codesign --verify --deep --strict "$built"
version=$(defaults read "$built/Contents/Info" CFBundleShortVersionString)

# Replace the installed app
osascript -e 'quit app "Good Frame"' 2>/dev/null || true
rm -rf "$installed"
ditto "$built" "$installed"

open "$installed"
echo "Installed Good Frame $version in Applications."
