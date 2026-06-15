#!/usr/bin/env bash
# Build GINEXUS.app: compile (SwiftPM) → assemble .app bundle → Hardened-Runtime codesign.
#
# Signing: ad-hoc (-s -) for LOCAL verification so no Developer-ID key prompt blocks the build.
# For DISTRIBUTION the operator re-signs with a "Developer ID Application" cert and notarizes:
#   codesign --force --options runtime --timestamp --entitlements GINEXUS.entitlements \
#     -s "Developer ID Application: <NAME> (<TEAMID>)" "$APP"
#   xcrun notarytool submit "$APP".zip --apple-id <id> --team-id <TEAMID> --password <app-pw> --wait
#   xcrun stapler staple "$APP"
# (See docs/adr/0001-packaging-signing.md.)
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=release
BIN_NAME=GinexusApp
APP="$PWD/.build/GINEXUS.app"
SIGN_ID="${GINEXUS_SIGN_ID:--}"   # default ad-hoc; override with a Developer ID for distribution

echo "== [1/4] swift build =="
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/$BIN_NAME"
[ -x "$BIN" ] || { echo "FAIL: binary not built at $BIN"; exit 1; }

echo "== [2/4] assemble bundle =="
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$BIN_NAME"
cp Info.plist "$APP/Contents/Info.plist"
cp Resources/sidecar-heartbeat.sh "$APP/Contents/Resources/"
chmod +x "$APP/Contents/Resources/sidecar-heartbeat.sh"

echo "== [3/4] codesign (Hardened Runtime, id=$SIGN_ID) =="
codesign --force --options runtime --timestamp=none \
  --entitlements GINEXUS.entitlements -s "$SIGN_ID" "$APP/Contents/Resources/sidecar-heartbeat.sh" 2>/dev/null || true
codesign --force --options runtime --timestamp=none \
  --entitlements GINEXUS.entitlements -s "$SIGN_ID" "$APP"

echo "== [4/4] verify =="
codesign --verify --strict --verbose=2 "$APP"
echo "signature:"; codesign -dv "$APP" 2>&1 | grep -E "Identifier|Signature|flags|Runtime"
echo "BUILT: $APP"
