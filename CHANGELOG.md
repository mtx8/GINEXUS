# GINEXUS — Changelog

Progress log for the GINEXUS personal AI agent (GiNexus startup foundation). Newest first.
Format loosely follows [Keep a Changelog](https://keepachangelog.com/). Each entry maps to a
merged PR on `main` (repo `mtx8/GINEXUS`, private). Architecture, decisions, and the deep
technical record live in `docs/superpowers/specs/` and `docs/adr/`; this file is the high-level
running history.

## Status snapshot

- **v1 acceptance test PASSES** end-to-end on the Rust core: research (web_fetch) → write-to-file
  (HITL approval) → remember (persistent memory), with cross-language (Swift↔Rust) approval-token parity.
- **8 Rust crates** — security, agent, gateway, mcp, memory, skills, sanitize, server. **108 Rust tests + 16 Swift tests.**
- **App**: self-contained signed `GINEXUS.app` (embeds the Rust core), redesigned as a three-pane
  **"Execution Stream"** (icon rail · floating Conversations card · stream of agent-flow blocks ·
  floating Context & Tools card) on the MackTrax brand. Token-streaming chat with content-aware
  rendering, action/final-output cards, **PDF + Word document creation**, collapsible **floating
  side panels**, settings screen, smart attachments + **vision wiring**, in-app model manager,
  memory browser, **⌘K command palette**, starter-prompt empty state, and a **Connections card
  grid** (MCP servers + exposed tools) — matched to the claude.ai/design "GINEXUS Prototype".
- **Live memory**: the operator's full ChatGPT history — 3,779 sanitized facts with 768-dim embeddings.
- **Default model**: Qwen3-30B-A3B-Instruct-2507 (Apache-2.0) via Ollama. Vision tier ready (Qwen3-VL-30B-A3B, pull when Ollama ≥ 0.12.7).

---

## 2026-07-06 — SP-FAB: the Fabrication module — AI-run 3D printing (branch `feat/sp-fab`)

SP-Robotics Phase 3 ships: GINEXUS now operates real 3D printers. New **`ginexus-print`** crate
(9th): a unified `PrinterDriver` layer with the **first Rust implementation of Elegoo/Chitu SDCP
V3** (UDP discovery, WebSocket control, chunked-MD5 upload — protocol-tested against an
in-process mock printer), OctoPrint + Moonraker REST drivers, a deterministic mock, a pure-Rust
**mesh gate** (watertight/manifold, volume, bbox, overhangs → ModelReport), the open-source
**resin pipeline** (PrusaSlicer SLA → SL1 → UVtools → .goo/.ctb/.pm7/.pwsz + island/resin-trap
validation) and FDM pipeline, and a persisted **job queue** with a manual-unload gate. 14 `fab_*`
agent tools under the SP-FAB safety doctrine: **start/resume/plate-clear are hard-gated**
(approval even in autonomous mode — printers can't sense resin/plate/lid), pause is always free.
**PSS enforced**: no downloads ever, fixed `/Applications` tool paths, `codesign -v` preflight,
copyleft tools stay external processes, keys stay in env/Keychain. New generic **MCP stdio
server** (`ginexus_mcp::server`) + `--fab-mcp` subcommand exports the fab tools to external MCP
hosts (hard-gated tools excluded by default). App: new **Fabrication section** (sidebar → detail
pane): printer rack with live telemetry (OMNISCIENT **cyan = live data** law joins the Silo
Unison recipe), per-printer tabs, job queue with "Plate Cleared" human confirmation, SDCP
discover + manual-IP add-printer flow, 4-s live polling; `NSLocalNetworkUsageDescription` added.
Research basis: 33-agent verified workflow (SDCP spec, Anycubic M7 cloud-lock → R2, MCP
landscape, headless slicing, CAD-AI). Design: `docs/superpowers/specs/2026-07-06-sp-fab-fabrication-design.md`.

## 2026-07-01 — Hermes incorporation #8: learning loop B3 — inactivity curator (Phase B COMPLETE) (branch `feat/hermes-incorporation`)

Phase B Increment B3 — the self-improvement loop now maintains itself when idle: after ~5 min of no
agent activity (and work since the last pass), GiNexus autonomously refreshes its durable profile block
from long-term memory. Finishes Phase B.

- **Idle trigger** (`ginexus-server`): `should_consolidate` (pure, unit-tested) + `last_activity` /
  `last_consolidated` atomics bumped on both agent routes; the heartbeat fires the pass at most once per
  idle period. Single-flight (shares B1/B2's `curation_gate`), killswitch-gated (re-checked immediately
  before the autonomous write), audited (`consolidate_idle`).
- **Reversible** (`ginexus-memory` `archive_block`): the prior profile is snapshotted to an append-only
  `blocks-archive.jsonl` before overwrite (undo trail).
- **Refactor:** extracted `consolidate_profile` (shared by `/v1/consolidate` and the idle trigger) —
  route behavior preserved (Ok(Some)→profile, Ok(None)→no-memory, Err→502).
- **SEC/PSS gate: APPROVE-WITH-CHANGES → required change applied.** The gate caught the one novel risk:
  autonomous distillation of *untrusted* archival facts (imported ChatGPT history / web / tool output)
  into the always-injected trusted profile = laundering untrusted content into unreviewed standing
  context. **Fix: the autonomous path is `trusted_only`** — it distills ONLY `Origin::Trusted` facts;
  the human-reviewed `/v1/consolidate` keeps all-origin (operator sees the result). Also applied the
  should-fix (killswitch re-check before the write). Catastrophic path was already contained by
  HITL-in-code (irreversible actions gate on tool flags, not profile text). **Code review: APPROVE.**
- **172 Rust tests (2 new), 0 failures.** No Swift changes. TDD (pure decision + snapshot).
- Deferred (nice-to-have, per gate): mark the B3 block as machine-distilled in `system_preamble`;
  `blocks-archive.jsonl` rotation/cap; playbook-umbrella merge.

**PHASE B COMPLETE** (B1 memory curation · B2a playbooks · B2b authoring · B3 inactivity curator). The
closed self-improvement loop is fully operational: GiNexus curates memory + procedural skills after
substantive turns, and refreshes its self-model when idle — locally, free, and PSS-gated end to end.
Next: **Phase C** (ProviderTransport → RPC programmatic-tool-calling → real cron → gateway/DM-pairing).

---

## 2026-07-01 — Hermes incorporation #7: learning loop B2b — autonomous playbook authoring (branch `feat/hermes-incorporation`)

Phase B Increment B2b — the closed loop now improves its PROCEDURAL skills too: after a turn that
demonstrated a reusable how-to, GiNexus may autonomously author an agent playbook. The most sensitive
surface (an agent writing files); shipped write/overwrite-only (no fuzzy patch → no ambiguous-match risk).

- **`playbook_write`** (`ginexus-skills/src/playbooks.rs`): creates/updates `auto/<name>/SKILL.md` with the
  gate's hard controls — **R5** we compose the frontmatter (description newline-stripped + quote-neutralized;
  origin is dir-derived, never frontmatter → an agent playbook can never become trusted/enter the index);
  **R6** whitelist name `[A-Za-z0-9_-]` (traversal impossible) + `auto/` AND per-playbook-dir symlink refusal;
  **R7** archive-not-delete, fail-closed + rotation-bounded (`auto/.archive`, keep 5); **R9** global cap of 64.
- **`curate_playbooks`** (`ginexus-agent/src/curator.rs`): single-shot, transcript-as-DATA, runs ONLY
  `playbook_write` (allowlist + name filter, double-contained), capped at 2/pass, never panics.
- **`maybe_curate`** (`ginexus-server`): shared helper wired into both agent routes — **R10** killswitch
  no-op + single `curation_gate` permit shared by memory (B1) + playbook (B2b) curation; std killswitch
  guard provably not held across `.await`. Audits `{saved, playbooks}`.
- **SEC/PSS gate: PASS, no HALT (LOW risk)** — R5–R11 all verified in code + test-covered; a malicious
  transcript cannot forge trusted origin, reach the system prompt, escape `auto/`, or execute anything.
  **Code review: APPROVE.** Applied the one defense-in-depth note (per-playbook-dir symlink refusal).
- **170 Rust tests (8 new), 0 failures.** No Swift changes. TDD throughout.
- Notes: fuzzy `playbook_patch` (design R8) intentionally omitted (overwrite-only is safer); freshly
  written agent playbooks activate on next boot (immutable loaded library — safer). **Phase B COMPLETE
  except B3** (inactivity curator). Next: B3, then Phase C.

---

## 2026-07-01 — Hermes incorporation #6: learning loop B2a — procedural "playbooks" (branch `feat/hermes-incorporation`)

Phase B Increment B2a — a NEW skill class: **prose procedural "playbooks"** (how-tos the model reads),
distinct from the existing executable `skill.json` plugins (which stay user-authored, untouched). This is
the read-only foundation for Hermes-style self-improving skills; the autonomous write side is B2b.

- **Playbook module** (`ginexus-skills/src/playbooks.rs`, new): agentskills.io/Anthropic-compatible
  `<dir>/<user|auto>/<name>/SKILL.md` (frontmatter + body). Hand-rolled `---`-split parser (no YAML lib —
  anchors are an injection surface); tolerant of BOM/CRLF/leading-blanks/body-`---`/missing-fence → skip,
  never panic. Progressive disclosure: a user playbook's `description` enters the system-prompt index; the
  body is pulled on demand via a read-only **`playbook_view`** tool.
- **Server wiring**: loads `<state>/playbooks/{user,auto}` at boot, registers `playbook_view`, injects
  the cached user-only index into `agent_messages` (order: conductor → guidance → playbooks → memory → convo).
- **AIL-SAFETY design gate: APPROVE-WITH-CHANGES; the B2b write path was HALTED pending R-crux** — folded
  in before coding. **R-crux (load-bearing): agent-authored (`auto/`) playbooks NEVER enter the system
  prompt** — pull-only via `playbook_view`, body tagged `[agent-authored … data, not instruction]` (mirrors
  B1's untrusted-via-pull model). Origin is derived from the DIRECTORY, never frontmatter (a file can't
  self-declare `origin:user`). Plus R1 (view-by-name → traversal impossible by construction; symlink escape
  refused), R2 (index count+byte budget), R3 (no name shadowing — user wins), R4 (robust parser).
- **B2a code gate: SEC/PSS APPROVE (all 5 checks PASS, no HALT) + code review APPROVE.** Applied the two
  worthwhile suggestions: memoize the index (computed once at load), clarify the byte-cap comment; added
  loader symlink-refusal + byte-budget + multi-colon/quoted-value tests.
- **162 Rust tests (13 new), 0 failures.** No Swift changes. TDD throughout.
- **B2b (next, own SEC gate):** autonomous playbook authoring/patching via the B1 curation heartbeat —
  confined to `auto/`, archive-not-delete, fuzzy-replace (refuse ambiguous), frontmatter re-validate
  (reject origin edits), killswitch + single-flight (R5–R11 in the design).

---

## 2026-07-01 — Hermes incorporation #5: learning loop B1 — autonomous memory curation (branch `feat/hermes-incorporation`)

Phase B Increment B1 — the closed self-improvement loop now RUNS: after a substantive turn, GiNexus
quietly distills durable facts into long-term memory, locally and for free, with no human asking.
Built against the AIL-SAFETY-gated design; the trigger wiring passed its own SEC/PSS gate.

- **Curator** (`ginexus-agent/src/curator.rs`, new): `curate_memory()` — a SINGLE model call over the
  just-finished transcript (framed as quoted DATA with an anti-injection wrapper), executes ONLY
  `remember`, hard-capped at 5 writes, never panics (model failure → 0 saved). The Hermes review-prompt
  IP (do-NOT-capture list) ported in.
- **Server wiring** (`ginexus-server`): opt-in `curate` flag on both `/v1/agent` and `/v1/agent/stream`;
  after the response/done frame, a **fire-and-forget** task curates on the **fast local tier**, behind a
  **single-flight semaphore**, using `build_curation_registry()` (the forced-untrusted, `remember`-only
  allowlist — never `state.registry`/`memory_tools`). Only fires on a `Final` result (never mid-approval);
  failures are swallowed + audited (`audit.record("curate", {saved})`), never user-visible.
- **App cadence** (`AppModel`): sets `curate:true` every 6 turns; counter is per-conversation (reset on
  newChat AND on conversation switch — the latter was a code-review fix). Approval re-runs never curate.
- **SEC/PSS gate: APPROVE, all 6 checks PASS, no HALT** — registry correctness, forced-untrusted
  end-to-end, fire-and-forget isolation (panic-confined), single-flight (no permit leak), Final-only
  trigger, and zero injection reach to web/OS tools all verified at file:line. **Code review: 1 fix
  applied** (per-conversation cadence reset in `adopt`).
- **GATE 1+2 regression test** (`curation_registry_tests`): asserts the curator registry is `remember`-only
  (web_fetch/recall/set_memory/terminal/… all unreachable) AND forces `Origin::Untrusted` even on
  `untrusted:false` — locks the load-bearing property against future refactors.
- **149 Rust tests (5 new across curator + regression), 0 failures. App BUILD SUCCEEDED.** TDD throughout.
- **Phase B remaining (later PRs):** B2 skill self-improvement (fuzzy-patch + archive-not-delete),
  B3 inactivity curator. Then Phase C (ProviderTransport → RPC tool-calling → cron → gateway/DM-pairing).

---

## 2026-07-01 — Hermes incorporation #4: learning-loop design + safe substrate (branch `feat/hermes-incorporation`)

Phase B (the headline closed self-improvement loop) — **started correctly: design + safety gate before
code** for this autonomous self-modification surface. Two commits:

- **Gated design doc** (`docs/learning-loop-design-2026-07-01.md`). AIL-SAFETY/PSS design gate verdict:
  **APPROVE-WITH-CHANGES (no HALT)** — caught 3 PSS-level holes *before any code*: (1) a curation
  registry built from `ToolRegistry::readonly()` would leak `recall`/`web_fetch`/`read_document` (since
  `remember` is non-irreversible) → must be a positive allowlist; (2) the shared `remember` defaults
  Trusted → curation must force `Origin::Untrusted` in code; (3) routing through `run_streaming` at
  depth 0 re-arms `delegate`/`council`/`deep_research` → use a single-shot call. Plus transcript-as-DATA
  framing, an archival write mutex + single-flight, and an expanded do-NOT-capture list (third-party PII,
  special-category data, inferences, imperative/standing-instructions).
- **Safe substrate** (`ginexus-memory`), implementing gate changes #1/#2/#5 (all low-risk, fully tested):
  - `memory_curation_tools()` — positive-allowlist toolset exposing ONLY a curation `remember` that
    **hardcodes `Origin::Untrusted`** (no `untrusted` field in its schema); built from scratch, not from
    `memory_tools`/`readonly()`. A prompt-injected curator cannot plant a trusted standing instruction.
  - `archival: Mutex<()>` serializing `archival.jsonl` appends — fixes a real writer/writer race (the new
    concurrency test tears lines without it).
  - **SEC verification: PASS, no HALT.** Allowlist, forced-untrusted, and mutex (no deadlock) all
    confirmed airtight at file:line.
- **144 Rust tests (3 new), 0 failures.** TDD throughout (incl. a genuinely-RED concurrency test).
- **Remaining for B1 (next focused PR, its own SEC gate):** the single-shot curator call in the agent
  crate (transcript-as-DATA, execute only `remember`, cap 5, swallow+audit errors), the server `curate`
  flag + fire-and-forget spawn, and the app cadence (every-N-turns toggle). The wiring increment MUST be
  constructed with `memory_curation_tools` (not `memory_tools`) — carry a regression test asserting it.

---

## 2026-07-01 — Hermes incorporation #3: error taxonomy + one-shot retry (branch `feat/hermes-incorporation`)

Phase A #3. Makes every model call resilient to transient local-server failures (Ollama cold start,
timeout, connection refused, 5xx) instead of surfacing them as a fake `"model error: …"` answer.

- **Pure taxonomy** (`core/crates/ginexus-gateway/src/lib.rs`): `classify_error(status, is_timeout,
  is_connect) → ErrorClass` (Timeout/Connect/RateLimit/ServerError/ClientError/Unknown) + `retryable()`.
  Adapted from Hermes `error_classifier.py`. 4xx (≠429) and Unknown are NOT retried (won't self-heal).
- **One-shot retry** (`send_with_retry`): on a retryable class, wait 300ms and retry the request exactly
  once; the closure rebuilds the (consumed) `RequestBuilder`. Wired into `complete_with_tools` and
  `complete_with_tools_streaming`; streaming retries only the INITIAL request (a mid-stream error is
  surfaced, never silently swallowed, to avoid re-emitting already-streamed tokens).
- **PSS/SEC gate: PASS (CLEAN).** The retry is model *inference* only — tools execute downstream in the
  agent loop with the HITL biometric gate intact, so a retry can NEVER double-execute an irreversible
  action or bypass approval. One retry only (no storm); no secret leakage (token stays in the header,
  never in error strings). `tokio` added to the gateway crate = the existing workspace pin.
- **Code review: APPROVE.** Documented the local-first idempotency assumption (honor `Retry-After` /
  reconsider 5xx-retry if a remote billed API is ever fronted).
- **141 Rust tests (2 new classifier tests), 0 failures.** TDD: stub → RED → implement → GREEN.

---

## 2026-07-01 — Hermes incorporation #2: hybrid memory recall (branch `feat/hermes-incorporation`)

Phase A #2 of the Hermes plan. Upgrades long-term recall from **either/or** (semantic OR keyword)
to **hybrid** — fusing both signals so exact tokens (IDs, error codes, file paths, proper nouns)
that embeddings rank poorly are no longer lost. Adapted from Hermes's FTS5 idea, but kept native to
GiNexus's lightweight append-only JSONL store (no SQLite dependency).

- **Reciprocal Rank Fusion** in `MemoryStore::search()` (`core/crates/ginexus-memory/src/lib.rs`):
  a semantic ranking (cosine) and a keyword ranking are fused via `Σ 1/(K+rank)`, K=60 — scale-free,
  no weight tuning between a [0,1] cosine and a word count. Degrades cleanly: no embedder → keyword
  only; zero-overlap semantic query → semantic only; so all prior behaviors (and tests) are preserved.
- Live automatically in the `recall` tool and `POST /v1/memory/search` (both call `search()`).
- **PSS/SEC gate: PASS** (ai-safety-reviewer, halt authority). Origin labeling preserved end-to-end —
  Untrusted facts still surface as DATA-not-instructions (the injection defense is the labeling layer,
  unchanged by re-ranking); panic/DoS-safe; no leakage. NON-BLOCKING note for the security design doc:
  hybrid modestly amplifies *recall* of untrusted exact-token content vs the old semantic-only path —
  acceptable because the defense is labeling, not ranking.
- **Code review fix applied:** the fused sort now has a total-order tie-break on insertion index
  (`.then(a.1.cmp(&b.1))`) — RRF can produce bit-identical scores at symmetric ranks and `ts` collides
  at ms resolution (batch import), so without it the ordering depended on randomized HashMap iteration
  → non-reproducible recall. Now deterministic.
- **139 Rust tests (2 new), 0 failures.** TDD: tests first (exact-token surfacing + dual-signal ranks
  first), watched fail, implemented, green.

---

## 2026-06-30 — Hermes incorporation #1: deterministic context compaction (branch `feat/hermes-incorporation`)

First feature ported from **Nous Research's Hermes Agent** (forked to `mtx8/hermes-agent`) after a
6-agent analysis (`docs/hermes-incorporation-analysis-2026-06-30.md`). Closes the **context
compression** gap — previously the agent loop was bounded only by an iteration ceiling, so a long
agentic turn could overflow a local 8K–32K Ollama/MLX window.

- **No-LLM Tier-1 compactor** (`core/crates/ginexus-agent/src/context_compress.rs`, new). Adapted
  from Hermes `context_compressor.py`: dedup identical tool results (keep newest verbatim), truncate
  oversized tool-call arguments *inside the parsed JSON* (stays valid), digest stale tool results to
  a one-line hint, and a last-resort token-budget **tail-cut** that pins `system` + the latest `user`
  request and never orphans a tool_call/result pair. Runs every loop iteration before the model call;
  a cheap no-op below threshold. Budget math mirrors Hermes (reserve output, 50%/85% of the rest).
- **Wired into the loop** (`loop_.rs`) with the result exposed on `AgentResult.compaction` and
  serialized over `/v1/agent` + the streaming `done` event (`ginexus-server` `compaction_json`).
- **New "Context Budget" meter** (`ContentView.swift` `ContextBudgetGauge` + `AppModel` parsing):
  window-fullness bar that turns Hinomaru-red past 85%, plus a "TRIMMED" badge (deduped/digested/
  dropped + before→after tokens) shown only when the compactor actually engaged.
- **Safety:** execution & HMAC approval bind to the *fresh* per-turn args, never the compacted
  history; the pending tool call (last assistant `tool_calls`) is never truncated; audit hash-chain
  untouched. Code + security review: APPROVE. **137 Rust tests** (10 new) + app `BUILD SUCCEEDED`.
- Follow-ups queued: feed the real `GINEXUS_CTX_WINDOW` to the UI meter; then hybrid FTS5 recall and
  the closed self-improvement loop (Phases A→B of the analysis).

---

## 2026-06-30 — UI: match the Claude Design "GINEXUS Prototype" (branch `feat/voice-docs-projects-connect`)

Pulled the full UI/UX of the **"GINEXUS Prototype"** (built in claude.ai/design) into the real
native app — re-implemented as SwiftUI on the existing `Brand.swift` tokens + `AppModel`, no HTML
ported. All in `app/Sources/GinexusApp/ContentView.swift` (+ one `@Published` in `AppModel.swift`).

- **Rich empty state.** "What should we work on?" display heading + subtitle + three tappable,
  hover-lift **starter cards** (`StarterCard`) that fire real sends; the research card arms Deep
  Research first.
- **⌘K command palette.** New `CommandPalette` / `CommandRow` overlay — searchable navigation,
  Deep-Research / HITL toggles, and a row per model; window-wide `⌘K` shortcut, Enter runs the top
  hit, Esc / click-out dismisses. Backed by `AppModel.paletteOpen`.
- **Model dropdown tiers.** `modelSelector` grouped under **"Local · Apple Silicon"**, each row
  showing `label · tier` (e.g. `Qwen3-30B · smart`), tier derived from the roster id.
- **Right-panel Connections row.** `connectionsSection` ("MCP & tools · N connected · M tools" +
  MANAGE) between Token Usage and File Context, wired to real counts.
- **Connections sheet redesign.** `ginexus-core` summary card + 2-col **`ServerCard`** grid
  (transport badge, status pill, wrapped tool chips via a `FlowLayout`). Built-in core servers are
  always-on (disabled switch — gated per call); external servers keep live toggle + remove; the
  add-server form (Notion / GitHub presets + generic stdio) is preserved behind **ADD**. New shared
  `ConnServer` model + `AppModel.connectionServers` / `connectedServerCount` / `exposedToolCount`.
- **No fake stats** (brand rule): all counts derive from the real connection surface; tool chips are
  real capability names, not invented metrics.
- Verified: `swift build` **and** the full `GINEXUS` scheme build (cargo pre-action + per-Mach-O
  sign) both **SUCCEED**.

---

## 2026-06-21 — Voice, documents, projects, connections (branch `feat/voice-docs-projects-connect`)

A large operator-driven session adding four new subsystems (specs in
`docs/superpowers/specs/2026-06-21-*`), plus a competitive teardown
(`docs/competitive-strategy-2026-06-21.md`) of Nous Hermes & PewDiePie Odysseus.

- **SP-Voice — conversational voice.** New `app/audio-sidecar/` (FastAPI, loopback, single-thread
  MLX): Chatterbox Multilingual V3 TTS + Parakeet-TDT STT, all local, no PyTorch. Verified
  end-to-end on M2 Ultra — TTS↔STT round-trip 94% word overlap, warm TTS RTF 0.31×, STT 0.81s.
  Swift hands-free loop (mic VAD → STT → agent → streamed 24 kHz TTS) with **barge-in** (AEC via
  voice-processing), a mic toggle + live status bar, mic entitlement + usage string, and a core
  `speak` tool. (Live mic loop needs on-device run to exercise.)
- **SP-Docs — document intelligence + in-place PDF form filling.** Native PDFKit
  `read_pdf_fields` + `fill_pdf_form` fill real AcroForm PDFs **in place** (timestamped backup),
  iCloud-refused, XFA/flat detection — PDFKit round-trip verified PASS. `read_document` reads
  PDF/text/code, chunking into memory as `Origin::Untrusted` (grounding + injection defense).
- **SP-Projects — workspaces.** Projects group a local folder, custom instructions, and their own
  threads; `Conversation` gains a back-compatible `projectID`; per-project instructions are injected
  as a system message; Projects menu + editor sheet. Folders under `~/GINEXUS-Projects/` (iCloud refused).
- **SP-Connect — MCP integration framework.** Keychain secret store; settings-driven multi-server
  registry (`GINEXUS_MCP_SERVERS`); SpineController injects per-server secrets into the core env;
  Connections sheet with a one-paste **Notion** preset. All MCP tools stay default-deny (HITL).
- **Verification:** full `xcodebuild` SUCCEEDS with the mic entitlement embedded; Swift core tests
  21/21 pass; new Rust voice/PDF tool tests pass. Remaining polish: docs review-diff UI, voice
  cloning UI, MCP settings panel depth, and live Notion/mic exercising.

## 2026-06-18 — Polish + real-work pass (PRs #34–#45)

A long operator-driven session refining the shell and the actually-doing-work flows.

- **Layout (#34, #35, #37):** the GINEXUS header is now a **full-width top bar** (right of the icon
  rail) with the panels + stream BELOW it — the brand no longer gets squeezed between panels; a hidden
  panel collapses to a small floating tab high in the upper area, with GINEXUS clearly above it.
- **Brand (#36, #38):** the wordmark never wraps/compresses (`lineLimit(1)` + `fixedSize`); the AUTO /
  HITL toggle is box-less (just the ember bolt + label).
- **Working-state animation (#36, #39, #40, #43, #45):** the corner glyph + the active reply avatar
  rotate/breathe while the AI is thinking and **stop when done** (fixed a stuck `repeatForever`); the
  Models rail icon pulses while a model **downloads**. Each tool shows **one contextual card** that
  animates and then completes **in place** — photo for images, document for PDFs/Word, research, agents,
  council, web, terminal, memory, vault. The card now appears from an **early "intent" signal** (the
  moment the model commits to a tool, before its arguments finish) so it animates for the whole job,
  with tense-aware labels ("Generating image" → "Image generated").
- **Documents (#41, #42):** the agent no longer generates an image for a document/PDF request (tool
  descriptions + an `AGENT_GUIDANCE` system rule keep tool selection disciplined); and both renderers
  now **parse the model's Markdown** into properly formatted files — **PDF** in Helvetica with accurate
  AFM proportional wrapping (no clipping), inline bold/italic, sized headings, bullets/numbered lists,
  pagination; **DOCX** with real Word headings/bold/italic/bulleted paragraphs. Verified by rendering.
- **Privacy (#44):** GINEXUS never reveals the macOS username or absolute home path — tool results and
  replies use `~/…` (via `abbreviate_home`), full path only if explicitly asked.

## 2026-06-18 — Token-usage gauge + side-panel polish

A real **token-usage gauge** wired end-to-end, and a second pass on the floating side panels per
operator feedback. Designed by a parallel "understand" workflow (one reader per code layer), built
coherently across Rust + Swift, then hardened by a 4-dimension adversarial review (each finding
independently verified — which correctly **refuted** a false "panic" claim and two false "invalid SF
Symbol" claims, the latter settled by an empirical `NSImage(systemSymbolName:)` probe).

- **Real token usage, gauge in the Context rail.** The gateway now sends `stream_options.include_usage`
  and captures the late empty-`choices` usage chunk (and the non-streaming `usage`); `AssistantTurn`
  carries per-call `Usage{prompt,completion}` (now **u64**, no truncation), and `AgentResult.total_usage`
  **sums every model call in a run** — main-loop iterations plus the delegate / council / deep_research
  fan-outs and all their workers. The core emits `usage` on the `/v1/agent` + `/v1/agent/stream` done
  frames **only when real (total > 0)** — "real data or none" — and records it in the audit trail. The
  app shows a clean gauge (prompt / completion counts, an ember-vs-bone proportional bar, total) that
  resets per conversation and shows "—" until a turn reports real counts. **Verified live**: a real
  30B turn returned `usage{prompt 1391, completion 2, total 1393}` on the SSE done frame. +2 Rust tests
  (accumulation + zero-default), bar width clamped against a malformed total.
- **Side panels, second pass.** Floating panels now use a **really subtle fill** (`ink850` @ 0.42)
  with a **thin bright hairline** (`white` @ 0.14) so they read as outlines, not solid blocks; a
  **collapsed panel is now a small floating pill** (compact, vertically centered — no longer a
  full-height bar) with a full-pill click target; and the Enabled-Tools icons are a cleaner, modern
  **monochrome** set (`network`, `terminal.fill`, `brain.head.profile`, `person.3.fill`, …).

## 2026-06-18 — Make-it-beautiful: the "Execution Stream" redesign (MackTrax brand)

A full visual rebuild of the app shell into a three-pane agentic **Execution Stream**, iterated
against operator reference UIs (a tactical-HUD aesthetic and the OMNISCIENT floating-panel system)
with an offscreen `ImageRenderer` harness as the visual feedback loop (screen capture is TCC-blocked
on this Mac). Every token comes from the `macktrax-design` system — `ink900` canvas, single `ember`
accent, dark-only, no emoji/neon/glassmorphism, real data only.

- **#34 — Floating side panels (OMNISCIENT-style).** Both rails are now rich **floating cards** over
  the canvas — rounded 16px, hairline border, top highlight, soft shadow, generous margins — instead
  of flush bordered columns. A reusable `FloatingPanel` (titled header + collapse chevron + optional
  header accessory) and `CollapsedTab` (thin vertical tab that expands) drive both the left
  **Conversations** card (list + new-chat + AGENT status footer) and the right **Context & Tools**
  card (Session stats · Current File Context · Enabled Tools), each independently collapsible with an
  eased transition. Same look and feel whether revealed or collapsed.
- **#33 — One-color wordmark + boxless glyph + bigger branding.** `GINEXUS` is a single-color
  Trade-Gothic stamp (no two-tone), the corner glyph is an 8-point ember starburst with **no square
  box**, sized up, and the `GINEXUS` wordmark now reads larger than the `Execution Stream` label.
- **#29 — PDF + Word document creation.** A new HITL-gated `write_document` core tool builds valid
  files with **zero new crates** — hand-rolled **PDF-1.4** (xref/trailer, Courier, wrapped/paged)
  and **DOCX** (OPC ZIP with stored entries + CRC32, `[Content_Types].xml`/rels/`document.xml`).
  Verified by `file` ("PDF document, version 1.4" / "Microsoft Word 2007+") and `unzip -t`. The app
  surfaces the result as a **Final Output** card with Open / Reveal (NSWorkspace). +4 Rust tests.
- **#28 — Luxe agent-flow redesign.** The stream renders as composable blocks — user prompts as a
  right-aligned bubble; assistant turns as **Action cards** (one per tool step), a live status card,
  bare prose, and a Final Output card — with a text-only **SEND** control (no gimmick icon). Center
  column locked to a readable 760px measure with auto-scroll.
- **#26–#27 — Tactical HUD + Gemini-style chat foundations.** Mono tactical labels, status dots,
  `BlockCard`/`Panel` primitives, and a clean Gemini-style conversation flow established the base the
  later passes refined.

## 2026-06-17 — Functional-UI completion (history, settings, vision)

The "make-it-right" UI phase, each feature designed by a multi-agent workflow and hardened by an
adversarial review (25 confirmed findings fixed across the three) before merge.

- **#21 — Vision / image-understanding wiring (graceful degradation).** Attach an image → it's sent
  to a vision model when one is available, else degrades to a clear text note. Core: a `vlm` tier
  (Qwen3-VL-30B-A3B), `has_image()` detection, vision routing that **fails loud** (never answers
  blind from a text model — an image always forces the vision tier), and a 24MB request-body guard.
  App: OpenAI multimodal content array, deterministic ImageIO downscaling (1536px, EXIF-stripped,
  12MB cap), a capability gate (`visionAvailable` = Ollama ≥ 0.12.7 + a VLM installed), "Attach
  image…", a thumbnail chip (decoded once) + degradation copy.
- **#20 — Settings screen.** A SETTINGS sheet over `SettingsStore`/`GinexusSettings` (sole owner of
  settings.json): live defaults (model, HITL/AUTO mode), and core-config via env + APPLY & RESTART
  CORE (Ollama endpoint, Obsidian vault, image generation) — restart is `!sending`-guarded,
  boot-id-validated, and watchdog'd. Security: the iCloud hard-rule check canonicalizes (symlink-proof,
  app + core), the Ollama base is host-checked (loopback/LAN ok; metadata/link-local blocked), and
  settings.json is written 0600.
- **#19 — Conversation history & persistence + sidebar.** Transcripts persist app-side; a
  NavigationSplitView sidebar with NEW / select / inline rename / delete, auto-titled, most-recent
  restored on launch. A serial-queue store with the in-memory index as the single authority (no
  lost-updates / no resurrection of a deleted chat); switching is blocked mid-stream.

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
