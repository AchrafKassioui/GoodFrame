#!/bin/zsh
# Build Good Frame in Release mode and zip it with the license as good-frame.zip, next to this file.
# Double-click in Finder to run.
set -euo pipefail
cd "$(dirname "$0")"

app_name="Good Frame.app"
build="$(mktemp -d)"
trap 'rm -rf "$build"' EXIT

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

# Zip the app and the license together
staging="$build/zip"
mkdir "$staging"
ditto "$built" "$staging/$app_name"
cp LICENSE "$staging/"
rm -f good-frame.zip
ditto -c -k --sequesterRsrc "$staging" good-frame.zip
echo "Made good-frame.zip with Good Frame $version."
