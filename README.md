# GINEXUS

> The best, most advanced **modular personal AI agent for macOS** — local-by-default,
> audit-everything, you-own-your-brain. GiNexus startup foundation.

Native SwiftUI "LLM-OS" orchestrator running open-source models on Apple Silicon (MLX-first) with
an auto/manual model selector. Tool calling · email · web search · deep research · image & video
generation · macOS Shortcuts + Home Assistant IoT · MCP / local API / terminal · ingestion of
sanitized personal-data exports (ChatGPT/Claude/Gemini/Perplexity).

**Not greenfield.** GINEXUS is the orchestrator head over a spine and subsystems already built:
`MTX-NEXUS` (security + inference spine, dependency) · `NexusForge` (media) · `Axiom` (SwiftUI
shell) · `ai-export-sanitizer` (ingest) · `Hermes` (always-on body, later).

## Status
**v1 daily-driver works end-to-end** (acceptance: *researched X → wrote it to a file → recalled it
the next session*). The core engine is **Rust** (`core/` — crates: security, agent, gateway, mcp,
memory, skills, sanitize, server; 93 tests green). Python is the reference impl only, retired from
the runtime path (ADR 0003).

Shipped: SP0 security spine · SP1 model router · SP1.5 notarized self-contained app (Rust core
embedded + signed) · SP2 agent loop + MCP host · SP4 web + safe terminal · SP3 two-tier memory +
injection-quarantined ingestion · **semantic recall** (Rust-native vector cosine over Ollama
embeddings) · SP5 macOS integration (Shortcuts/EventKit + Touch-ID approval) · SP6 image generation ·
hot-loadable **skills** · **subagents** (concurrent fan-out) · **Council/Group mode** (parallel
persona deliberation → synthesis) · **deep research** (decompose → parallel research → cited report) ·
**scheduler/heartbeat** · **autonomy modes** (HITL default + fully-autonomous + non-overridable hard
gate, toggled from the UI) · **self-model consolidation** (`/v1/consolidate` distills long-term
memory into a durable always-in-context profile). The operator's **real ChatGPT export (3,779
user-message facts** across 11 shards) is sanitized + embedded into quarantined memory in a measured
25s (batched embeddings); consolidation distilled it into an accurate operator profile in 7.6s.

Remaining: SP7 Home Assistant IoT · SP8 self-improvement loop · SP9 Hermes always-on
body + iPhone/Watch. See the master design:
[`docs/superpowers/specs/2026-06-15-ginexus-master-design.md`](docs/superpowers/specs/2026-06-15-ginexus-master-design.md).

## Architecture (one line)
Native SwiftUI shell (signed, non-sandboxed, notarized) owns OS calls + Touch-ID approval → UDS +
HMAC-token → **Rust `ginexus-core`** (agent loop, model router, MCP host, two-tier memory + ingest
sanitizer, kill switch, hash-chain audit) → HTTP → local model servers (Ollama / MLX; optional
Python media sidecar for mflux). Auto/manual model selector (fast/smart/embed/code tiers).

See [`CLAUDE.md`](CLAUDE.md) for full session context.
