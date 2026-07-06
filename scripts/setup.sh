#!/usr/bin/env bash
# GINEXUS Setup — the terminal onboarding path (for users who cloned from GitHub).
# Detects your Mac's capabilities, installs the Ollama runtime if missing, pulls a right-sized
# local model, and writes it into the app's settings so launching GINEXUS.app "just works".
# Mirrors the in-app Setup Assistant's recommendation ladder — same result whichever path you take.
#
# Usage:  bash scripts/setup.sh            (auto-recommend a model for this machine)
#         bash scripts/setup.sh <ollama-tag>   (pull a specific model instead)
#
# PSS: installs ONLY the official Ollama — the Homebrew formula, or the code-signed app from
# ollama.com which is verified with `codesign` before install. It asks before installing anything,
# and never pipes a shell from an unknown host.
set -euo pipefail

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
dim()  { printf '\033[2m%s\033[0m\n' "$*"; }
ok()   { printf '\033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '\033[33m!\033[0m %s\n' "$*"; }

# ── 1. detect hardware ───────────────────────────────────────────────────────
CHIP="$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo 'Unknown CPU')"
RAM_BYTES="$(sysctl -n hw.memsize 2>/dev/null || echo 0)"
RAM_GB=$(( RAM_BYTES / 1073741824 ))
CORES="$(sysctl -n hw.ncpu 2>/dev/null || echo '?')"
FREE_GB="$(df -g "$HOME" 2>/dev/null | awk 'NR==2{print $4}' || echo '?')"

# usable RAM = RAM - reserve, reserve = clamp(20%, 3, 16). Integer math (bash).
reserve=$(( RAM_GB * 20 / 100 ))
[ "$reserve" -lt 3 ] && reserve=3
[ "$reserve" -gt 16 ] && reserve=16
USABLE=$(( RAM_GB - reserve ))
[ "$USABLE" -lt 0 ] && USABLE=0

echo
bold "GINEXUS Setup"
dim  "Local-first AI on your Mac. Everything runs on-device."
echo
bold "1 · Your machine"
ok "Chip:      $CHIP"
ok "Memory:    ${RAM_GB} GB  (~${USABLE} GB usable for AI)"
ok "Storage:   ${FREE_GB} GB free"
ok "CPU cores: $CORES"
echo

# ── 2. recommend a right-sized daily driver (same ladder as the app) ─────────
recommend() {
  local u=$1
  if   [ "$u" -ge 24 ]; then echo "qwen3:30b-a3b-instruct-2507-q4_K_M"
  elif [ "$u" -ge 16 ]; then echo "qwen3:14b"
  elif [ "$u" -ge 10 ]; then echo "qwen3:8b"
  elif [ "$u" -ge 4  ]; then echo "qwen3:4b"
  else                       echo "qwen3:1.7b"
  fi
}
MODEL="${1:-$(recommend "$USABLE")}"
bold "2 · Recommended model"
if [ "$USABLE" -ge 24 ]; then
  ok "$MODEL — the full flagship daily driver runs comfortably."
elif [ "$USABLE" -ge 10 ]; then
  ok "$MODEL — the best local fit for this machine."
  dim "   (The 30B flagship needs ~24 GB usable; use a cloud API for the heaviest tier.)"
else
  warn "$MODEL — limited local memory; lean on a cloud API for capable chat."
fi
echo

# ── 3. install / start Ollama ────────────────────────────────────────────────
bold "3 · Ollama runtime"
OLLAMA=""
for c in /opt/homebrew/bin/ollama /usr/local/bin/ollama; do [ -x "$c" ] && OLLAMA="$c" && break; done
[ -z "$OLLAMA" ] && command -v ollama >/dev/null 2>&1 && OLLAMA="$(command -v ollama)"

if [ -z "$OLLAMA" ]; then
  warn "Ollama isn't installed."
  # Non-interactive stdin (piped/CI): don't silently abort on read EOF — bail with guidance.
  if [ ! -t 0 ]; then
    echo "Non-interactive shell. Install Ollama from https://ollama.com/download, then re-run this script."
    exit 1
  fi
  if command -v brew >/dev/null 2>&1; then
    ans=""
    read -r -p "Install it now with Homebrew? [Y/n] " ans || ans="n"
    if [[ ! "$ans" =~ ^[Nn]$ ]]; then
      brew install ollama
      brew services start ollama || true
      OLLAMA="$(command -v ollama || true)"
    fi
  fi
  # Fallback (no brew, or the user declined brew): download the OFFICIAL, code-signed macOS app,
  # verify its signature (PSS), and install it. Only the official ollama.com host is used.
  if [ -z "$OLLAMA" ]; then
    ans=""
    read -r -p "Download the official Ollama app from ollama.com and install it? [Y/n] " ans || ans="n"
    if [[ ! "$ans" =~ ^[Nn]$ ]]; then
      TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
      dim "Downloading Ollama-darwin.zip…"
      curl -fsSL "https://ollama.com/download/Ollama-darwin.zip" -o "$TMP/Ollama.zip"
      ditto -x -k "$TMP/Ollama.zip" "$TMP" 2>/dev/null || unzip -q "$TMP/Ollama.zip" -d "$TMP"
      APP="$(/usr/bin/find "$TMP" -maxdepth 2 -name 'Ollama.app' -print -quit)"
      [ -n "$APP" ] || { warn "Download did not contain Ollama.app."; exit 1; }
      # PSS: refuse an app that fails Apple code-signature verification.
      if ! /usr/bin/codesign -v --deep --strict "$APP" 2>/dev/null; then
        warn "Downloaded Ollama failed code-signature verification — refusing to install it."; exit 1
      fi
      rm -rf /Applications/Ollama.app
      cp -R "$APP" /Applications/Ollama.app
      open -a /Applications/Ollama.app || true
      # The app bundles the CLI; also symlink is created by the app on first launch, but resolve now.
      for c in /Applications/Ollama.app/Contents/Resources/ollama /opt/homebrew/bin/ollama /usr/local/bin/ollama; do
        [ -x "$c" ] && OLLAMA="$c" && break
      done
    fi
  fi
  [ -n "$OLLAMA" ] || { echo "Ollama not installed. Get it from https://ollama.com/download, then re-run."; exit 1; }
else
  ok "Ollama found: $OLLAMA"
fi

# Ensure the server is up (start it if the API doesn't answer).
if ! curl -s --max-time 2 http://127.0.0.1:11434/api/version >/dev/null 2>&1; then
  dim "Starting the Ollama server…"
  (brew services start ollama >/dev/null 2>&1) || ("$OLLAMA" serve >/dev/null 2>&1 &)
  for _ in $(seq 1 15); do
    curl -s --max-time 2 http://127.0.0.1:11434/api/version >/dev/null 2>&1 && break
    sleep 1
  done
fi
VER="$(curl -s --max-time 2 http://127.0.0.1:11434/api/version 2>/dev/null || echo '')"
[ -n "$VER" ] && ok "Ollama server is running." || { warn "Could not reach the Ollama server on :11434."; exit 1; }
echo

# ── 4. pull the model ────────────────────────────────────────────────────────
bold "4 · Downloading $MODEL"
dim  "This can take a few minutes on first run."
"$OLLAMA" pull "$MODEL"
echo

# ── 5. configure the app (write the SAME settings the app reads) ─────────────
CFG_DIR="$HOME/Library/Application Support/GINEXUS"
mkdir -p "$CFG_DIR"
SETTINGS="$CFG_DIR/settings.json"
# Merge smartModel + setupComplete into settings.json (preserving any existing keys), so the app
# picks up the chosen daily driver and skips the first-run wizard. Atomic temp+rename.
python3 - "$SETTINGS" "$MODEL" <<'PY' || warn "Could not write settings.json — set the model in the app's Setup Assistant instead."
import json, os, sys
path, model = sys.argv[1], sys.argv[2]
try:
    with open(path) as f: cfg = json.load(f)
    if not isinstance(cfg, dict): cfg = {}
except Exception:
    cfg = {}
cfg["smartModel"] = model
cfg["setupComplete"] = True
tmp = path + ".tmp"
with open(tmp, "w") as f: json.dump(cfg, f, indent=2)
os.replace(tmp, path)
print("wrote", path)
PY

ok "Done — GINEXUS is configured to use $MODEL."
echo
bold "Next steps"
echo "  • Launch GINEXUS.app — it will use $MODEL as your daily driver (no further setup needed)."
echo "  • Manage or swap models any time from the Models panel in the app."
echo
