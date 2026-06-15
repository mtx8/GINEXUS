# GINEXUS — Master Design (Umbrella Architecture & Decomposition)

**Status:** Draft v2 — awaiting Principal review
**Date:** 2026-06-15
**Owner:** Dreb (Principal) · authored via Conductor + 27-agent research sweep + 4-lens adversarial review
**Brand:** GiNexus (the Okinawa AI startup, MackTrax family)

> **v2 changelog:** Re-baselined against what actually exists on disk (a 4-lens review panel verified
> every code claim). Corrected overstated asset maturity, locked the IPC contract, pulled three
> safety primitives forward, inserted a packaging spike (SP1.5), re-scoped SP0/SP1, cut the
> dual-engine mandate, demoted Tier-0, and redefined the v1 finish line. Concrete model picks moved
> to `docs/model-roster-2026-06-15.md` (volatile, dated).

> This is the **umbrella spec**. GINEXUS is too large for one implementation plan, so this document
> fixes the architecture, the locked decisions, the model *policy*, and the **sub-project
> decomposition**. Each sub-project gets its own `spec → plan → implementation` cycle. Build order
> and the dependency DAG are in §8.

---

## 1. Vision & Positioning

GINEXUS is the **best, most advanced, modular personal AI agent for macOS** — local-by-default,
audit-everything, you-own-your-brain. It runs open-source models on Apple Silicon (MLX-first) with
an auto/manual model selector, does tool-calling, email, web search, deep research, image & video
generation, taps into **macOS Shortcuts** and **home IoT**, and exposes itself over **MCP, a local
API, and a terminal**. It ingests the Principal's **sanitized** personal-data exports
(ChatGPT/Claude/Gemini/Perplexity) into a private, inspectable memory.

**Positioning:** *the most deeply macOS-integrated, privacy-first, modular personal AI agent —
local-by-default, auditable, model-agnostic.* (This is why the v1 finish line in §8 is **not** a
chat front-end — that would be LM Studio parity, which this positions above.)

---

## 2. Confirmed Decisions (Principal, 2026-06-15)

1. **"Openclaw" = OpenClaw (Steinberger)** — borrow its Gateway control-plane,
   session-as-trust-boundary, markdown-skills, and approval-gated self-authoring. **Harden well past
   its defaults** (it shipped a one-click RCE, CVE-2026-25253, and a poisoned skill registry).
2. **"Mila" = MemPalace, patterns only** — build memory **natively** (two-tier, `sqlite-vec`/LanceDB)
   borrowing its verbatim-first + method-of-loci ideas. Do **not** depend on its disputed benchmarks.
3. **Smart home = Home Assistant** — consume HA's local MCP server + WebSocket + REST, scoped token
   in Keychain. (HITL model corrected to default-confirm allow-list — see §7.)
4. **Scope = personal-first, product-clean** — build for the Principal, but hold to commercial-safe
   model licenses (Apache-2.0/MIT default roster) and a clean architecture so it can become the
   GiNexus product later.

### Decisions made post-review (2026-06-15)
- **SEC-3 ownership:** the **signed Swift app owns the Keychain write in SP0** via a small
  `KeychainStore` (`SecItemAdd`, `kSecAttrSynchronizable=false`, `AccessibleWhenUnlockedThisDeviceOnly`,
  dedicated keychain), handing the token to the sidecar over the UDS handshake. This writes the first
  Swift in the spine now, kills SEC-3 as a Python blocker, and matches the "signed-app-owns-everything"
  TCC invariant. (Rejected: keeping the `security` CLI interim — unacceptable for a security-gating item.)
- **v1 finish line:** the **extended cut** — `SP0 → SP1 → SP2 → SP3-slim → SP4-slim` (chat + memory +
  web + terminal). SP2-alone is the **integration smoke-test milestone**, *not* v1.

---

## 3. Locked Architectural Decisions (research- + review-validated)

| Area | Decision |
|---|---|
| Repo strategy | **New `GINEXUS` repo** depending on `MTX-NEXUS` as the inference/security backend package. **No rename.** |
| Front-end | **Native SwiftUI.** Do not fork Electron/web. **Port** Axiom's UI look/feel + service shapes **file-by-file into a new module graph** (Axiom is a flat single-target SPM exe — not a drop-in lift). De-singleton, de-force-unwrap. |
| Tool bus | **MCP host first.** Implement **stdio + Streamable-HTTP** (drop legacy SSE unless a concrete server needs it). Don't MCP-wrap native capabilities until there is >1 tool. |
| IPC transport | **MTX-NEXUS UDS + 0600 socket + env-injected per-launch bearer token** (UDS 0600 TOCTOU already fixed on disk). NexusForge's plaintext-TCP / no-auth / force-unwrapped / UserDefaults-bash transport is **REPLACED**; only the child-`Process` supervision *lifecycle shape* is reused, rewritten (fixed app-bundle-relative interpreter, no force-unwrapped URLs, SwiftLint gate on every ported file). *(ADR required.)* |
| Inference | **ONE Python/uv sidecar engine for SP1** (`mlx-lm`) behind an OpenAI-compatible router. The Engine protocol is designed so an *optional* in-process `mlx-swift` small-lane engine **may** be added later (deferred until a measured latency win justifies a 2nd runtime). **Dual-engine mandate cut.** |
| Engine split | **TEXT Engine** (router-fronted, prefill/decode/stream) vs **MEDIA Engine** (NexusForge job interface, SP6). `mflux` is image-only and does **not** sit behind the text interface. |
| Model tiering | **Tier 1** MLX local (default) → **Tier 2** API. **Tier 0** Apple Foundation Models is **optional/feature-flagged** behind an adapter (its guided-generation API + small context don't natively match the OpenAI router shape). |
| Agent loop | **Minimal, model-driven** (native reasoning + native tool calls), with hard **iteration/tool-call ceilings**, sandboxing, and **HITL on irreversible actions**. The loop and all OS-affecting tool calls live behind the **signed Swift app** (TCC attribution), not the Python sidecar. |
| Memory | **Native two-tier** (in-context core blocks + fact extraction to a local vector store), CoALA-tagged, nightly consolidation, **human-inspectable flat files**. Untrusted-origin tagging is mandatory (§7). |
| Autonomy | **Per-capability dial** (suggest → auto-with-approval → autonomous-with-audit). Read/research = autonomous; irreversible/external (money, comms, destructive, locks, terminal mutations) = approval. Terminal autonomy max = **approve-every-invocation**. |
| Self-improvement | **Strictly approval-gated + eval-gated.** Self-authored skills + prompt-learning notes staged; nothing activates without Principal approval + eval pass + diff. |
| Multi-model | **Council/Group Mode** with a **neutral separate judge** (never member self-voting) + opt-in convergence + Blind Compare. Deferred to SP8 (no v1 value, pure added attack surface). |
| Distribution | **Direction decided** (non-sandboxed, Hardened-Runtime, notarized Developer-ID). **Packaging UNPROVEN — no app bundle exists yet.** A tracer-bullet spike (**SP1.5**) must pass before SP2 freezes the shell. Embedded-Python signing strategy = ADR. |
| Sequencing | **macOS daily-driver first.** Hermes always-on body + iPhone/Watch = SP9. |

---

## 4. Existing-Asset Landscape (re-baselined to disk reality)

There is **no `GINEXUS` directory** before today. GINEXUS is an **umbrella orchestrator, a strict
superset of MTX-NEXUS's scope**, that composes existing parts. The maturity ratings below were
**verified against the source on disk** by the review panel.

| Repo | Verified state | Role in GINEXUS |
|---|---|---|
| **MTX-NEXUS** | Python inference backend + IPC + **PARTIAL** security primitives. **ZERO Swift files.** SEC-1 (audit anchor), SEC-3 (non-syncable Keychain), and a monotonic+wired kill switch are **OPEN**. The "Swift-owned Keychain" referenced here does not exist yet. | The inference + IPC + security **spine** GINEXUS depends on as a package — **after SP0 closes the open gaps.** |
| **Hermes** | Blueprint, 0 code | Always-on headless **body** + iPhone/Watch control-surface contract (SP9). |
| **NexusForge** | Builds green; **IPC is plaintext TCP, no auth, force-unwrapped URLs, UserDefaults-bash launcher** | Image/video **subsystem** (MCP tools, SP6). Its **transport is replaced** (§3); only the supervision lifecycle is borrowed and rewritten. |
| **Axiom** | MVP; **flat single-target SPM exe** — no Info.plist, entitlements, bundle, or modules; `@Observable` god-objects; `SafetyGuard` = 10-entry substring denylist | UI/service **reference**, ported file-by-file into a real module graph. **`SafetyGuard` is NOT lifted as a security control** (§7/SP4). |
| **ai-export-sanitizer** | Beta v0.2 — **secret/PII redactor only** (placeholder substitution). **Does NOT neutralize prompt injection.** | Ingest **pre-processor**, but only one of two ingest controls; a real injection-mitigation layer is added in SP3 (§7). |
| **ai-iot-projects** | Project 01 prod-ready | Telemetry/monitoring ML patterns (not home control — that is new via HA). |
| **Nexus/NexusBI** | Beta ~30–40% | Optional analytics subagent — borrow patterns, don't adopt wholesale. |

**Mental model:** MTX-NEXUS = kernel + (in-progress) security spine · Hermes = always-on deployment ·
NexusForge/NexusBI/ai-iot = capability subsystems · **GINEXUS = orchestrator + native daily-driver head.**

---

## 5. High-Level Architecture

```
┌──────────────────────────────────────────────────────────────────────┐
│  HEADS (thin clients)                                                  │
│  • GINEXUS.app — native SwiftUI (daily driver, deep macOS integration) │
│  • iPhone + Apple Watch (HermesKit: approve/deny, voice, kill) [SP9]   │
│  • CLI + local API + MCP (human / program / agent)                     │
└───────────────┬──────────────────────────────────────────────────────┘
                │  UDS + 0600 + per-launch Keychain bearer token (signed app owns the token)
┌───────────────▼──────────────────────────────────────────────────────┐
│  GINEXUS ORCHESTRATOR ("LLM-OS kernel") — in the SIGNED SWIFT APP      │
│  • Agent loop (model-driven, native tool-calling, iteration ceilings)  │
│  • Workflow primitives (chain / route / parallel / orchestrator-worker)│
│  • Autonomy dial per capability · per-session Lane Queue               │
│  • APPROVAL-TOKEN trust boundary (Secure Enclave/LocalAuthentication;  │
│    HMAC over {action, resolved args, target, nonce, expiry}; single-   │
│    use; preview payload == executed payload)                           │
│  • 3-tier monotonic kill switch + HMAC-anchored append-only audit      │
└──┬─────────────┬─────────────┬──────────────┬───────────────┬─────────┘
   │             │             │              │               │
┌──▼───────┐ ┌───▼────────┐ ┌──▼─────────┐ ┌──▼──────────┐ ┌──▼──────────┐
│ MODEL    │ │ TOOL / MCP │ │ MEMORY     │ │ macOS / OS  │ │ MEDIA / SUBS │
│ ROUTER   │ │ HOST       │ │ (2-tier,   │ │ (signed app │ │ (MCP tools)  │
│ (TEXT    │ │ stdio +    │ │ untrusted- │ │ ONLY)       │ │ NexusForge   │
│ engine,  │ │ Streamable │ │ origin     │ │ App Intents │ │ Home Assist. │
│ sidecar) │ │ -HTTP      │ │ tagged)    │ │ Shortcuts   │ │ Deep Research│
│ Tier1 MLX│ │ default-   │ │ sqlite-vec │ │ EventKit    │ │ Council[SP8] │
│ Tier2 API│ │ deny       │ │ /LanceDB   │ │ Contacts    │ │              │
│ Tier0 FM │ │ imported   │ │ + LLM-Wiki │ │ Mail/Msgs   │ │              │
│ (opt.)   │ │ skills/MCP │ │ /raw(quar.)│ │ AXUIElement │ │              │
│ LiteLLM  │ │ = manifest │ │ →/wiki     │ │ Spotlight   │ │              │
│ OpenAI-  │ │ + pinned   │ │ + Skills   │ │ TWO TARGETS │ │              │
│ compat   │ │ provenance │ │            │ │             │ │              │
└──────────┘ └────────────┘ └────────────┘ └─────────────┘ └─────────────┘
        ▲ MEDIA engine (mflux/NexusForge) is a SEPARATE job interface, not behind the text router
        │
        ┌───────▼────────────────────────────────────────────┐
        │ INGEST: export → ai-export-sanitizer (redact) →     │
        │ injection-quarantine /raw (DATA-ONLY, no tools) →   │
        │ wiki-maintainer (no tool access) → /wiki + memory   │
        │ (tagged untrusted-origin; cannot authorize tools)   │
        └─────────────────────────────────────────────────────┘
```

**Process model:** Native **SwiftUI shell** (signed, non-sandboxed, notarized Developer-ID) owns the
agent loop, the MCP host, the approval-token mint/verify, **and all OS calls**. A **Python/uv FastAPI
sidecar** runs MLX inference, launched **from inside the app bundle** over UDS+token. **No OS-affecting
call (osascript/EventKit/Contacts/Mail/Accessibility) ever originates in the sidecar** (TCC
attribution). MEDIA generation is a separate job interface.

---

## 6. Model Policy (concrete picks → `docs/model-roster-2026-06-15.md`)

Target: Apple M2 Ultra, 192 GB (`iogpu.wired_limit_mb` ≈ 144 GB default — **not** 192 GB).

- **Default roster license bar = Apache-2.0 / MIT** (commercial-safe). Attribute NVIDIA for Parakeet.
- **Tiering:** Tier 1 MLX local (default) → Tier 2 API; Tier 0 Apple FM optional/flagged.
- **Memory budgeting is MEASURED, not estimated** (SP1): `weights + KV(ctx×concurrency) + activations
  + media + OS reserve` against the wired limit. State whether gpt-oss-120b **co-resides or evicts**;
  surface its ~9–13 s cold-load in auto-mode. Resident weights ≠ working set.
- **MoE metadata** carries total params (memory) and active params (latency) separately.
- **Reject native-FP8 checkpoints** (`Float8_e4m3fn/e5m2`); **MXFP4 (gpt-oss) is NOT FP8** and is allowed.
- **Supply chain:** SP1 records pinned HF revision SHAs + quant provenance in `models.lock`, flips
  `verify_lock(strict=True)` (fails closed on any `PIN_AT_PULL`), and records the model lockfile in the
  audit chain per inference. (Today: all entries are `PIN_AT_PULL`, `strict=False` — open.)
- **Eval-gated selection:** every rostered quant must pass the SP1/SP2 eval harness (schema adherence +
  reasoning golden set + injection corpus) vs its fp16/API reference before it is auto-selectable.

The full default table, license tiers, and engineering constraints live in the dated roster doc.

---

## 7. Cross-Cutting Security & Safety Gates

**Nothing above autonomy level "suggest" ships until §7.1–§7.4 hold.** The panel verified each gap
against disk.

### 7.1 SP0 blocking spine fixes (HARD exit gates)
1. **SEC-1 — audit anchor.** `audit.py` is a plain SHA-256 chain with **no secret** (docstring falsely
   says "signed JSONL") → forgeable. Fix: **HMAC the chain** with a Swift-app-owned Keychain key +
   out-of-band signed head; `verify()` must check the HMAC. *(Exit test: `verify()` rejects a forged chain.)*
2. **SEC-3 — non-syncable token.** Swift `KeychainStore` via `SecItemAdd` with
   `kSecAttrSynchronizable=false` + `AccessibleWhenUnlockedThisDeviceOnly` + dedicated keychain
   (decided §2). *(Exit test: token provably non-syncable + ThisDeviceOnly.)*
3. **Monotonic + wired kill switch.** Today `engage()` accepts any tier, `reset()` is unconditional, and
   `api/app.py:13` builds `KillSwitch()` with no audit / no `on_engage`. Fix: rank `soft<hard<nuclear`,
   refuse downgrades, **biometric-gated reset**, wire `on_engage`+audit, add an authenticated AND
   out-of-band trip. *(Exit test: nuclear survives a later soft and survives reset-without-biometric.)*
4. **Tighten THEN execution-test the SBPL profile.** `brainstem.sb` currently allows `file-read*` over
   **all of `$HOME`** and outbound to **`localhost:*`**. Scope reads to venv/project/state/model-cache;
   **explicitly deny `~/.ssh`, `~/.aws`, `~/.config`, other repos, and iCloud**; pin outbound to the exact
   model-server ports. *(Exit test: blocks a known-bad exec AND blocks reads of `~/.ssh` and iCloud.)*

### 7.2 Safety primitives pulled FORWARD (were sequenced after the code that needs them)
- **Approval-token trust boundary (defined in SP0, used from SP4):** minted/verified **only** in the
  signed Swift app; HMAC-bound to a canonical hash of `{action, fully-resolved args, target, nonce,
  expiry}`; single-use; **the previewed payload is byte-identical to the executed payload** (no
  post-approval shell expansion); the resolved target is shown, not a model summary. v1 surface = a
  **local macOS biometric sheet**; iPhone/Watch routing is SP9.
- **Minimal eval/injection harness (pulled to SP1/SP2):** golden tool-call schema set + small reasoning
  set + prompt-injection corpus, per quant vs reference. Gates auto-selectability. ("From day one" can't
  debut at SP8.)
- **Ingest injection mitigation (in SP3, gating "memory influences actions"):** the sanitizer is a
  **redactor only** — add a separate injection-mitigation layer. **Quarantine `/raw` as data-only** (the
  wiki-maintainer agent gets **no tool access**); tag all ingested/extracted memory **`untrusted-origin`**;
  forbid untrusted-origin memory from authorizing tool calls or entering a tool-enabled context without a
  trust downgrade. (Prevents the injection-into-memory pump.)

### 7.3 HITL = default-confirm allow-list (defined once in SP0, inherited by SP4/SP7)
Invert the deny-list: **every state-changing action confirms by default**; a no-confirm **allow-list** of
explicit `(entity, service)` / `(tool, op)` pairs is the only exemption. Resolve scene/automation
side-effects **transitively** (an allowed HA scene must not actuate a confirm-required domain). Treat HA
entity names/state, email, and device text as **untrusted**.

### 7.4 Imported skills / external MCP = default-deny capability manifest
External MCP servers and imported `SKILL.md` folders are **default-denied** all tool/network/file
capabilities on import (the OpenClaw "consumed uniformly" RCE error). Each requires a human-approved
capability manifest + provenance pinning (hash/version, like models), runs under the tightened sandbox,
and is **never auto-loaded from a registry**.

### 7.5 Standing constraints
Default-deny tool policy · scoped sessions · iteration/tool-call ceilings · sandboxed execution ·
scrub `BRAINSTEM_TOKEN` from child/tool subprocess environments (prefer UDS-handshake delivery).

### 7.6 iCloud HARD RULE (defense-in-depth)
Nothing under `~/Library/Mobile Documents/` is ever read/written. Add an explicit SBPL
`(deny file-read* file-write* (subpath …/Mobile Documents))` and apply the guard at the **tool/file-op
boundary**, not only at startup config (the agent can compute paths the startup check never sees).

---

## 8. Sub-Project Decomposition (build order + dependency DAG)

**Dependency DAG (not "all independently shippable"):**
`SP0 → SP1 → SP1.5 → SP2 → {SP3, SP4}`; SP4 ⇄ SP5a (App Intents shared); SP6 needs SP2;
SP7 inherits SP0's HITL primitive; SP8 needs the SP1/SP2 eval harness; SP9 needs SP2+SP4.

**v1 (daily driver) = SP0 → SP1 → SP2 → SP3-slim → SP4-slim.** SP2-alone = integration smoke-test.
**v1 acceptance test:** *"It researched X, wrote the result to a file, and remembered the answer the
next day."*

| # | Sub-project | Outcome |
|---|---|---|
| **SP0** | **Harden the spine + define safety primitives** | The four §7.1 fixes as HARD exit-gate tests (incl. the first Swift `KeychainStore`); **define** the approval-token trust boundary + the default-confirm HITL primitive. *(model-pull scripts moved to SP1; UDS TOCTOU already fixed — not an SP0 item.)* |
| **SP1** | **Extend the gateway → router + Engine + lockfile** | **EXTEND** the existing MTX-NEXUS LiteLLM gateway (`gateway.py`) with MLX/Ollama providers + a Tier 0/1/2 routing policy; **split Engine into TEXT vs MEDIA**; add the **model lockfile** (pinned SHAs) + a **measured residency report**; **pull the minimal eval/injection harness forward**. **CUT** the Cookbook GUI installer (use pull scripts; GUI is post-v1). |
| **SP1.5** | **Packaging / TCC tracer-bullet spike** (NEW) | Minimal Hardened-Runtime, **notarized** `GINEXUS.app` that launches the UDS sidecar **from inside the bundle**, makes **one EventKit call attributed to the app**, **registers one App Intent**, and passes `notarytool`. Embedded-Python signing strategy → ADR. **Must pass before SP2 freezes the shell.** |
| **SP2** | **GINEXUS Kernel: SwiftUI shell + agent loop + MCP host** | Thin orchestrator. Ported Axiom module graph, sidecar supervision over the UDS+token spine, model-driven agent loop (ceilings, sandbox, HITL), MCP host (stdio + Streamable-HTTP), session manager + Lane Queue, **the eval harness**, and the **local biometric approval sheet**. *(Smoke-test, not v1.)* |
| **SP3** | **Memory + personal-data ingestion** | sanitizer → **injection-quarantined `/raw` (data-only)** → wiki-maintainer (no tools) → `/wiki`; two-tier memory, CoALA-tagged, **untrusted-origin** tags, nightly consolidation. **Decide sqlite-vec vs LanceDB** (resolve git-diffable contradiction: track source flat files + rebuild script). A **retrieval eval** drives 0.6B-vs-8B embeddings. |
| **SP4** | **Core tool suite (shared-domain dual adapters)** | Each capability written once (typed Swift) → App Intent **and** MCP tool. Web search/fetch, **terminal (allow-list + capability model, NO shell-string passthrough for autonomous tiers, under SP0's SBPL, diff/preview + biometric HITL on mutation — approved string == executed string)**, email (preview-approval), file ops. Basic App Intent plumbing lands here. *(Axiom denylist removed, not reused.)* |
| **SP5a** | **App Intents / AppEntity / Spotlight** | The native-macOS differentiator, lower TCC risk: App Intents + IndexedEntity (Spotlight/Shortcuts/Siri), `shortcuts` CLI registry. |
| **SP5b** | **High-friction OS automation** | EventKit/Contacts/Mail/Messages, AppleScript/Apple Events, Accessibility AX fallback (system-toggle, not a prompt), Focus-awareness, permissions dashboard + TCC re-polling. All in the signed app. |
| **SP6** | **Media generation subsystem** | Adopt NexusForge via MCP tools (transport replaced per §3); mflux MEDIA engine (FP8-excluded registry); video defaults to API + opt-in local Wan with a **measured** wall-clock warning. Default artifact status `draft`. |
| **SP7** | **Smart-home / IoT control (Home Assistant)** | Consume HA local MCP + WebSocket + REST; scoped Keychain token; **inherits SP0's default-confirm HITL allow-list** (transitive side-effects resolved); optional ai-iot telemetry. |
| **SP8** | **Self-improvement + multi-model Council/Group Mode** | Agent Skills (progressive disclosure); self-authored skills + prompt-learning behind approval + **self-improvement eval-gate on top of the SP1/SP2 harness** + diffs; Council with a **neutral separate judge** + opt-in convergence + Blind Compare. |
| **SP9** | **Always-on body + companion clients (Hermes)** | Headless spine on a dedicated Mac (launchd, Tailscale+Caddy, no public ports) + iPhone/Apple Watch approval/voice/kill (HermesKit, biometric signed tokens, APNs/ntfy). **"One brain, many heads."** |

---

## 9. Risks

1. **Scope explosion** → SP decomposition + the extended-but-bounded v1 cut.
2. **Packaging/TCC UNPROVEN (biggest schedule risk)** → no app bundle exists; **SP1.5 spike** must pass before SP2.
3. **Local tool-calling reliability** → depends on the eval/injection harness **pulled forward to SP1/SP2** + schema validation + approval; route hard chains to higher tiers.
4. **Untrusted input everywhere** → default-deny, sandbox, scoped sessions, untrusted-origin tagging.
5. **Injection-into-memory pump** → `/raw` quarantine (no-tool wiki-maintainer) + untrusted-origin memory cannot authorize tools.
6. **Imported-skill / external-MCP RCE (OpenClaw lesson)** → default-deny capability manifest + provenance pinning.
7. **Spine not yet trustworthy** → SP0 four fixes are blocking exit-gates before autonomy > suggest.
8. **Local video not production-ready** → API default, local batch only.
9. **MemPalace benchmarks disputed** → patterns only, native build, re-benchmark.
10. **Model-roster volatility** → concrete picks isolated in a dated roster doc; supply-chain pinned (`strict=True`).

---

## 10. What's Next

1. **Principal reviews this master spec (v2).**
2. On approval → write the **SP0 spec** (the four blocking spine fixes as exit-gate tests + the
   approval-token + HITL primitives) and invoke `writing-plans`.
3. Proceed `SP0 → SP1 → SP1.5 → SP2 → SP3-slim → SP4-slim` to v1, with agent-team review at each gate
   (architecture → code → security) per the Principal's standing process.
