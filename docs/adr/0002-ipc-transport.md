# ADR 0002 — App ↔ Sidecar IPC Transport

**Status:** Accepted
**Date:** 2026-06-15

## Context
The GINEXUS app (signed Swift) supervises a Python inference sidecar. Two existing patterns
were candidates: MTX-NEXUS's UDS+token transport and NexusForge's `SidecarManager`. The
security review found NexusForge's transport is **plaintext TCP, no auth, force-unwrapped URLs,
launched via a UserDefaults-driven `bash -lc` (command-injectable)** — the insecure opposite of
what the master design implied.

## Decision
- **Transport = MTX-NEXUS UDS + 0600 socket + env-injected per-launch bearer token** (the spine
  hardened in SP0: zero-window 0600 bind, fail-closed keys, HMAC audit). The app mints/owns the
  token (Keychain, SP0 `GinexusKeychain`) and injects it; the sidecar binds the UDS only — no TCP.
- **From NexusForge we reuse ONLY the supervision lifecycle shape** (child `Process`, log capture,
  `terminationHandler`), and even that is rewritten: fixed app-bundle-relative interpreter (never a
  UserDefaults `bash -lc`), no force-unwrapped URLs, SwiftLint gate on every ported file.
- The SP1.5 tracer-bullet proved the app spawns a bundle-relative child (`Process` →
  `Contents/Resources/…`); SP2 swaps that stub for the real UDS sidecar launcher.

## Consequences
- No localhost TCP surface; egress stays pinned to model ports by the SP0 SBPL profile.
- The NexusForge media subsystem (SP6) is consumed over this same hardened transport, not its
  original plaintext one.
