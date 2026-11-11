#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

install_dir="${1:-/Applications}"
app_dir="$PWD/build/Termvia.app"
destination="$install_dir/Termvia.app"
codesign --verify --deep --strict "$app_dir"
mkdir -p "$install_dir"
staging=$(mktemp -d "$install_dir/.termvia-install.XXXXXX")

cleanup() {
    # Restore the previous installation if replacing it failed.
    if [ -e "$staging/previous.app" ] || [ -L "$staging/previous.app" ]; then
        if [ ! -e "$destination" ] && [ ! -L "$destination" ]; then
            mv "$staging/previous.app" "$destination"
        fi
    fi
    rm -rf "$staging"
}
trap cleanup EXIT

ditto "$app_dir" "$staging/Termvia.app"
codesign --verify --deep --strict "$staging/Termvia.app"
if [ -e "$destination" ] || [ -L "$destination" ]; then
    mv "$destination" "$staging/previous.app"
fi
mv "$staging/Termvia.app" "$destination"
printf 'Installed %s\n' "$destination"
