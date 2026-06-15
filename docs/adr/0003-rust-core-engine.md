# ADR 0003 — Rust is the Core Engine (non-negotiable)

**Status:** Accepted (Principal directive, 2026-06-16)
**Supersedes:** the Python orchestration role from the SP0–SP2 spine

## Context
The SP0–SP2 spine was built in Python (FastAPI) to reuse MTX-NEXUS and prove the design fast —
which it did: chat, the agent tool-loop, and HITL approval were all verified live. The Principal
has since mandated, non-negotiably, that **the core engine be Rust** for speed, safety, and
reliability. This matches the original research (the "Rust core + thin head" pattern of Jan/Goose)
and the CORTEX/OMNISCIENT precedents (hardened Rust cores).

## Decision
- **The core engine is Rust** — a `ginexus-core` Cargo workspace at `GINEXUS/core/`. It owns the
  entire hardened orchestrator: security primitives (HMAC audit chain, approval tokens, kill
  switch, HITL), the agent tool-loop, the model router, the UDS+token server, and the MCP host.
- **Python is demoted** to (at most) an optional MLX model-server. The existing Python spine
  (`MTX-NEXUS/backend`) is now the **reference implementation**: its test suite and the
  cross-language **golden vectors** are the behavioral contract the Rust core must satisfy.
- **Swift remains the thin UI head**, talking to the Rust core over the same UDS + per-launch
  bearer token contract (the existing Swift `UDSClient` is unchanged).
- **Inference stays out of Rust**: the Rust core calls model servers (Ollama [Go], an MLX server)
  over localhost HTTP — MLX is not reimplementable in Rust, and the mature path is more reliable.
  (`mlx-rs` is a future option; not on the critical path.)

## New topology
```
Swift app (UI) ──UDS+token──▶ Rust ginexus-core (engine) ──HTTP──▶ model servers (Ollama / MLX)
```

## Migration (port module-by-module, parity-tested)
1. `ginexus-security` — approval / audit / killswitch / hitl. **DONE** (27 tests; the approval
   golden vector is byte-identical to Python: payload string + HMAC hex match exactly).
2. `ginexus-agent` — tool registry + tools + the ReAct loop (HITL-gated, iteration ceiling).
3. `ginexus-gateway` — model router + HTTP client to the OpenAI-compatible model servers (reqwest).
4. `ginexus-server` — UDS + bearer-token auth + JSON API (/healthz, /v1/chat, /v1/agent,
   /v1/admin/killswitch); fail-closed on missing keys; sandboxed.
5. `ginexus-mcp` — MCP host (stdio + Streamable-HTTP).
Then re-point the Swift app at the Rust server's socket and retire the Python spine from the path.

## Consequences
- Memory safety + constant-time crypto by construction; a single, fast, statically-linked engine.
- The Python work is not wasted — it de-risked the design and is the executable spec/contract.
- Two implementations exist transiently; the Rust core is authoritative once the server crate lands.
