#!/bin/bash
# Rebuilds libwg-go.a from UPSTREAM wireguard-go for tvOS arm64.
#
# This archive must contain no AmneziaWG code. AmneziaWG has its own archive
# (AmneziaWGKit/Scripts/build-awg-go.sh) linked into a separate extension
# process — two Go c-archives cannot be linked into one binary (their cgo
# bridge symbols collide), and keeping them apart means an AmneziaWG change
# can never reach WireGuard users.
#
# api-apple.go is wireguard-apple's Sources/WireGuardKitGo/api-apple.go, unmodified.
#
# Requires: Go 1.25+, Xcode with the AppleTVOS SDK.

set -euo pipefail

WG_VERSION="${WG_VERSION:-v0.0.0-20260522210424-ecfc5a8d5446}"
TVOS_MIN="${TVOS_MIN:-17.0}"   # matches WireGuardKit/Package.swift's .tvOS(.v17)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEST_DIR="$SCRIPT_DIR/../Sources/WireGuardKitGo"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
SDK="$(xcrun --sdk appletvos --show-sdk-path)"
CLANG="$(xcrun --sdk appletvos --find clang)"

cp "$SCRIPT_DIR/api-apple.go" "$WORK_DIR/"
cd "$WORK_DIR"

go mod init zacvpn/wgapple
go mod edit -require="golang.zx2c4.com/wireguard@$WG_VERSION"
go mod tidy

# Go has no tvOS port; GOOS=ios plus an explicit tvOS clang target is the
# standard workaround and produces LC_BUILD_VERSION platform 3 (tvOS) objects.
CGO_ENABLED=1 GOOS=ios GOARCH=arm64 \
  CC="$CLANG" \
  CGO_CFLAGS="-target arm64-apple-tvos$TVOS_MIN -isysroot $SDK" \
  CGO_LDFLAGS="-target arm64-apple-tvos$TVOS_MIN -isysroot $SDK" \
  go build -trimpath -buildmode=c-archive -o libwg-go.a

# Dump once to files: piping into `grep -q` under pipefail SIGPIPEs the
# producer, which would make the negative checks below silently pass.
nm -gU libwg-go.a > syms.txt 2>/dev/null
strings -a libwg-go.a > strs.txt

# Isolation checks: wg* entry points present, nothing from AmneziaWG.
grep -q "_wgTurnOn\$" syms.txt || { echo "error: wgTurnOn missing" >&2; exit 1; }
if grep -q "_awg" syms.txt; then
    echo "error: archive exports awg* symbols — AmneziaWG must not be in the WireGuard library" >&2; exit 1
fi
if grep -q "amneziawg-go" strs.txt; then
    echo "error: archive contains amneziawg-go code" >&2; exit 1
fi

cp libwg-go.a "$DEST_DIR/libwg-go.a"
echo "Installed $DEST_DIR/libwg-go.a (wireguard-go $WG_VERSION, tvOS $TVOS_MIN arm64)"
