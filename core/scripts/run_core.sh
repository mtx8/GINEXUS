#!/usr/bin/env bash
# Launch the Rust GINEXUS core engine. Mints the per-launch secrets (bearer token + audit +
# approval HMAC keys), persists the token via the signed keychainstore tool (so the app can
# read it), exports all three (the server FAILS CLOSED without the keys), and execs the binary
# on the GINEXUS UDS. (Sandboxing via sandbox-exec is added by the app launcher in production.)
set -euo pipefail
cd "$(dirname "$0")/.."  # GINEXUS/core

KCS="$HOME/Desktop/MTX-NEXUS/swift/GinexusKeychain/.build/release/keychainstore"
GX="$HOME/Library/Application Support/GINEXUS"
SOCK="${GINEXUS_SOCK:-$GX/run/ginexus.sock}"
mkdir -p "$GX/run"

TOKEN="$(openssl rand -hex 32)"
export GINEXUS_TOKEN="$TOKEN"
export GINEXUS_AUDIT_KEY="$(openssl rand -hex 32)"
export GINEXUS_APPROVAL_KEY="$(openssl rand -hex 32)"

# Persist the token for the app to read back (best-effort; env is authoritative).
if [ -x "$KCS" ]; then
  printf '%s' "$TOKEN" | "$KCS" store ginexus.core.token 2>/dev/null \
    || echo "[run_core] keychain store skipped; token still injected via env" >&2
fi

[ -x target/release/ginexus-server ] && BIN=target/release/ginexus-server || BIN=target/debug/ginexus-server
[ -x "$BIN" ] || cargo build -q
exec "$BIN" --uds "$SOCK"
