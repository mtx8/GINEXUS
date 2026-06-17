#!/usr/bin/env bash
# Build a SELF-CONTAINED GINEXUS.app: Swift UI + the embedded Rust core engine, Hardened-Runtime
# codesigned, with the brand app icon. The Rust binary lives in Contents/MacOS/ginexus-server
# (in-bundle → no ~/Desktop, so Desktop-TCC is moot and `open` works normally). The app mints +
# injects the core's keys. After building it DEPLOYS the app to clickable locations (/Applications
# + ~/Desktop) so double-clicking the icon always launches the freshly-built version.
#
# Signing: ad-hoc (-s -) for LOCAL use (no Developer-ID prompt). For DISTRIBUTION, set
# GINEXUS_SIGN_ID to a "Developer ID Application" cert and notarize (docs/adr/0001-packaging-signing.md).
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=release
BIN_NAME=GinexusApp
APP="$PWD/.build/GINEXUS.app"
SIGN_ID="${GINEXUS_SIGN_ID:--}"   # default ad-hoc; override with a Developer ID for distribution

echo "== [1/6] swift build (app) =="
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/$BIN_NAME"
[ -x "$BIN" ] || { echo "FAIL: app binary not built at $BIN"; exit 1; }

echo "== [2/6] cargo build --release (Rust core) =="
( cd ../core && cargo build -q --release -p ginexus-server )
RUST_BIN="../core/target/release/ginexus-server"
[ -x "$RUST_BIN" ] || { echo "FAIL: rust core not built at $RUST_BIN"; exit 1; }

echo "== [3/6] app icon =="
# Regenerate the brand mark from source so the icon is always current, then build the .icns.
if [ -f scripts/make_icon.swift ]; then
  swift scripts/make_icon.swift /tmp/ginexus_icon_1024.png >/dev/null 2>&1 || true
  if [ -f /tmp/ginexus_icon_1024.png ]; then
    ICONSET=/tmp/GINEXUS.iconset; rm -rf "$ICONSET"; mkdir -p "$ICONSET"
    for spec in 16:16x16 32:16x16@2x 32:32x32 64:32x32@2x 128:128x128 256:128x128@2x 256:256x256 512:256x256@2x 512:512x512 1024:512x512@2x; do
      px="${spec%%:*}"; nm="${spec##*:}"
      sips -z "$px" "$px" /tmp/ginexus_icon_1024.png --out "$ICONSET/icon_${nm}.png" >/dev/null 2>&1
    done
    iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns >/dev/null 2>&1 || true
    cp /tmp/ginexus_icon_1024.png Resources/AppIcon-1024.png 2>/dev/null || true
  fi
fi

echo "== [4/6] assemble bundle =="
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$BIN_NAME"
cp "$RUST_BIN" "$APP/Contents/MacOS/ginexus-server"   # embedded core engine
cp Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

echo "== [5/6] codesign (Hardened Runtime, id=$SIGN_ID) — nested binary first, then app =="
codesign --force --options runtime --timestamp=none \
  --entitlements GINEXUS.entitlements -s "$SIGN_ID" "$APP/Contents/MacOS/ginexus-server"
codesign --force --options runtime --timestamp=none \
  --entitlements GINEXUS.entitlements -s "$SIGN_ID" "$APP"
codesign --verify --strict --verbose=2 "$APP"

echo "== [6/6] deploy (update-in-place so the clickable icon launches the new build) =="
# Stop any running instance so we can overwrite it (otherwise macOS reactivates the old copy).
pkill -f "GINEXUS.app/Contents/MacOS/GinexusApp" 2>/dev/null || true
pkill -f "GINEXUS.app/Contents/MacOS/ginexus-server" 2>/dev/null || true
rm -f "$HOME/Library/Application Support/GINEXUS/run/ginexus.sock" 2>/dev/null || true
sleep 1
DESTS=()
# Install to /Applications (Launchpad/Spotlight/Dock) when writable, else ~/Applications.
if [ -w /Applications ] 2>/dev/null; then DESTS+=("/Applications/GINEXUS.app"); else mkdir -p "$HOME/Applications"; DESTS+=("$HOME/Applications/GINEXUS.app"); fi
# Also drop a clickable copy INSIDE the project folder (repo root), which is the parent of this app/ dir.
DESTS+=("$(dirname "$PWD")/GINEXUS.app")
# Keep the Desktop uncluttered — remove any loose Desktop copy from earlier builds.
rm -rf "$HOME/Desktop/GINEXUS.app" 2>/dev/null || true
for dest in "${DESTS[@]}"; do
  rm -rf "$dest"
  cp -R "$APP" "$dest"
  touch "$dest"           # nudge LaunchServices to refresh the icon
  echo "deployed → $dest"
done
# Refresh the icon cache / register the app so the new icon shows immediately.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f "${DESTS[0]}" 2>/dev/null || true

echo ""
echo "BUILT + DEPLOYED. Double-click any of:"
for dest in "${DESTS[@]}"; do echo "  $dest"; done
echo "(needs Ollama running for chat: 'ollama serve')"
