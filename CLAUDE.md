# GINEXUS — Project Context

**Read this first every session.** GINEXUS is the flagship, modular, native-macOS personal AI
agent for the Principal (Dreb) — the GiNexus startup foundation (Okinawa, MackTrax family).

## What it is
A native **SwiftUI "LLM-OS" orchestrator** that composes existing repos rather than reinventing
them. Local-by-default (Apple MLX), model-agnostic (auto/manual selector), MCP host, with tool
calling, email, web search, deep research, image/video generation, macOS Shortcuts + Home Assistant
IoT, and ingestion of sanitized personal-data exports.

## Repo strategy
- **This repo depends on `~/Desktop/MTX-NEXUS`** as the security + inference spine. **No rename.**
- Reuses: NexusForge (image/video MCP), Axiom (SwiftUI shell), ai-export-sanitizer (ingest),
  ai-iot-projects (telemetry), Hermes (always-on body + iPhone/Watch — later).

## Canonical design
- **Master design (v2):** `docs/superpowers/specs/2026-06-15-ginexus-master-design.md` — architecture,
  confirmed decisions, model *policy*, decomposition, security gates, risks. v2 = re-baselined to disk
  reality after a 4-lens adversarial review.
- **Model roster (dated, volatile):** `docs/model-roster-2026-06-15.md` — concrete model picks + licenses.
- Each sub-project gets its own `spec → plan → implementation` cycle.
- **v1 (daily driver) = SP0 → SP1 → SP1.5 → SP2 → SP3-slim → SP4-slim** (chat + memory + web + terminal).
  SP2-alone is only the integration smoke-test. v1 acceptance: *"researched X, wrote it to a file,
  remembered it the next day."*

## Confirmed decisions (2026-06-15)
1. Inspiration "Openclaw" = **OpenClaw (Steinberger)** patterns (harden past its defaults).
2. "Mila" = **MemPalace patterns only** → build native two-tier memory.
3. Smart home = **Home Assistant** (local MCP + WebSocket + REST).
4. Scope = **personal-first, product-clean** → Apache-2.0/MIT default model roster.

## Default model stack (Apple M2 Ultra, 192GB) — all commercial-safe
Chat/agent: **Qwen3-30B-A3B-Instruct-2507** · escalate **gpt-oss-120b** · code **Qwen3-Coder-30B-A3B**
· router **Qwen3-4B** · VLM **Qwen3-VL-8B** · embed **Qwen3-Embedding-0.6B** · rerank
**Qwen3-Reranker-0.6B** · image **Z-Image-Turbo** (mflux) · video **Wan2.2-TI2V-5B** (local batch) +
API for interactive · STT **Parakeet-TDT-0.6b-v3** · TTS **Kokoro-82M**. Router = LiteLLM-style
OpenAI-compatible, Tier 0 Apple FM / Tier 1 MLX / Tier 2 API. **Avoid FP8 (Metal crash class).**

## Hard rules
- **NEVER access `~/Library/Mobile Documents/` (iCloud)** — global HARD RULE #1.
- All OS calls (Calendar/Contacts/Mail/Accessibility) originate in the **signed Swift app**, never
  the Python sidecar (TCC attribution). Non-sandboxed, Hardened-Runtime, notarized Developer-ID.
- HITL (biometric approval) on all irreversible/external actions: email send, terminal mutations,
  IoT locks/garage/alarm, spend, external comms.
- No username in deliverable paths — use `~`/`$HOME`.
- Plan before building; agent-team review at each gate (architecture → code → security).
