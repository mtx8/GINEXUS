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

# Persist the token + approval key for the app (the signed app mints approval tokens after a
# biometric assertion, so it needs the approval key). Audit key stays env-only. Best-effort.
if [ -x "$KCS" ]; then
  printf '%s' "$TOKEN" | "$KCS" store ginexus.core.token 2>/dev/null || true
  printf '%s' "$GINEXUS_APPROVAL_KEY" | "$KCS" store ginexus.core.approval 2>/dev/null \
    || echo "[run_core] keychain store skipped; secrets still injected via env" >&2
fi

# Always (re)build incrementally so we never exec a stale binary (near-instant if unchanged).
cargo build -q -p ginexus-server
exec target/debug/ginexus-server --uds "$SOCK"
