#!/usr/bin/env bash
# deploy_dev.sh — one command to make the double-clickable app the LATEST build.
#
# Rebuilds the app, stages the Python sidecars to App Support (NOT ~/Desktop — a Finder launch has
# no Desktop TCC permission, which hangs the sidecar's Python at startup), refreshes the app in the
# project folder, and stamps CFBundleVersion with a build timestamp so each deploy is identifiable.
#
# After this:  double-click  ~/Desktop/GINEXUS/GINEXUS.app  →  launches THIS build.
#
# (For a signed/notarized distributable, use build_app.sh instead — this is the fast dev loop.)
set -euo pipefail

cd "$(dirname "$0")/.."                      # → app/
ROOT="$HOME/Desktop/GINEXUS"
SUP="$HOME/Library/Application Support/GINEXUS"
STAMP="$(date +%Y%m%d.%H%M)"
LS="/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister"

echo "== [1/5] regenerate Xcode project =="
xcodegen generate >/dev/null

echo "== [2/5] build (version $STAMP) =="
xcodebuild -project GINEXUS.xcodeproj -scheme GINEXUS -configuration Debug \
  CURRENT_PROJECT_VERSION="$STAMP" build >/tmp/ginexus_build.log 2>&1 \
  || { echo "BUILD FAILED — tail of /tmp/ginexus_build.log:"; tail -25 /tmp/ginexus_build.log; exit 1; }
APP="$(xcodebuild -project GINEXUS.xcodeproj -scheme GINEXUS -configuration Debug -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/ TARGET_BUILD_DIR =/{d=$2} / WRAPPER_NAME =/{w=$2} END{print d"/"w}')"
[ -d "$APP" ] || { echo "could not locate built app at: $APP"; exit 1; }

echo "== [3/5] stage sidecars to App Support (non-TCC) =="
for s in audio-sidecar media-sidecar; do
  mkdir -p "$SUP/$s"
  cp "$s"/server.py "$s"/pyproject.toml "$s"/.python-version "$SUP/$s"/ 2>/dev/null || true
  ( cd "$SUP/$s" && uv sync >/dev/null 2>&1 || true )
done

echo "== [4/5] stop running instances =="
pkill -f "GINEXUS.app/Contents/MacOS" 2>/dev/null || true
pkill -f uvicorn 2>/dev/null || true
sleep 1

echo "== [5/5] deploy to project folder + refresh icon cache =="
rm -rf "$ROOT/GINEXUS.app"
cp -R "$APP" "$ROOT/GINEXUS.app"
touch "$ROOT/GINEXUS.app"
"$LS" -f "$ROOT/GINEXUS.app" >/dev/null 2>&1 || true

echo "✅ Deployed build $STAMP → $ROOT/GINEXUS.app"
echo "   Double-click the app icon in the project folder to launch the latest version."
