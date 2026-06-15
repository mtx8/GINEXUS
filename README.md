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
**Design phase.** See the master design:
[`docs/superpowers/specs/2026-06-15-ginexus-master-design.md`](docs/superpowers/specs/2026-06-15-ginexus-master-design.md).

Built as 10 sub-projects (SP0–SP9); first build is **SP0 → SP1 → SP2**.

## Architecture (one line)
Native SwiftUI shell (signed, non-sandboxed, notarized) owns OS calls + MCP host → Python/uv
FastAPI sidecar runs MLX/mflux inference over UDS+Keychain → LiteLLM-style OpenAI-compatible router
(Tier 0 Apple FM / Tier 1 MLX local / Tier 2 API) → tools as MCP, two-tier local memory, deep
macOS + Home Assistant integration.

See [`CLAUDE.md`](CLAUDE.md) for full session context.
