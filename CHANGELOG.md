# GINEXUS — Changelog

Progress log for the GINEXUS personal AI agent (GiNexus startup foundation). Newest first.
Format loosely follows [Keep a Changelog](https://keepachangelog.com/). Each entry maps to a
merged PR on `main` (repo `mtx8/GINEXUS`, private). Architecture, decisions, and the deep
technical record live in `docs/superpowers/specs/` and `docs/adr/`; this file is the high-level
running history.

## Status snapshot

- **v1 acceptance test PASSES** end-to-end on the Rust core: research (web_fetch) → write-to-file
  (HITL approval) → remember (persistent memory), with cross-language (Swift↔Rust) approval-token parity.
- **8 Rust crates** — security, agent, gateway, mcp, memory, skills, sanitize, server. **97 Rust tests.**
- **App**: self-contained signed `GINEXUS.app` (embeds the Rust core), token-streaming chat with
  content-aware rendering, capability menu, smart attachments, in-app model manager, memory browser.
- **Live memory**: the operator's full ChatGPT history — 3,779 sanitized facts with 768-dim embeddings.
- **Default model**: Qwen3-30B-A3B-Instruct-2507 (Apache-2.0) via Ollama.

---

## 2026-06-17 — UI functional pass + model management

### Model management
- **#17 — Model manager: refresh, uninstall, cards, installed-in-picker.** Refresh button to
  re-read the installed list; per-model uninstall (confirm → frees disk, proxies Ollama
  `DELETE /api/delete`, audited); modern hover-animated cards showing size + quantization and a
  disk total; freshly-pulled models now appear in the top-right model picker immediately
  (`fetchModels` merges Auto + roster tiers + installed, deduped by base name).
- **#16 — Live Hugging Face type-ahead.** As you type in the pull field, matching GGUF models
  stream in from the Hugging Face search API (`/v1/hf/search`, debounced), ranked by downloads.
- **#15 — In-app model downloader.** Pull models from the Ollama registry or Hugging Face GGUF
  (`hf.co/<org>/<repo>:<QUANT>`) without leaving the app. Core proxies Ollama `POST /api/pull`
  (NDJSON → SSE progress, resumable, audited); MODELS header button → manager sheet with suggested
  Apache-licensed picks, a progress bar, and an "upgrade Ollama for vision" banner.
  Vision pick researched: **Qwen3-VL-30B-A3B-Instruct** (needs Ollama ≥ 0.12.7; currently 0.11.4 → upgrade first).

### Chat input + attachments
- **#14 — Smart Attach.** The Attach option detects file type and extracts content on-device:
  PDF (PDFKit), rich documents (NSAttributedString), plain text/code (UTF-8), images, and video
  (AVKit) — content capped and sent as context for that turn. (Image *understanding* still needs a VLM pulled.)
- **#13 — "+" bare icon inside the input pill** (no filled box), merged into one input HStack.
- **#12 — "+" input menu.** Replaced the capability bar with the modern chat pattern: a "+" button
  left of the message box opens "Do with your message" (Perspectives / Research / Create image) and
  "Attach" (file / image / Import AI data). Import AI data runs the sanitizer by default.
- **#11 — Plain-language capability labels** (Council → Perspectives, Image → Create image);
  Build Profile moved into the Memory browser.

### Reply rendering + streaming
- **#10 — Capability surfacing + memory browser.** One-tap Council / Research / Image / Profile;
  header MEMORY button → sheet with core blocks (the self-model profile), fact count, recent facts,
  and a semantic search field over the archive (`GET /v1/memory`, `POST /v1/memory/search`).
- **#9 — Blinking ember streaming cursor** (matches the SEND button color).
- **#8 — Fix: SSE drain deadlock** that left the stream connection open (SEND got stuck after the
  first reply) — drain now breaks on the `done` frame.
- **#7 — Token-by-token streaming**, end to end: gateway `complete_with_tools_streaming` (SSE deltas
  + tool-call accrual, `<think>` suppressed) → loop `run_streaming` → server `/v1/agent/stream` →
  Swift UDS SSE client → live bubble (plain + cursor while streaming, MarkdownReply on finalize).
- **#6 — Content-aware reply rendering** (`MarkdownReply.swift`): prose, headings, ember
  bullets/numbers, code → recessed panel with language tag + Copy, images inline, video via AVKit,
  tables aligned. User messages stay verbatim.

### Packaging
- **#5 — Fix: deploy the app into the project folder** (`~/Desktop/GINEXUS/GINEXUS.app`), not loose on Desktop.
- **#4 — Double-clickable installable `GINEXUS.app`** with a brand icon (abstract chrome nexus
  starburst on ink-900, no wordmark) deployed to `/Applications` + the repo folder; reliable relaunch
  (fixed a stale-UDS-socket bug that blocked re-spawn).

## 2026-06-17 — Multi-agent orchestration + import performance

- **#3 — Multi-agent orchestration + SP8 + Obsidian.** Concurrent subagent fan-out (`delegate`,
  `futures::join_all`), Council/Group mode (divergent personas → chair synthesis), deep research
  (decompose → parallel web workers → cited synthesis), self-model consolidation
  (`POST /v1/consolidate` → durable profile block), autonomy HITL⇄AUTO toggle, per-run
  synthetic-call budget, and Obsidian vault tools (auto-detected at `~/Desktop/AGENTS`).
- **#1 — Import performance.** Batch embeddings + hardened realignment dropped a 736-fact shard
  from a >400s timeout to ~5s (~83×); enabled loading the operator's full ChatGPT history into memory.

## 2026-06-15 / 06-16 — Core engine, app, and capabilities (pre-changelog)

Recorded in the master design and project memory; summarized here for continuity:

- **Rust core engine live** (ADR 0003, non-negotiable): Swift app → UDS+token → Rust `ginexus-core`
  → HTTP → Ollama/MLX. Crates: security (approval/audit/killswitch/HITL), agent (HITL-gated ReAct
  loop), gateway (router + model client), mcp (stdio host), memory (two-tier), skills (hot-loadable
  plugins), sanitize (in-core PII scrub), server (UDS+token JSON/SSE).
- **v1 acceptance** passed: research → write (HITL) → remember.
- **SP1-tail**: production model Qwen3-30B-A3B-Instruct-2507 + auto/manual selection.
- **SP3**: two-tier semantic memory (cosine vector recall, nomic-embed) + injection-quarantined ingestion.
- **SP5**: deep macOS integration bridge (TCC-correct OS tools) + Touch ID biometric approval sheet.
- **SP6**: local image generation (mflux + Z-Image-Turbo media sidecar).
- **Skills platform**: hot-loadable command/MCP plugins, security-hardened executor.
- **XcodeGen project** with a sandbox-proof Rust embed (cargo in the scheme pre-action + native
  CopyFiles with CodeSignOnCopy).
