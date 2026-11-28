#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
case "$#:${1-}" in
    0:) app_dir="$PWD/build/Termvia.app" ;;
    1:--test-bundle) app_dir="$PWD/build/diagnostics/Termvia.app" ;;
    *) echo "Usage: $0 [--test-bundle]" >&2; exit 2 ;;
esac
[ "$(uname -m)" = arm64 ] || { echo 'Apple Silicon is required.' >&2; exit 1; }
os_version=$(sw_vers -productVersion)
sdk_version=$(xcrun --sdk macosx --show-sdk-version)
[ "${os_version%%.*}" -ge 27 ] && [ "${sdk_version%%.*}" -ge 27 ] || {
    echo 'macOS 27 or later and the macOS 27 SDK or later are required.' >&2; exit 1;
}
swift_options=(--arch arm64 -c release --only-use-versions-from-resolved-file)
swift build "${swift_options[@]}" --product Termvia
swift build "${swift_options[@]}" --product termvia-askpass
swift build "${swift_options[@]}" --product termvia-proxy
bash scripts/build-rust-helpers.sh
rust_bin_dir="$PWD/.build/rust/aarch64-apple-darwin/release"
bin_dir=$(swift build "${swift_options[@]}" --show-bin-path)
# Recreate the bundle so removed resources cannot survive an incremental build.
rm -rf "$app_dir"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$bin_dir/Termvia" "$app_dir/Contents/MacOS/Termvia"
install -m 755 "$bin_dir/termvia-askpass" "$app_dir/Contents/MacOS/termvia-askpass"
install -m 755 "$bin_dir/termvia-proxy" "$app_dir/Contents/MacOS/termvia-proxy"
strip -S "$app_dir/Contents/MacOS/termvia-proxy"
codesign --force --sign - "$app_dir/Contents/MacOS/termvia-proxy"
# Remove debug symbols and their absolute local build paths before signing.
strip -S "$app_dir/Contents/MacOS/Termvia" "$app_dir/Contents/MacOS/termvia-askpass"
codesign --force --sign - "$app_dir/Contents/MacOS/termvia-askpass"
for helper in termvia-wireguard termvia-ppk; do
    install -m 755 "$rust_bin_dir/$helper" "$app_dir/Contents/MacOS/$helper"
    codesign --force --sign - "$app_dir/Contents/MacOS/$helper"
done
python3 scripts/bundle-rust-licenses.py "$app_dir/Contents/Resources/Rust-Licenses"
cp Resources/Info.plist "$app_dir/Contents/Info.plist"
# Stamp the packaged artifact, so About reports this build rather than launch time.
/usr/libexec/PlistBuddy -c "Add :TermviaBuildDate string $(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$app_dir/Contents/Info.plist"
install -m 644 Resources/Termvia.svg "$app_dir/Contents/Resources/Termvia.svg"
icon_build_dir=$(mktemp -d "${TMPDIR:-/tmp}/termvia-icon-build.XXXXXX")
trap 'rm -rf "$icon_build_dir"' EXIT
xcrun actool Resources/Termvia.icon --compile "$icon_build_dir" --app-icon Termvia \
    --include-all-app-icons --platform macosx --target-device mac --minimum-deployment-target 27.0 \
    --output-partial-info-plist "$icon_build_dir/icon.plist" --output-format human-readable-text --notices --warnings
install -m 644 "$icon_build_dir/Assets.car" "$app_dir/Contents/Resources/Assets.car"
install -m 644 "$icon_build_dir/Termvia.icns" "$app_dir/Contents/Resources/Termvia.icns"
python3 - "$app_dir/Contents/Info.plist" "$icon_build_dir/icon.plist" <<'PY'
import plistlib
import sys
from pathlib import Path
destination = Path(sys.argv[1])
info = plistlib.loads(destination.read_bytes())
info.update(plistlib.loads(Path(sys.argv[2]).read_bytes()))
destination.write_bytes(plistlib.dumps(info))
PY
install -m 644 .build/checkouts/SwiftTerm/LICENSE "$app_dir/Contents/Resources/SwiftTerm-LICENSE.txt"
install -m 644 LICENSE "$app_dir/Contents/Resources/LICENSE.txt"
install -m 644 NOTICE "$app_dir/Contents/Resources/NOTICE.txt"
install -m 644 Package.resolved "$app_dir/Contents/Resources/Package.resolved"
for bundle in "$bin_dir/"*.bundle; do
    if [ -d "$bundle" ]; then cp -R "$bundle" "$app_dir/Contents/Resources/"; fi
done
codesign --force --sign - "$app_dir"
echo "$app_dir"
