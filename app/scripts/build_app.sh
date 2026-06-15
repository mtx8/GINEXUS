#!/usr/bin/env bash
# Build a SELF-CONTAINED GINEXUS.app: Swift UI + the embedded Rust core engine, Hardened-Runtime
# codesigned. The Rust binary lives in Contents/MacOS/ginexus-server (in-bundle → no ~/Desktop,
# so Desktop-TCC is moot and `open` works normally). The app mints+injects the core's keys.
#
# Signing: ad-hoc (-s -) for LOCAL verification (no Developer-ID key prompt). For DISTRIBUTION,
# re-sign every Mach-O with a "Developer ID Application" cert + --timestamp, then notarize:
#   xcrun notarytool submit GINEXUS.app.zip --apple-id <id> --team-id <TEAMID> --password <pw> --wait
#   xcrun stapler staple GINEXUS.app        (see docs/adr/0001-packaging-signing.md)
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=release
BIN_NAME=GinexusApp
APP="$PWD/.build/GINEXUS.app"
SIGN_ID="${GINEXUS_SIGN_ID:--}"   # default ad-hoc; override with a Developer ID for distribution

echo "== [1/5] swift build (app) =="
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/$BIN_NAME"
[ -x "$BIN" ] || { echo "FAIL: app binary not built at $BIN"; exit 1; }

echo "== [2/5] cargo build --release (Rust core) =="
( cd ../core && cargo build -q --release -p ginexus-server )
RUST_BIN="../core/target/release/ginexus-server"
[ -x "$RUST_BIN" ] || { echo "FAIL: rust core not built at $RUST_BIN"; exit 1; }

echo "== [3/5] assemble bundle =="
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$BIN_NAME"
cp "$RUST_BIN" "$APP/Contents/MacOS/ginexus-server"   # embedded core engine
cp Info.plist "$APP/Contents/Info.plist"

echo "== [4/5] codesign (Hardened Runtime, id=$SIGN_ID) — nested binary first, then app =="
codesign --force --options runtime --timestamp=none \
  --entitlements GINEXUS.entitlements -s "$SIGN_ID" "$APP/Contents/MacOS/ginexus-server"
codesign --force --options runtime --timestamp=none \
  --entitlements GINEXUS.entitlements -s "$SIGN_ID" "$APP"

echo "== [5/5] verify =="
codesign --verify --strict --verbose=2 "$APP"
echo "app signature:";  codesign -dv "$APP" 2>&1 | grep -E "Identifier|Signature|flags|Runtime"
echo "core signature:"; codesign -dv "$APP/Contents/MacOS/ginexus-server" 2>&1 | grep -E "Identifier|Signature|flags"
echo "BUILT (self-contained): $APP"
