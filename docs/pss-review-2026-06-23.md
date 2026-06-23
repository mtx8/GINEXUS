# GINEXUS — PSS Review (Privacy · Safety · Security) of build-time downloads

**Date:** 2026-06-23 · **Scope:** everything pulled in to build GINEXUS this session (the local voice
stack + the robotics slicer). PSS framework (Nexus): nothing suspicious, official sources only,
verify all code, no malware. **Verdict: CLEAN.** Two CAUTION items, both with mitigations below; no
AVOID, no malware.

## Local runtime posture — verified in code

| Control | Status | Evidence |
|---|---|---|
| Services bind **loopback only** | ✅ | sidecars launch `uvicorn --host 127.0.0.1`; core uses a 0600 Unix socket (`SpineController.swift`) |
| **No data exfiltration** | ✅ | `audio-sidecar/server.py` has no outbound network calls; only first-run model pulls from Hugging Face, then fully local |
| **Models are exec-safe** | ✅ | all weights are `.safetensors` (tensor+JSON only, no code-exec on load); **0** `.bin`/`.pkl`/`.pt`/`.ckpt` across all 3 models |
| **Supply-chain integrity** | ✅ | `audio-sidecar/uv.lock` pins all 79 packages with **1,303 sha256 hashes** |
| **Secrets** | ✅ | per-launch ephemeral tokens; MCP creds in Keychain; never in logs/settings.json; voice logs are content-free + DEBUG-gated |

## Component verdicts

| Component | Source | License | Verdict |
|---|---|---|---|
| **mlx-audio 0.4.4** | PyPI · GitHub `Blaizzy/mlx-audio` (Prince Canuma, named MLX-community dev, 7.4k★) | MIT | **SAFE** |
| **parakeet-mlx 0.5.2** | PyPI · GitHub `senstella/parakeet-mlx` (946★, cited by S. Willison) | Apache-2.0 | **CAUTION (light)** — solo maintainer; pin + diff on upgrade |
| **mlx / mlx-lm / mlx-metal** | Apple's MLX | MIT | **SAFE** (official Apple) |
| **~79 mainstream PyPI deps** | transformers, librosa, soundfile, numba, scikit-learn, fastapi, uvicorn, huggingface-hub, sentencepiece… | permissive | **SAFE** (hash-pinned) |
| **Chatterbox MLX (TTS)** | HF `theoracleguy/...` — individual uploader; conversion of official MIT `ResembleAI/chatterbox` | tag says Apache-2.0 (upstream is MIT) | **CAUTION** — pin SHA, safetensors neutralizes exec risk; reconcile license; prefer self-host |
| **parakeet / S3Tokenizer (STT)** | HF `mlx-community` (semi-official: Awni Hannun/HF leads) | — | **SAFE** (semi-official; pin per-model SHA) |
| **PrusaSlicer 2.9.5** | Prusa Research, code-signed (TeamID `DKPB65N43Z`) | AGPL-3.0 | **SAFE** — used as **unmodified external CLI** only (copyleft does NOT reach GINEXUS code) |

## Model SBOM (pinned commit SHAs — all safetensors, 0 pickle)

| Model | HF repo | Commit SHA |
|---|---|---|
| TTS | `theoracleguy/Chatterbox-Multilingual-MLX-v2-fp16` | `70989e4faeec48daba16728f8bc9c041741fdf8f` |
| STT | `mlx-community/parakeet-tdt-0.6b-v3` | `ed2b7e8c15f9aaa0b5772e2efb986255eaef7e15` |
| Tokenizer | `mlx-community/S3TokenizerV2` | `e0c9886f0e1c35ae85b1f27277416fb19fc72bec` |

## Robotics tooling decision (PSS-driven)

- **OpenSCAD** — the Homebrew cask was a **deprecated Intel-only 2021 build that installed broken**;
  **removed, not used.** (For CAD-as-code, the safe path is OpenSCAD's *DSL* — a geometry language with
  no file/network/system access, unlike executing model-generated Python — sourced as a current
  **official** arm64 build from openscad.org, OR a sandboxed approach. To be re-decided before building.)
- **PrusaSlicer** — kept; official Prusa, signed, external-CLI only.

## Remediations (priority)

1. **Own the model supply chain.** Self-convert Chatterbox from the official **MIT** `ResembleAI/chatterbox`
   and host all weights under a GINEXUS-controlled HF org, pinned by the SHAs above — removes the only
   real provenance gap (individual uploader) and fixes the Apache-vs-MIT tag mismatch.
2. **Hash-pinned, safetensors-only CI.** `uv sync --frozen`; a CI gate that rejects any `.bin`/`.pkl`/`.ckpt`
   weight and requires HF pickle-scan-clean per SHA; never resolve unpinned at build time (typosquat/tamper).
3. **SBOM + license report + AGPL note.** Generate a CycloneDX SBOM for the 79 deps + 3 models; document in
   writing that PrusaSlicer (AGPL) is invoked only as an unmodified external CLI, never linked/bundled.

**Bottom line:** the GINEXUS build is PSS-clean — loopback-only, exec-safe model format, pinned
supply chain, reputable sources. The two CAUTION items are the individual Chatterbox uploader (mitigated
by safetensors; self-hosting recommended) and the AGPL slicer (clean as an external CLI). No malware.
