#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

app_dir="$PWD/build/Termvia.app"
codesign --verify --deep --strict "$app_dir"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_dir/Contents/Info.plist")
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Invalid release version.' >&2; exit 1; }
if [ -n "${RELEASE_TAG:-}" ] && [ "$RELEASE_TAG" != "v$version" ]; then
    echo "Release tag must match the app version: v$version" >&2; exit 1
fi
for executable in Termvia termvia-askpass termvia-ppk; do
    [ "$(lipo -archs "$app_dir/Contents/MacOS/$executable")" = arm64 ] || {
        echo "Unexpected architecture: $executable" >&2; exit 1;
    }
done
[ "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$app_dir/Contents/Info.plist")" = 27.0 ]
mkdir -p dist
archive="Termvia-$version-macos-arm64.zip"
rm -f "dist/$archive"
COPYFILE_DISABLE=1 ditto -c -k --keepParent --norsrc --noextattr --noqtn "$app_dir" "dist/$archive"
(
    cd dist
    shasum -a 256 "$archive" > "$archive.sha256"
)
printf '%s\n' "$PWD/dist/$archive" "$PWD/dist/$archive.sha256"
