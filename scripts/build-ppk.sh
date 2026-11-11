#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Source and build tooling are cached, not shipped. Only the native arm64
# helper and PuTTY's licence enter the application bundle.
source_cache="$PWD/.build/ppk-source"
tool_cache="$PWD/.build/build-tools"
mkdir -p "$source_cache" "$tool_cache"
fetch() {
    local url="$1" destination="$2" digest="$3"
    if [ ! -f "$destination" ] || [ "$(shasum -a 256 "$destination" | awk '{print $1}')" != "$digest" ]; then
        curl --fail --location --silent --show-error --retry 4 --retry-delay 2 --retry-all-errors \
            --connect-timeout 20 --max-time 600 --proto '=https' --proto-redir '=https' "$url" --output "$destination"
    fi
    [ "$(shasum -a 256 "$destination" | awk '{print $1}')" = "$digest" ] || { echo "PPK build dependency checksum mismatch" >&2; exit 1; }
}
fetch 'https://the.earth.li/~sgtatham/putty/0.85/putty-0.85.tar.gz' "$source_cache/putty-0.85.tar.gz" '13fd4db2936d03b73812a7bcc2a658e4dd29cc776a56c3670a7fc6f1a0ee8af8'
if [ ! -f "$source_cache/putty-0.85/CMakeLists.txt" ]; then tar -xzf "$source_cache/putty-0.85.tar.gz" -C "$source_cache"; fi
wheel="$tool_cache/cmake-4.1.2-py3-none-macosx_10_10_universal2.whl"
fetch 'https://files.pythonhosted.org/packages/ca/f7/f28a1df8d35cb6e37ff087e9f995cc0253ab1ffc55b12cf276436db4d392/cmake-4.1.2-py3-none-macosx_10_10_universal2.whl' "$wheel" '415396a7320856c64bd27ca00950b2bbb161604bff60ae5ebf256e2ca08b81ab'
cmake="$tool_cache/cmake-4.1.2/cmake/data/bin/cmake"
if [ ! -f "$cmake" ]; then python3 -m zipfile -e "$wheel" "$tool_cache/cmake-4.1.2"; fi
chmod +x "$tool_cache/cmake-4.1.2/cmake/data/bin/"*
mkdir -p .build/ppk-build
"$cmake" -S "$source_cache/putty-0.85" -B .build/ppk-build \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_COMPILER="$(xcrun --find clang)" \
    -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=27.0 \
    -DCMAKE_EXE_LINKER_FLAGS=-Wl,-no_warn_duplicate_libraries -DPUTTY_GTK_VERSION=NONE \
    > .build/ppk-build/configure.log 2>&1 || { tail -40 .build/ppk-build/configure.log; exit 1; }
"$cmake" --build .build/ppk-build --target puttygen --parallel 6 \
    > .build/ppk-build/build.log 2>&1 || { tail -40 .build/ppk-build/build.log; exit 1; }
[ "$(lipo -archs .build/ppk-build/puttygen)" = arm64 ]
