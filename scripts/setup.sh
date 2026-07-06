#!/usr/bin/env bash
# GINEXUS Setup — the terminal onboarding path (for users who cloned from GitHub).
# Detects your Mac's capabilities, installs the Ollama runtime if missing, and pulls a
# right-sized local model. Mirrors the in-app Setup Assistant's recommendation ladder so the
# result is identical whichever path you take.
#
# Usage:  bash scripts/setup.sh            (auto-recommend a model for this machine)
#         bash scripts/setup.sh <ollama-tag>   (pull a specific model instead)
#
# PSS: installs ONLY the official Ollama (Homebrew formula or ollama.com installer) — nothing else,
# no piped-shell from unknown hosts beyond Ollama's own signed installer, and it asks before installing.
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
  if command -v brew >/dev/null 2>&1; then
    read -r -p "Install it now with Homebrew? [Y/n] " ans
    if [[ ! "$ans" =~ ^[Nn]$ ]]; then
      brew install ollama
      brew services start ollama || true
      OLLAMA="$(command -v ollama)"
    else
      echo "Install it from https://ollama.com/download then re-run this script."; exit 1
    fi
  else
    echo "Homebrew not found. Install Ollama from https://ollama.com/download, then re-run this script."
    exit 1
  fi
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

# ── 5. record the choice for the app ─────────────────────────────────────────
CFG_DIR="$HOME/Library/Application Support/GINEXUS"
mkdir -p "$CFG_DIR"
# A hint file the app / launcher can read to preseed the daily driver.
printf '%s\n' "$MODEL" > "$CFG_DIR/smart_model.txt"

ok "Done."
echo
bold "Next steps"
echo "  • Launch GINEXUS.app — it will use $MODEL as your daily driver."
echo "  • Or run the core directly with:  GINEXUS_SMART_MODEL='$MODEL' <core> --uds <sock>"
echo "  • Manage or swap models any time from the Models panel in the app."
echo
