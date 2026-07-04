# Hermes Gap Incorporation — Design

**Date:** 2026-07-05
**Branch:** `feat/hermes-gap-incorporation` (off `feat/counterpart-ui-overhaul`)
**Source reviewed:** `~/Desktop/hermes-agent` (Nous Research Hermes Agent, MIT). Full
engineering map produced by agent review; GINEXUS-side audit confirmed what the
`feat/hermes-incorporation` arc already shipped.

## Where GINEXUS already matches or beats Hermes

Already done (Phases A + B of `docs/hermes-incorporation-analysis-2026-06-30.md`):
context compaction, hybrid recall (RRF), error taxonomy + retry, post-turn memory
curation (B1), playbooks read/write (B2a/B2b), inactivity curator (B3), subagent
delegation with depth/blocklist limits, executable skills, profile block, scheduler-lite,
plus security properties Hermes lacks entirely (HMAC approval minting, Touch ID HITL,
hash-chained audit, forced-untrusted memory origin).

## The gap (from the fresh upstream review)

| # | Hermes capability | GINEXUS status | This pass? |
|---|---|---|---|
| W1 | Session search over past transcripts (FTS, discovery/scroll/browse, bookends, demote-automation) | ABSENT | **YES** |
| W2 | Compaction anti-resurrection preamble (`SUMMARY_PREFIX`) | Compaction exists, preamble missing | **YES** |
| W3 | Memory-hygiene "do-NOT-capture" hardening (negative capability claims, env-dependent failures, one-off narratives) | Partial in curator prompt | **YES** |
| W4 | Playbook live-reload (Hermes: snapshot + mtime manifest) | Deferred — auto playbooks invisible until reboot | **YES** |
| W5 | Bounded archives (Hermes: archive-only lifecycle, never delete) | `blocks-archive.jsonl` unbounded | **YES** |
| W6 | Real cron expressions + `[SILENT]` delivery | Interval-only scheduler | Deferred (roadmap) |
| W7 | Programmatic tool-calling (`execute_code` RPC sandbox) | ABSENT | Deferred — big security surface, needs its own gated design |
| W8 | Multi-provider transport, gateway adapters, phone pairing | ABSENT (Phase C) | Deferred — SP9 scope |
| W9 | Honcho-style dialectic user modeling | Local profile block covers the idea | No (by prior decision: no hosted deps) |

## W1 — Session search (`session_search` tool)

Hermes's design, adapted to GINEXUS's split-brain storage: transcripts live **app-side**
(`ConversationStore`, JSONL under Application Support), not in the Rust core. So the tool
is implemented in **AppToolHost** (the signed app's second UDS server the core already
calls for OS tools) — no new storage, no sync, transcripts never copied into the core.

One tool, implicit modes (Hermes's schema-bloat killer):
- **Discovery** (`query`): case-insensitive term scan over every persisted conversation's
  messages (personal scale ≈ hundreds of sessions — a linear scan with early caps is
  fine; FTS5 is an upgrade path, not a requirement). Score = per-message term-hit count
  with a recency tiebreak. Dedupe by conversation; return top 5 conversations, each with:
  title, updated-at, the best-matching message snippet (±2 messages of context), and
  **bookends** (first 2 + last 2 user/assistant messages) — Hermes's trick so the agent
  sees how a session started and ended without reading it all.
- **Scroll** (`conversation_id` + `around_index`): a ±6-message window centered on an
  anchor index, for drill-down paging.
- **Browse** (no args): the 10 most recent conversations (title, date, message count).
- No LLM summarization step — return real messages only (zero extra model cost; Hermes
  removed its summary path deliberately).
- The active conversation is excluded from discovery (it is already in context).
- Output is plain text framed as quoted DATA (same convention as the curator's
  transcript framing) — past-session content must not be interpreted as instructions.

Core side: `session_search` joins the app-host tool list (read-only, no approval gate
needed — it reads state the app already owns), plus one system-preamble guidance line
("Before claiming you don't remember earlier work, search past sessions").

## W2 — Anti-resurrection compaction preamble

Port Hermes's `SUMMARY_PREFIX` verbatim in spirit into `context_compress.rs`: the
compacted summary opens with a `[CONTEXT COMPACTION — REFERENCE ONLY]` preamble stating:
treat as background reference, do NOT re-execute or re-answer anything inside it, the
latest user message always wins, reverse signals ("stop", "never mind") end in-flight
work, and persistent memory blocks remain authoritative. Fixes the classic
"agent resumes cancelled work after compaction" failure.

## W3 — Curator prompt hardening (memory hygiene)

Augment the B1/B2b curator prompts with Hermes's hard-won rules:
- Never capture **negative capability claims** ("X tool is broken", "Y doesn't work") —
  they harden into refusals the agent cites against itself for months.
- Never capture environment-dependent failures, transient errors, or one-off task
  narratives.
- The memory/playbook split, stated as Hermes states it: memory = who the user is and
  the current state of operations; playbooks = how to do this class of task.

## W4 — Playbook live-reload

`ginexus-server` loads the playbook library once at boot; a B2b-authored playbook is
invisible until relaunch. Fix: reload the library from disk after any successful
`playbook_write` (and after curator authoring). The library handle becomes shared
mutable state (`RwLock`); reload is a full re-scan (small N, boot already does it).
The system-prompt index stays boot-frozen (Hermes freezes prompt snapshots per session
on purpose — cache discipline); `playbook_view`/list reflect live state, which is what
the agent actually pulls.

## W5 — Archive rotation

`archive_block` appends to `blocks-archive.jsonl` unbounded. Cap like playbook archives:
keep the newest `MAX_BLOCK_ARCHIVES = 200` lines (rewrite-on-append when exceeded).
Archive-only, never delete live data — Hermes's lifecycle rule kept intact.

## Explicitly deferred (roadmap, in order)

1. **W6 cron expressions + `[SILENT]`** — adopt a cron-expr crate, keep interval syntax.
2. **W7 programmatic tool calling** — Hermes's UDS-RPC stub pattern is the right shape
   and GINEXUS already speaks UDS, but letting the model author executable scripts that
   drive tools needs its own adversarial design pass (env scrubbing, tool intersection
   allowlist, HITL on mutating calls from scripts). Do not bolt on.
3. **W8 gateway/phone (SP9)** and multi-provider transport — per master plan.

## Security invariants (unchanged, non-negotiable)

- No new write paths without the approval gate; `session_search` is read-only.
- Past-transcript content is DATA, never instructions (explicit framing in tool output).
- Curator stays single-shot, allowlisted, forced-untrusted, single-flight.
- No hosted services (no Honcho); everything on-device.

## Test plan

- Rust: unit tests for the compaction preamble presence, archive rotation cap,
  playbook reload visibility (write → list shows it without reboot).
- Swift: `GinexusCore` tests for session-search scoring/windowing/bookends over a
  fixture store; app builds; core `cargo test` stays green (43+).
