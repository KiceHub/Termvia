#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
[ "$(uname -m)" = arm64 ] || { echo 'Apple Silicon is required.' >&2; exit 1; }
go_tool=$(command -v go || true)
if [ -z "$go_tool" ] && [ -x /usr/local/go/bin/go ]; then go_tool=/usr/local/go/bin/go; fi
[ -n "$go_tool" ] || { echo 'Go 1.27.4 or later is required to build WireGuard.' >&2; exit 1; }
rm -rf .build/wireguard-licenses
mkdir -p .build/wireguard-licenses
MACOSX_DEPLOYMENT_TARGET=27.0 CGO_ENABLED=1 GOOS=darwin GOARCH=arm64 "$go_tool" -C WireGuardTransport build -mod=readonly -trimpath -ldflags='-s -w -buildid= -linkmode=external -extldflags=-mmacosx-version-min=27.0' -o ../.build/termvia-wireguard .
# Bundle each dependency's own licence with the binary.
"$go_tool" -C WireGuardTransport list -m -f '{{.Path}}|{{.Dir}}' all | while IFS='|' read -r module directory; do
    [ -n "$directory" ] || continue
    name=${module//\//_}
    for license in LICENSE COPYING; do
        if [ -f "$directory/$license" ]; then install -m 644 "$directory/$license" ".build/wireguard-licenses/$name-$license.txt"; fi
    done
done

install -m 644 "$("$go_tool" env GOROOT)/LICENSE" .build/wireguard-licenses/Go-LICENSE.txt
