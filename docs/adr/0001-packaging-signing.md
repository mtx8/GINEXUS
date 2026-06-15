# ADR 0001 — Packaging, Signing & Notarization

**Status:** Accepted (SP1.5 tracer-bullet validated the local path; distribution path documented)
**Date:** 2026-06-15

## Context
GINEXUS needs deep macOS automation (App Intents, Shortcuts, EventKit/Contacts/Mail,
Accessibility, spawning a sidecar). App Sandbox and deep automation are mutually exclusive,
so the flagship is a **non-sandboxed, Hardened-Runtime, notarized Developer-ID** app
distributed by **direct download (not the Mac App Store)**.

## Decision
- **Bundle:** native SwiftUI `.app`, `com.macktrax.ginexus`, Hardened Runtime
  (`codesign --options runtime`), non-sandboxed (no `com.apple.security.app-sandbox`).
- **OS calls originate in the signed app** (TCC attribution). The Python sidecar never calls
  Calendar/Contacts/Mail/Accessibility — it is spawned by the app from inside the bundle.
- **Local dev:** ad-hoc signing (`-s -`) — proven in SP1.5 (`codesign --verify` passes, Hardened
  Runtime flag set, bundled sidecar spawns, App Intent registers, EventKit attributed to the
  bundle). `spctl` rejects ad-hoc/unnotarized — expected.
- **Distribution:** re-sign with a **Developer ID Application** cert + `--timestamp`, then
  `notarytool submit … --wait` + `stapler staple`. The operator supplies the Developer ID cert
  + an app-specific password (this dev machine has only an Apple Development cert).

## Embedded-Python signing (SP2 task)
The SP2 sidecar ships a Python interpreter + venv inside the bundle; Hardened Runtime +
notarization reject unsigned nested code. Chosen approach (in priority order):
1. **Ship a relocatable `python-build-standalone` interpreter and deep-sign it** + every
   `.dylib`/`.so` in the venv with `--options runtime` (most correct; notarization-clean).
2. Interim fallback: `com.apple.security.cs.disable-library-validation` entitlement to allow
   unsigned nested libs — weaker; only if (1) is not yet ready.
Bytecode is not written into the read-only bundle (`PYTHONDONTWRITEBYTECODE=1`); caches go to
the app-support state dir.

## Consequences
- No Mac App Store for the flagship (acceptable; an optional sandboxed "lite" build can come later).
- Notarization requires operator credentials → a release step, not a CI default on this machine.
- `build_app.sh` parameterizes `GINEXUS_SIGN_ID` so the same script does ad-hoc dev and Developer-ID release.
