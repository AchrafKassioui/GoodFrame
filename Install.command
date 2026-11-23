#!/bin/zsh
# Build Good Frame in Release mode, replace the app in Applications, and open it.
# Double-click in Finder to run.
set -euo pipefail
cd "$(dirname "$0")"

app_name="Good Frame.app"
installed="/Applications/$app_name"
build="$(mktemp -d)"
trap 'rm -rf "$build"' EXIT

# Ask before quitting a running copy
if pgrep -xq "Good Frame"; then
    if ! read -q "?Good Frame is running. Quit it and install? [y/N] "; then
        echo "\nCancelled."
        exit 0
    fi
    echo
fi

# The build runs in the background while a counter shows it's working
log="$build/build.log"
xcodebuild -project GoodFrame.xcodeproj -scheme GoodFrame -configuration Release \
    -derivedDataPath "$build" build > "$log" 2>&1 &
builder=$!
started=$SECONDS
while kill -0 $builder 2>/dev/null; do
    printf "\rBuilding Good Frame… %ds" $((SECONDS - started))
    sleep 1
done
if ! wait $builder; then
    echo "\nBuild failed:"
    grep -E "error:" "$log" | sort -u | head -20
    exit 1
fi
printf "\rBuilt in %ds.                \n" $((SECONDS - started))
built="$build/Build/Products/Release/$app_name"
codesign --verify --deep --strict "$built"
version=$(defaults read "$built/Contents/Info" CFBundleShortVersionString)

# Replace the installed app
osascript -e 'quit app "Good Frame"' 2>/dev/null || true
rm -rf "$installed"
ditto "$built" "$installed"

open "$installed"
echo "Installed Good Frame $version in Applications."
