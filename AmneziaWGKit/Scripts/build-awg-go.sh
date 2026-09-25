#!/bin/bash
# Rebuilds libawg-go.a from amneziawg-go for tvOS arm64.
#
# This archive must contain no upstream WireGuard code and export only awg*
# symbols. It is linked solely into the Amnezia Tunnel extension; WireGuard has
# its own archive (WireGuardKit/Scripts/build-wg-go.sh) in a separate process.
# Two Go c-archives cannot be linked into one binary, so keep them apart.
#
# Bump AWG_VERSION to pick up a new AmneziaWG release, run this script, then
# rebuild the app.
#
# Requires: Go 1.25+, Xcode with the AppleTVOS SDK.

set -euo pipefail

AWG_VERSION="${AWG_VERSION:-v3.1.20260828}"
TVOS_MIN="${TVOS_MIN:-17.0}"   # matches AmneziaWGKit/Package.swift's .tvOS(.v17)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEST_DIR="$SCRIPT_DIR/../Sources/AmneziaWGKitGo"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
SDK="$(xcrun --sdk appletvos --show-sdk-path)"
CLANG="$(xcrun --sdk appletvos --find clang)"

cp "$SCRIPT_DIR/api-apple.go" "$WORK_DIR/"
cd "$WORK_DIR"

go mod init zacvpn/awgapple
go mod edit -require="github.com/amnezia-vpn/amneziawg-go/v3@$AWG_VERSION"
go mod tidy

# Go has no tvOS port; GOOS=ios plus an explicit tvOS clang target is the
# standard workaround and produces LC_BUILD_VERSION platform 3 (tvOS) objects.
CGO_ENABLED=1 GOOS=ios GOARCH=arm64 \
  CC="$CLANG" \
  CGO_CFLAGS="-target arm64-apple-tvos$TVOS_MIN -isysroot $SDK" \
  CGO_LDFLAGS="-target arm64-apple-tvos$TVOS_MIN -isysroot $SDK" \
  go build -trimpath -buildmode=c-archive -o libawg-go.a

# Dump once to files: piping into `grep -q` under pipefail SIGPIPEs the
# producer, which would make the negative checks below silently pass.
nm -gU libawg-go.a > syms.txt 2>/dev/null
strings -a libawg-go.a > strs.txt

# Isolation checks: awg* entry points present, no wg* exports, no upstream WireGuard.
grep -q "_awgTurnOn\$" syms.txt || { echo "error: awgTurnOn missing" >&2; exit 1; }
if grep -qE "_wg[A-Z]" syms.txt; then
    echo "error: archive exports wg* symbols — it would shadow WireGuardKit" >&2; exit 1
fi
if grep -q "golang.zx2c4.com/wireguard/device" strs.txt; then
    echo "error: archive contains upstream wireguard-go" >&2; exit 1
fi
grep -q header_protection_key strs.txt || {
    echo "error: AmneziaWG 3.1 UAPI keys missing — wrong amneziawg-go version?" >&2; exit 1; }

cp libawg-go.a "$DEST_DIR/libawg-go.a"
echo "Installed $DEST_DIR/libawg-go.a (amneziawg-go $AWG_VERSION, tvOS $TVOS_MIN arm64)"
