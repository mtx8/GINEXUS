# GINEXUS — Acquisition-Readiness Audit & Remediation Backlog (2026-06-22)

Multi-agent audit (7 dimensions: audio, performance, profile, AI-import, security, reliability, UX) →
61 findings, 47 after dedup. Severity × confidence × acquisition-impact ranked. Status tracked here.

**Legend:** ✅ done · ⏳ in progress · ⬜ open. Confidence: `confirmed` (in code) / `likely` (needs profiling) / `measured` (validated on-device).

---

## A) Audio stutter — root cause + fix (the #1 pain) — ✅ FIXED

Runtime measurement (this session): TTS RTF idle 0.43, under 30B-LLM load 0.43–0.52 → **GPU contention
adds only ~10–20%, NOT the cause.** The dominant causes were per-call overhead + fragmentation.

- **A1** `measured` GPU/unified-memory contention TTS↔Ollama — real but **minor (~15%)**. *No "wait for full reply" needed (would re-add latency).* ✅ measured, not blocking
- **A2** `confirmed` Serial per-sentence HTTP /synthesize, ~0.4–0.6s cold-start each → inter-chunk gaps. ✅ **fixed** — coalesce to ~140-char chunks (first sentence still fast).
- **A3** `confirmed` No playback jitter buffer → underrun-on-drain = silence. ✅ **fixed** — ~280ms prebuffer in `AudioOutput`.
- **A4** `confirmed` Tiny fragments ("Hey!") + raw markdown/emoji to TTS. ✅ **fixed** — coalescing + `ttsClean()` strips markdown/emoji.
- **A5** `likely` Main-actor contention (PCM convert + schedule on `@MainActor` vs `TimelineView` 120Hz + 48Hz level). ✅ **fixed** — `AudioOutput` off main actor; level throttled 48→15Hz.
- **A6** `confirmed` 100ms transport frames fine; paired with A3. ✅ covered.

---

## B) Critical / High — must-fix before acquisition

- **B1** `critical` `renderSnapshot()` rasterizes ENTIRE chat + PNG-encodes + writes disk synchronously on `@MainActor`, 12+ call sites — `AppModel.swift:1369`. ⬜ → env-gate, last-N only, debounce, `Task.detached`.
- **B2** `high` Per-token `onChange` animates scroll + invalidates whole LazyVStack — `ContentView.swift:223`. ⬜
- **B3** `high` `pollTimer` detached UDS round-trip every 1s forever, no backoff/pause — `AppModel.swift:327`. ⬜
- **B4** `high` `buildProfile()` claims "saved to memory" on server errors (no status check) — `AppModel.swift:1016`. ⬜
- **B5** `high` AI-import format detection inspects only `root[0]` → silent fallthrough → 0 facts, no error — `ingest.rs:47`. ⬜
- **B6** `high` Ingest sanitizer never redacts personal NAMES → operator name into archival memory (privacy-DD red flag) — `ginexus-sanitize/src/lib.rs:33`. ⬜ → plumb `with_custom_terms` end-to-end.
- **B7** `high` `voice.log` logged speech transcripts + reply text in plaintext, unbounded. ✅ **fixed** — gated to DEBUG/opt-in, content never logged (lengths only).
- **B8** `high` No top-level LICENSE/NOTICE despite MIT Cargo; no SBOM/model-weight attestation — IP/legal DD. ⬜
- **B9** `high` `boot()` leaks previous core+sidecar processes (zombies every restart) — `SpineController.swift`. ⬜ → `teardownIfRunning()` + reap. *(I've been killing these manually all session.)*
- **B10** `high` `shutdown()` never reaps; wedged sidecar holds the port → next launch's uvicorn silently exits. ⬜
- **B11** `high` Voice `start()` blocks on `warmup()` (600s, swallows errors) → "active" with no mic up to 10min. ⬜ → `/healthz` probe first, lower timeout.
- **B12** `high` Permanent stuck "thinking"/"speaking" if turn never finalizes. ✅ **fixed** — 90s turn watchdog recovers.
- **B13** `high` Actionable `spineStatus` rendered only in the headless SnapshotView; live UI shows bare "OFFLINE" → demo dead-end — `ContentView.swift:144`. ⬜ → offline banner + "Restart core".
- **B14** `high` No way to stop/cancel an in-flight reply (Send disabled, no Stop) — `ContentView.swift:431`. ⬜

---

## C) Medium — improvements

- **C1** `@Published chatInput` invalidates whole tree per keystroke — `AppModel.swift:81`. ⬜
- **C2** `StreamingText` 0.53s blink Timer rebuilds full AttributedString per tick — `ContentView.swift:1078`. ⬜
- **C3** Profile build appends into the user's active conversation — `AppModel.swift:1012`. ⬜
- **C4** Silent profile-block overwrite, no diff/undo — `main.rs:904`. ⬜
- **C5** ChatGPT multimodal `content.parts` non-string entries silently dropped — `ingest.rs:88`. ⬜
- **C6** Generic ingest reaches one nesting level → Gemini/Copilot/etc. → 0 facts silently — `ingest.rs:155`. ⬜
- **C7** `Origin::Untrusted` defense is a soft inline suffix the payload can mimic — `memory/lib.rs:263`. ⬜ → nonce-fenced delimiter.
- **C8** Zero import observability (`skipped` discarded, no preview/undo) — `AppModel.swift:634`. ⬜
- **C9** `web_fetch` SSRF guard doesn't resolve DNS (rebind/TOCTOU) — `web.rs:18`. ⬜
- **C10** Autonomous mode runs `calendar_create`/`fill_pdf_form` unattended (only `irreversible`, not `hard_gate`) — `loop_.rs:378`. ⬜
- **C11** `likely` TTS streaming worker can deadlock the single MLX thread on barge-in cancel (`q.put` blocks) — `server.py:127`. ⬜
- **C12** STT timeout abandons work on shared MLX thread → next op wedges; temp WAV unlinked early — `server.py:176`. ⬜
- **C13** `/healthz` hardcodes `status:"ready"` even on model-load failure — `server.py:201`. ⬜
- **C14** Mic can stay closed if playback completions don't fire after stop. ✅ **covered** by the B12 watchdog (+ `whenDrained` forces play).
- **C15** `AudioOutput.start()` failure silently swallowed. ✅ **fixed** — logged via VoiceLog.
- **C16** Send/stream failures surface as raw `"error: …"` prose, no retry — `AppModel.swift:644`. ⬜
- **C17** Empty state assumes a model is installed; no first-run "download a model" path — `ContentView.swift:231`. ⬜
- **C18** "Enabled Tools" rows hardcode `on:true` → fake CONNECTED when OFFLINE — `ContentView.swift:566`. ⬜
- **C19** Icon-only buttons lack `.accessibilityLabel` — `ContentView.swift` (several). ⬜
- **C20** Sidecar dir/home path (→ username) leaked into voice.log. ✅ **mitigated** — voice.log gated + content-free (path lines log dir only in DEBUG).

---

## D) Low — polish / hygiene

D1 scheduled profile-refresh unwired · D2 no size cap on profile block · D3 core blocks read-only in UI ·
D4 confirm `persistActive` write is off-main · D5 GlyphMark animated shadow offscreen-renders ·
D6 per-token O(n) chat scan · D7 cosmetic `streaming` flag overload · D8 MAX_FACTS iterate-skip ·
D9 non-UTF8 export misleading error · D10 ingest arbitrary-path read · D11 per-launch keys via child env ·
D12 mic-level diag log every 2s → ✅ now gated/content-free · D13 redaction assertion for API keys ·
D14 fixed 450ms re-arm guard → derive from drain · D15 voice error text truncation/dismiss; unify level meters ·
D16 StreamingText hardcoded font · D17 model selector empty state · D18 no-conversations empty CTA ·
D19 stale-snapshot profile · **D20 emoji in product UI — ✅ verified CLEAN** (only `▌`/`↓`/backend `✓`).

---

## Highest-ROI remaining (recommended next)

1. **B9/B10/B11** sidecar lifecycle (zombies, port, warmup) — reliability + stops the manual-kill loop.
2. **B1/B3** main-thread (`renderSnapshot`, `pollTimer`) — biggest non-audio perf wins.
3. **B6/B8** name redaction + LICENSE/SBOM — privacy + IP due-diligence blockers.
4. **B13/B14** offline banner + Stop button — demo polish.
5. **B4/B5** profile error-check + import format detection — correctness/silent-data-loss.
