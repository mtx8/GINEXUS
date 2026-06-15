# GINEXUS — Master Design (Umbrella Architecture & Decomposition)

**Status:** Draft — awaiting Principal review
**Date:** 2026-06-15
**Owner:** Dreb (Principal) · authored via Conductor + 27-agent research sweep
**Brand:** GiNexus (the Okinawa AI startup, MackTrax family)

> This is the **umbrella spec**. GINEXUS is too large for one implementation plan, so this
> document fixes the architecture, the locked decisions, the model stack, and the
> **sub-project decomposition**. Each sub-project gets its own `spec → plan → implementation`
> cycle. The build order is defined in §8.

---

## 1. Vision & Positioning

GINEXUS is the **best, most advanced, modular personal AI agent for macOS** — local-by-default,
audit-everything, you-own-your-brain. It runs open-source models on Apple Silicon (MLX-first)
with an auto/manual model selector, does tool-calling, email, web search, deep research, image &
video generation, taps into **macOS Shortcuts** and **home IoT**, and exposes itself over **MCP,
a local API, and a terminal**. It ingests the Principal's **sanitized** personal-data exports
(ChatGPT/Claude/Gemini/Perplexity) into a private, inspectable memory.

**Positioning statement:** *the most deeply macOS-integrated, privacy-first, modular personal AI
agent — local-by-default, auditable, model-agnostic.*

| Compared to | GINEXUS edge |
|---|---|
| OpenClaw / Odysseus (web/Electron, cross-platform) | **Native macOS depth** (App Intents, Shortcuts, IoT via HA, Keychain, Watch) + hardened audit/kill-switch posture |
| Jan / Goose (Rust core + WebView head) | Same thin-core philosophy but **fully native SwiftUI**, plus personal-data ingestion + media generation |
| LM Studio / Msty (GUI runtimes) | **Agentic** (tool loop, memory, deep research, IoT) — not just a chat front-end |
| Apple Intelligence (closed) | **Model choice** (local MLX + any API), full tool reach, on-device fine-tuning, open auditable architecture |

---

## 2. Confirmed Decisions (Principal, 2026-06-15)

1. **"Openclaw" = OpenClaw (Steinberger)** — local-first, always-on personal agent. Borrow its
   Gateway control-plane, session-as-trust-boundary, markdown-skills, and approval-gated
   self-authoring patterns. **Harden well past its defaults** (it shipped a one-click RCE,
   CVE-2026-25253, and a poisoned skill registry).
2. **"Mila" = MemPalace, patterns only** — build GINEXUS memory **natively** (two-tier,
   `sqlite-vec`/LanceDB) borrowing MemPalace's verbatim-first storage + method-of-loci hierarchy.
   Do **not** depend on its disputed benchmarks.
3. **Smart home = Home Assistant** — consume HA's local MCP server (Streamable-HTTP) + WebSocket
   live state + REST commands, scoped bearer token in Keychain, explicit entity allow-list,
   **mandatory human-confirm** for locks/garage/alarm routed to iPhone/Watch.
4. **Scope = personal-first, product-clean** — build for the Principal, but hold to
   **commercial-safe model licenses** (Apache-2.0 / MIT default roster) and a clean architecture
   so it can become the GiNexus product later.

---

## 3. Locked Autonomous Decisions (research-validated)

| Area | Decision |
|---|---|
| Repo strategy | **New `GINEXUS` repo** that depends on `MTX-NEXUS` as the inference/security backend package. **No rename** — preserve the agent-validated security work. |
| Front-end | **Native SwiftUI**. Do not fork Electron/web. Lift Axiom's `AppState`/`PersistenceService`/design system + `TerminalService`+`SafetyGuard`. |
| Tool bus | **MCP host first.** Native capabilities (email, Shortcuts, IoT, terminal, gen) are internal MCP servers/tools; external MCP servers consumed uniformly. |
| Inference | **MLX-first + GGUF fallback** behind a **LiteLLM-style OpenAI-compatible router**. Both in-Swift `mlx-swift` and a Python/uv sidecar (`mlx-lm`/mflux) behind one **Engine interface**, routed per task. |
| Model tiering | **Tier 0** Apple Foundation Models (offline/extraction/routing) → **Tier 1** MLX local heavy → **Tier 2** API. Route on difficulty × privacy × connectivity. |
| Agent loop | **Minimal, model-driven** (native reasoning + native tool calls), with hard **iteration/tool-call ceilings**, sandboxing, and **HITL on irreversible actions**. |
| Memory | **Native two-tier** (always-in-context core blocks + mem0/Letta-style fact extraction to local vector store), CoALA-tagged, nightly consolidation, **human-inspectable flat files** (git-diffable), aligned with the `~/.claude/MEMORY.md` convention. |
| Autonomy | **Per-capability dial** (suggest → auto-with-approval → autonomous-with-audit). Read/research = autonomous; irreversible/external (money, comms, destructive, locks) = approval. |
| Self-improvement | **Strictly approval-gated + eval-gated.** Self-authored skills + system-prompt-learning notes staged to a dir; nothing activates without Principal approval. |
| Multi-model | **Council/Group Mode** with a **neutral separate judge** (never member self-voting — PewDiePie's collusion lesson) + explicit opt-in convergence + Blind Compare. |
| Distribution | **Non-sandboxed, Hardened-Runtime, notarized Developer-ID** build (direct download) for deep automation. Optional sandboxed App-Store "lite" later. **All OS calls originate in the signed Swift app** (TCC attribution rule) — the Python sidecar never touches Calendar/Contacts/Mail. |
| Sequencing | **macOS daily-driver first.** Hermes always-on body + iPhone/Watch as a later sub-project. |

---

## 4. Existing-Asset Landscape

There is **no `GINEXUS` directory yet** (created today). GINEXUS is an **umbrella orchestrator,
a strict superset of MTX-NEXUS's scope**, that composes existing parts.

| Repo | State | Role in GINEXUS |
|---|---|---|
| **MTX-NEXUS** (`~/Desktop/MTX-NEXUS`) | Phase 0–1, ~70% | The **security + IPC + inference spine** (UDS+Keychain token, hash-chained audit, 3-tier kill switch, supply-chain pinning, sandbox-exec, iCloud guard). GINEXUS depends on it as a package. |
| **Hermes** (`~/Desktop/Hermes`) | Blueprint, 0 code | The **always-on headless body** + iPhone/Watch control surface contract. Same spine, different head. |
| **NexusForge** (`~/Desktop/NexusForge`) | Phase 2, builds green | The **image/video subsystem** — already an MCP server (10 tools), sidecar-supervision pattern, model LRU pool, job queue. |
| **Axiom** (`~/Desktop/Axiom`) | MVP shipped | **SwiftUI shell building blocks** — `TerminalService`+`SafetyGuard`, `PersistenceService`, `AppState`, dark design system, sidebar nav. |
| **ai-export-sanitizer** (`~/Desktop/ai-export-sanitizer`) | Beta v0.2 | The **mandatory ingest pre-processor** — PII/secret redaction + leak verification for ChatGPT/Claude/Gemini/Perplexity exports. |
| **ai-iot-projects** (`~/Desktop/ai-iot-projects`) | Project 01 prod-ready | Telemetry/monitoring ML patterns (not home *control* — that is new via HA). |
| **Nexus/NexusBI** (`~/Desktop/Nexus`) | Beta ~30–40% | Optional analytics subagent — **borrow patterns** (Swift-Rust FFI, conversational UI), don't adopt wholesale (1.6GB xcframework, iCloud-coupled). |

**Mental model:** MTX-NEXUS = kernel + security spine · Hermes = always-on deployment ·
NexusForge/NexusBI/ai-iot = capability subsystems (MCP tools) · **GINEXUS = the orchestrator +
native daily-driver head** (LLM-OS kernel).

---

## 5. High-Level Architecture

```
┌──────────────────────────────────────────────────────────────────────┐
│  HEADS (thin clients)                                                  │
│  • GINEXUS.app — native SwiftUI (daily driver, deep macOS integration) │
│  • iPhone + Apple Watch (HermesKit: approve/deny, voice, kill switch)  │  ← later
│  • CLI + local API + MCP (Software 3.0: human / program / agent)       │
└───────────────┬──────────────────────────────────────────────────────┘
                │  UDS + per-launch Keychain bearer token (MTX-NEXUS spine)
┌───────────────▼──────────────────────────────────────────────────────┐
│  GINEXUS ORCHESTRATOR ("LLM-OS kernel")                                │
│  • Agent loop (model-driven, native tool-calling, iteration ceilings)  │
│  • Workflow primitives (chain / route / parallel / orchestrator-worker)│
│  • Autonomy dial per capability (suggest → approve → autonomous+audit)  │
│  • Session manager (session-as-trust-boundary, per-session Lane Queue) │
│  • Approval queue (biometric, signed replay-proof tokens — Hermes)     │
│  • 3-tier kill switch + append-only hash-chained audit (MTX-NEXUS)     │
└──┬─────────────┬─────────────┬──────────────┬───────────────┬─────────┘
   │             │             │              │               │
┌──▼───────┐ ┌───▼────────┐ ┌──▼─────────┐ ┌──▼──────────┐ ┌──▼──────────┐
│ MODEL    │ │ TOOL / MCP │ │ MEMORY     │ │ macOS / OS  │ │ MEDIA / SUBS │
│ ROUTER   │ │ BUS (host) │ │ LAYER      │ │ INTEGRATION │ │ (MCP tools)  │
│ Tier0    │ │ stdio+SSE+ │ │ core blocks│ │ App Intents │ │ NexusForge   │
│ Apple FM │ │ Streamable │ │ + fact-    │ │ (signed app)│ │ Home Assist. │
│ Tier1    │ │ -HTTP      │ │ extraction │ │ Shortcuts   │ │ Deep Research│
│ MLX local│ │ native     │ │ vector     │ │ AppleScript │ │ Council/     │
│ Tier2    │ │ tools AS   │ │ (sqlite-   │ │ Accessibility│ │ Group Mode  │
│ API      │ │ MCP servers│ │  vec/Lance)│ │ EventKit    │ │ (judge ≠     │
│          │ │ email,term,│ │ + LLM-Wiki │ │ Contacts    │ │  member)     │
│ LiteLLM  │ │ shortcuts, │ │ (/raw→/wiki│ │ Mail/Msgs   │ │              │
│ OpenAI-  │ │ iot, gen,  │ │  over vault│ │ Spotlight   │ │              │
│ compat   │ │ research   │ │ + Skills   │ │ TWO TARGETS │ │              │
└──────────┘ └────────────┘ └────────────┘ └─────────────┘ └─────────────┘
                │
        ┌───────▼────────────────────────────────────────────┐
        │ INGEST: ai-export-sanitizer → sanitized exports →   │
        │ /raw → wiki-maintainer agent → /wiki + memory facts │
        └─────────────────────────────────────────────────────┘
```

**Process model:** Native **SwiftUI shell** (signed, non-sandboxed, notarized Developer-ID) owns
all OS calls + the MCP host. A **Python/uv FastAPI sidecar** (the MTX-NEXUS backend) runs
MLX/mflux/heavy inference, supervised as a child process over UDS+Keychain token (NexusForge
`SidecarManager` pattern). **All Calendar/Contacts/email/Accessibility calls originate in the
signed Swift app, never the sidecar** (TCC attribution rule).

---

## 6. Model Stack (Apple M2 Ultra, 192GB) — product-clean default roster

All defaults are **Apache-2.0 / MIT** (commercial-safe). Re-scan the HF Hub before locking
(researched June 2026; newer generations exist).

| Capability | Default model | HF repo | Runtime | License |
|---|---|---|---|---|
| Chat & reasoning | **Qwen3-30B-A3B-Instruct-2507** | `Qwen/Qwen3-30B-A3B-Instruct-2507` (`mlx-community/...-4bit`) | MLX / Ollama | Apache-2.0 |
| Agentic tool-calling | Qwen3-30B-A3B (+ **Qwen3-Coder-30B-A3B** code lane) | `Qwen/Qwen3-Coder-30B-A3B-Instruct` | MLX, smolagents/tiny-agents | Apache-2.0 |
| Hard reasoning (escalate) | **gpt-oss-120b** (~63GB MXFP4, hot-load) | `openai/gpt-oss-120b` | MLX / Ollama | Apache-2.0 |
| Fast/glue lane | gpt-oss-20b · **Qwen3-4B-Instruct-2507** (router) | `openai/gpt-oss-20b`, `Qwen/Qwen3-4B-Instruct-2507` | MLX / Ollama | Apache-2.0 |
| Vision (VLM) | **Qwen3-VL-8B-Instruct** (escalate 30B-A3B) | `Qwen/Qwen3-VL-8B-Instruct` | mlx-vlm | Apache-2.0 |
| Embeddings | **Qwen3-Embedding-0.6B** (8B for high-stakes) | `Qwen/Qwen3-Embedding-0.6B` | MLX / Ollama | Apache-2.0 |
| Reranker | **Qwen3-Reranker-0.6B** | `Qwen/Qwen3-Reranker-0.6B` | MLX | Apache-2.0 |
| Image gen | **Z-Image-Turbo** (Qwen-Image-2512 for CJK text) | `Tongyi-MAI/Z-Image-Turbo` | mflux (MLX) / ComfyUI | Apache-2.0 |
| Video gen | **Wan2.2-TI2V-5B** (local batch) → **API for interactive** | `Wan-AI/Wan2.2-TI2V-5B-Diffusers` | ComfyUI-GGUF / diffusers-MPS | Apache-2.0 |
| STT | **Parakeet-TDT-0.6b-v3** (Whisper-v3-turbo for CJK) | `mlx-community/parakeet-tdt-0.6b-v3` | MLX | CC-BY-4.0 (attribute NVIDIA) |
| TTS | **Kokoro-82M** (Chatterbox for clone/Japanese) | `mlx-community/Kokoro-82M-bf16` | MLX / CoreML-ANE | Apache-2.0 |

**Always-resident working set** ≈ 40–45 GB (Qwen3-30B + gpt-oss-20b + Qwen3-4B router + embed/rerank
0.6B + Qwen3-VL-8B + Parakeet + Kokoro), leaving ~125 GB to hot-swap gpt-oss-120b (~63 GB) and run
media jobs. **Co-residency is what the 192GB box buys.**

**Auto-mode heuristics:** latency-critical → fast tier · standard → resident default tier · hard
reasoning/verification → high-quality tier (hot-load) · video interactive → API, batch → local Wan ·
manual override always available per capability.

**Hard engineering rules:** **avoid FP8 everywhere** (Metal lacks `Float8_e4m3fn` — #1 crash class);
strict JSON-schema validation on all tool calls; consolidate to one local OpenAI-compatible server.

### License policy (product-clean)
- **Default roster = Apache-2.0/MIT only.** Attribute NVIDIA for Parakeet (CC-BY-4.0).
- **Internal-only / gated (buy license to ship):** FLUX.1/2-dev, FLUX-Krea, FLUX.2-klein-9B.
- **Revenue-capped:** SD3.5 (Stability Community, terminates >$1M ARR).
- **Restricted (legal review before commercial):** LTX-Video, HunyuanVideo, CogVideoX-5b, Gemma family, Llama community license, Qwen2.5-VL-72B, InternVL3 1B/2B/8B.
- **Avoid in product:** jina-v3 (NC), xLAM-2 (NC), XTTS-v2 (NC), Spark-TTS (NC), Moonshine non-English flavors (NC).

---

## 7. Cross-Cutting Security & Safety Gates

These must hold before any autonomy level above "suggest":

1. **Close MTX-NEXUS open gaps (blocking):** SEC-1 cryptographically anchor the audit hash-chain
   (HMAC/Keychain-signed head); SEC-3 guarantee non-syncable token storage (`SecItemAdd`,
   Swift-owned Keychain); enforce **monotonic kill-switch escalation**; finish + execution-test the
   sandbox-exec SBPL profile.
2. **Default-deny tool policy** + scoped sessions. Imported skills, sanitized exports, and
   device/email/sensor text are all **prompt-injection vectors** — treat as untrusted.
3. **HITL on irreversible/external actions**: email send, terminal mutations, IoT locks/garage/alarm,
   any spend, any external comms → preview + biometric approval routed to iPhone/Watch.
4. **Self-improvement** behind mandatory approval queue + eval-gated promotion + diffs.
5. **Iteration/tool-call ceilings** + sandboxed execution for the agent loop.
6. **iCloud HARD RULE** preserved end-to-end: nothing under `~/Library/Mobile Documents/` is ever read/written.

---

## 8. Sub-Project Decomposition (build order)

Each is an independent `spec → plan → implementation` cycle. Ship the kernel + one tool, then expand.

| # | Sub-project | Outcome |
|---|---|---|
| **SP0** | **Harden & finish the spine (MTX-NEXUS)** | Close SEC-1/SEC-3, monotonic kill-switch, sandbox profile, model-pull scripts → trustworthy local inference + security backend. *(No rename; keep as package.)* |
| **SP1** | **Model Router + Engine abstraction** | LiteLLM-style OpenAI-compatible router, nanochat-style Engine (prefill/decode/stream), Tier 0/1/2, macOS-native "Cookbook" model installer (scan RAM, score fit, one-click pull+serve). FP8 excluded. |
| **SP2** | **GINEXUS Kernel: SwiftUI shell + agent loop + MCP host** | Thin orchestrator. Signed non-sandboxed app, sidecar supervision over the spine, model-driven agent loop (ceilings, sandbox, HITL), MCP host (stdio+SSE+Streamable-HTTP), session manager + Lane Queue. **Working chat + single-tool agent end-to-end.** |
| **SP3** | **Memory + personal-data ingestion** | `ai-export-sanitizer` → `/raw` → LLM-Wiki maintainer agent → `/wiki` over the Obsidian vault; two-tier memory (core blocks + fact extraction to sqlite-vec/LanceDB), CoALA-tagged, hybrid retrieval, nightly consolidation. Human-inspectable, git-diffable. |
| **SP4** | **Core tool suite (shared-domain dual adapters)** | Each capability written once (typed Swift) → wrapped as App Intent **and** MCP tool: web search/fetch, terminal (Axiom `SafetyGuard`, diff-approval), email (preview-approval), file ops. Autonomy dial per tool. |
| **SP5** | **Deep macOS / OS integration** | App Intents + AppEntity + IndexedEntity (Spotlight/Shortcuts/Siri), `shortcuts` CLI registry, AppleScript/Apple Events, Accessibility AX fallback, EventKit/Contacts/Mail/Messages (all in signed app), Focus-awareness, permissions dashboard + TCC re-polling. **The native-macOS differentiator.** |
| **SP6** | **Media generation subsystem** | Adopt NexusForge via MCP tools; mflux local image engine (FP8-excluded registry: Z-Image-Turbo/Qwen-Image/FLUX.2-klein-4B); video defaults to API + opt-in local Wan with time warnings. Default artifact status `draft` (MackTrax review-queue). |
| **SP7** | **Smart-home / IoT control (Home Assistant)** | Consume HA local MCP (Streamable-HTTP) + WebSocket live state + REST; scoped Keychain token; explicit entity allow-list; **mandatory human-confirm for locks/garage/alarm** routed to iPhone/Watch. Optional ai-iot telemetry monitoring. |
| **SP8** | **Self-improvement + multi-model Council/Group Mode** | Agent Skills (SKILL.md folders, progressive disclosure); self-authored skills + prompt-learning behind approval queue + eval-gate + diffs; Council (N = model+role, Parallel/Round-Robin) with **neutral separate judge** + opt-in convergence + Blind Compare; eval harness from day one. |
| **SP9** | **Always-on body + companion clients (Hermes convergence)** | Headless GINEXUS spine on a dedicated Mac (launchd, Tailscale+Caddy, no public ports) + iPhone/Apple Watch approval/voice/kill apps (HermesKit, biometric signed tokens, APNs/ntfy). **"One brain, many heads."** |

**Recommended first build: SP0 → SP1 → SP2** (a trustworthy spine, a working router, then the
kernel that produces a usable chat+single-tool agent). SP3/SP4 follow to make it genuinely useful.

---

## 9. Risks

1. **Scope explosion** → mitigated by the SP decomposition; ship kernel + one tool first.
2. **TCC / sandbox fork** → decided (non-sandboxed Developer-ID); consolidate OS calls in the signed app.
3. **Local tool-calling reliability** → schema validation + approval; route hard tool chains to API/higher tier.
4. **Untrusted input everywhere** → default-deny, sandbox, scoped sessions.
5. **Self-improvement runaway** → approval + eval-gate + diffs + rollback.
6. **MTX-NEXUS open security gaps** → SP0 is blocking before autonomy > suggest.
7. **Local video not production-ready** → API default, local batch only; don't headline it.
8. **MemPalace benchmarks disputed** → patterns only, native build, re-benchmark.

---

## 10. What's Next

1. **Principal reviews this master spec.**
2. On approval → write the **SP0 spec** (harden the MTX-NEXUS spine) and invoke `writing-plans`.
3. Proceed SP0 → SP1 → SP2 with agent-team review at each gate (architecture review, code review,
   security audit) per the Principal's standing process.
