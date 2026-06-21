# SP-Voice — Conversational Voice (local STT ↔ LLM ↔ TTS)

**Status:** Draft v1 — awaiting Principal review
**Date:** 2026-06-21
**Owner:** Dreb (Principal) · authored via Conductor + 2 source-research sweeps (Chatterbox engine, GINEXUS architecture)
**Brand:** GiNexus (the Okinawa AI startup, MackTrax family)
**Parent:** `docs/superpowers/specs/2026-06-15-ginexus-master-design.md` (this is a sub-project spec)
**Siblings:** `2026-06-21-sp-docs-document-intelligence-design.md`, `2026-06-21-sp-connect-mcp-integrations-design.md`

> Voice was originally sequenced into **SP9 (Hermes companion clients)** in the master design. The
> Principal has pulled a **desktop-first conversational voice** subsystem forward as its own track,
> built on the existing sidecar + UDS rails. This spec covers the macOS daily-driver voice loop only;
> the iPhone/Watch voice surface remains SP9. (Note the naming collision: the master design's "Hermes"
> always-on body is unrelated to Nous Research's "Hermes" model family — a rename of the GINEXUS
> subsystem is recommended separately.)

---

## 1. Overview & Goal

Give GINEXUS a **local-first, real-time conversational voice** that sounds **as good as or better than
ElevenLabs**, runs entirely on-device (Apple MLX), and supports **hands-free, interruptible**
conversation. No audio ever leaves the Mac.

**Acceptance test:** *"I can talk to GINEXUS hands-free, it understands me, replies in a natural voice
within ~1 second of finishing my sentence, and I can cut it off by simply starting to talk."*

The voice engine is **Resemble AI's Chatterbox** (MIT, commercial-safe), whose own blind evals report
listeners preferring it over ElevenLabs (~63–65% preference). Speech-to-text is **Parakeet-TDT-0.6b-v3**
(already the master-design roster pick). Both run as MLX models inside a single Python sidecar; the
**signed Swift app owns the microphone, playback, and turn-taking** (TCC attribution — §5).

---

## 2. Confirmed Decisions (Principal, 2026-06-21)

1. **Scope = full hands-free loop** — mic → STT → LLM → TTS → speaker, with **barge-in** (the user
   talking interrupts playback). Not push-to-talk-only; not TTS-output-only.
2. **Voice = Chatterbox Multilingual V3 (≈500M)** — 23 languages incl. Japanese & Chinese (fits the
   Okinawa/MackTrax brand). MIT licensed.
3. **Voice selection = default built-in voice + zero-shot clone support** — ship a default voice now,
   plus the plumbing to clone a custom voice from a **~10 s** clean reference clip.
4. **Engine = MLX** — **NOT** PyTorch-MPS. MPS is unstable on Apple Silicon for Chatterbox
   (tensor-allocation errors, pinned-torch conflicts); MLX is the native-Metal path and matches
   GINEXUS's existing MLX-first stack. This is the same family of concern as the master design's
   "reject native-FP8 / Metal-crash class" posture.
   - **Resolved checkpoint (2026-06-21):** the multilingual MLX weights exist and are commercial-clean.
     **Primary = `theoracleguy/Chatterbox-Multilingual-MLX-v2-fp16`** (Apache-2.0, 331.5M params,
     `mlx-audio` library, ~1.5K downloads); **lighter fallback = `…-MLX-v2-Q8`** (Apache-2.0). fp16 is
     the default — a 331M model on a 192 GB Mac has no reason to quantize for memory; keep max quality.
   - **Library note:** the multilingual checkpoints load via **`mlx-audio`** (not `mlx-audio-plus`,
     which is the English-base path). Confirm the exact loader + sentence-streaming support at first
     import (residual sub-risk, non-blocking).
   - **Future ANE option:** `smdesai/Chatterbox-Multilingual-TTS-8bit` runs on **CoreML / Apple Neural
     Engine** (23 langs, MIT) — benchmark later as a latency play; different runtime than `mlx-audio`.
5. **STT = Parakeet-TDT-0.6b-v3** via `parakeet-mlx` (master-design roster; attribute NVIDIA).
6. **Audio output = 24 kHz** (Chatterbox/S3Gen native rate; read `model.sr` at runtime, don't hardcode).
7. **Perth watermark stays ON by default** — Chatterbox watermarks all generated audio; the code is MIT
   and the watermark imposes no commercial restriction. Keep it (responsible-provenance default);
   leave a future toggle but do not strip it now.

---

## 3. Architecture

Three layers, reusing the proven `media-sidecar` pattern (`app/media-sidecar/server.py`) and the
existing UDS + per-launch-token spine.

### 3.1 Audio sidecar — `app/audio-sidecar/server.py` (NEW)

FastAPI on **loopback `127.0.0.1:8764`**, launched from inside the app bundle. All MLX inference runs on
a **single-thread executor** (Metal stream consistency — same rule the media sidecar follows). Models
lazy-load on first use with an explicit warmup call.

| Endpoint | Method | Purpose |
|---|---|---|
| `/healthz` | GET | `{"status":"ready", "models":{...}}` once weights are resident |
| `/synthesize` | POST | Text → **sentence-chunked, streamed 24 kHz** audio. Params: `text`, `language_id`, `exaggeration` (default 0.5), `cfg_weight` (default 0.5), `temperature` (0.8), optional `voice_ref` (path to a reference clip for cloning). Streams audio chunks as they generate (sub-second to first audio). |
| `/transcribe` | POST | PCM/WAV audio → `{"text":..., "confidence":..., "language":...}` via Parakeet. |
| `/voices` | GET | List available voices (default + any registered clone references). |
| `/warmup` | POST | Force-load STT + TTS weights (called at sidecar start so the first real turn is fast). |

- **Dependencies pinned** in `app/audio-sidecar/pyproject.toml`: `mlx-audio` (multilingual Chatterbox
  loader), `parakeet-mlx`, `fastapi`, `uvicorn`, plus the Chatterbox MLX checkpoint
  (`theoracleguy/Chatterbox-Multilingual-MLX-v2-fp16`) pulled from a **pinned HF revision** (per the
  master-design supply-chain rule: pinned SHAs, `verify_lock` discipline).
- **Sentence chunking** is what makes it conversational: the synthesizer splits the LLM reply on
  sentence boundaries and emits audio per sentence so playback starts while later sentences are still
  generating (upstream Chatterbox has no first-class streaming API — we chunk at the sentence layer
  rather than depend on a token-streaming fork).

### 3.2 Rust core — `core/crates/ginexus-server/src/main.rs` (EXTEND)

Add two routes to `handle_conn()`, proxying to the sidecar at `GINEXUS_AUDIO_BASE`
(env var injected by `SpineController`, mirroring `GINEXUS_MEDIA_BASE`):

- `POST /v1/tts` → forwards to sidecar `/synthesize`, streams audio back over the UDS.
- `POST /v1/stt` → forwards to sidecar `/transcribe`.

Register a `speak` agent tool (`core/crates/ginexus-agent`): lets the agent voice a message
autonomously **when voice mode is active** (output-only → autonomous; it triggers no irreversible
side-effect itself). Tool calls that *are* irreversible still hit HITL regardless of voice (§5).

### 3.3 Swift app (NEW code — the orchestrator owns the loop)

- **`SpineController.startAudioSidecar()`** — gated by a `voiceEnabled` setting, mirroring
  `startMediaSidecar()` (`uv run uvicorn server:app --host 127.0.0.1 --port 8764`), injects
  `GINEXUS_AUDIO_BASE` into the core, calls `/warmup`.
- **`AudioInput.swift`** — `AVAudioEngine` microphone capture + an **energy/silence VAD** (voice
  activity detection) for end-of-utterance detection and barge-in. Requests mic permission once.
- **`AudioOutput.swift`** — streamed **24 kHz** playback (`AVAudioEngine`/`AVAudioPlayerNode`), able to
  **stop instantly** on barge-in.
- **`VoiceConversationController.swift`** — the turn-taking loop. Drives mic → `/v1/stt` →
  **existing `/v1/agent/stream`** (the agent loop is unchanged) → per-sentence `/v1/tts` → playback;
  cancels cleanly on barge-in.
- **Voice UI in `ContentView`** — a voice mode with a **mic orb**, **live transcript**, and a
  **speaking indicator**, styled to MackTrax (dark `--ink-900`, `--ember-500` accent, halftone
  texture; motion easing `cubic-bezier(0.22,1,0.36,1)`).
- **Entitlements / Info.plist** — add `com.apple.security.device.audio-input` to
  `app/GINEXUS.entitlements` (currently empty) and `NSMicrophoneUsageDescription` to `app/Info.plist`.
  Entitlement attaches to the **app only**, never the sidecar (per the master-design TCC invariant).

---

## 4. Data Flow — one conversational turn (with barge-in)

```
[idle: mic open, VAD listening]
  │  user speaks
  ▼
VAD detects speech start ──► (if TTS is currently playing → BARGE-IN:
  │                            AudioOutput.stop() + cancel in-flight agent stream + cancel /v1/tts)
  │  user keeps talking … VAD detects end-of-utterance (silence threshold)
  ▼
AudioInput hands PCM buffer ──► POST /v1/stt ──► transcript
  ▼
transcript appended to conversation ──► POST /v1/agent/stream  (unchanged agent loop, HITL intact)
  ▼
as the reply streams, split on sentence boundaries
  └─ per sentence ──► POST /v1/tts ──► 24 kHz audio chunk ──► AudioOutput plays (FIFO)
  ▼
playback finishes ──► back to [idle: mic open, VAD listening]
```

**Barge-in invariant:** the mic and VAD stay live *during* playback. Detected user speech immediately
(a) stops `AudioOutput`, (b) cancels the in-flight `/v1/agent/stream` request, and (c) cancels any
pending `/v1/tts`, then re-enters capture — so the user is never talking over a monologue.

---

## 5. Security & HITL

- **TCC attribution:** microphone capture and audio playback originate **only in the signed Swift app**,
  never the Python sidecar — same invariant as every other OS call in GINEXUS.
- **HITL preserved:** voice does not bypass approval. Any voice-initiated tool call that is irreversible
  or external (email send, terminal mutation, IoT lock, spend, external comms) still triggers the
  **existing biometric approval sheet**. Voice changes the *input modality*, not the trust boundary.
- **Local-only:** STT, TTS, and the LLM all run on-device. No audio, transcript, or reply is sent to any
  network service. The sidecar binds loopback only.
- **Reference clips (voice cloning):** stored under `~/Library/Application Support/GINEXUS/voices/`
  (owner-only). **Never** under `~/Library/Mobile Documents/` (iCloud HARD RULE — defense-in-depth at
  the file-op boundary, not just startup config).
- **Watermark:** Perth watermark left on by default (provenance), consistent with "no fake/unlabeled
  media" brand rules.

---

## 6. Risks

1. **Risk #1 — MLX Multilingual checkpoint availability — RESOLVED (2026-06-21).** ✅ Multiple
   Apache-2.0 MLX multilingual Chatterbox checkpoints exist on the Hub. **Chosen:
   `theoracleguy/Chatterbox-Multilingual-MLX-v2-fp16`** (Apache-2.0, 331.5M, `mlx-audio`), Q8 as
   fallback. No conversion or PyTorch-MPS fallback needed. **Residual sub-risk (non-blocking):** confirm
   the exact loader package (`mlx-audio` vs `mlx-audio-plus`) and its sentence-streaming support at first
   import; pin the HF revision SHA then.
2. **First-audio latency on M2 Ultra is unverified.** No source gives an Apple-Silicon RTF for
   Chatterbox. Mitigation: sentence-chunked streaming + warmup; **benchmark before committing** (§7).
   If sentence-chunk latency is too high, evaluate a token-streaming fork as a follow-up.
3. **VAD false triggers / barge-in oversensitivity.** Background noise could cut off playback.
   Mitigation: tunable energy + min-speech-duration thresholds; a "hold to talk" fallback.
4. **Microphone permission / Hardened Runtime.** Mic entitlement + usage string must be present or the
   notarized app crashes on first capture. Mitigation: covered in the entitlements step + a permissions
   check in `VoiceConversationController` before opening the mic.

---

## 7. Testing

- **STT↔TTS round-trip smoke test:** synthesize a known phrase via `/synthesize`, feed the audio to
  `/transcribe`, assert the transcript matches (fuzzy) — proves both halves load and run.
- **First-audio latency benchmark** on the M2 Ultra: measure time from `/synthesize` request to first
  audio chunk. **Target: sub-second to first audio.** Record alongside the residency report.
- **GinexusCore unit tests** for the audio client (request/stream framing over UDS, cancellation on
  barge-in, error paths when the sidecar is down → graceful fall back to text).
- **Barge-in integration test:** start playback, inject simulated speech energy, assert playback stops
  and the agent stream is cancelled within a bounded time.

---

## 8. Decomposition (ordered implementation steps)

1. **Risk #1 — DONE** ✅ checkpoint chosen (`theoracleguy/Chatterbox-Multilingual-MLX-v2-fp16`).
   Remaining slice of this step: a throwaway spike that `pip install`s the loader, loads the checkpoint,
   and synthesizes one phrase on the M2 Ultra — confirms `mlx-audio` vs `mlx-audio-plus` + streaming,
   then pin the HF revision SHA. *(Spike before full sidecar plumbing.)*
2. **Audio sidecar** — scaffold `app/audio-sidecar/` (mirror media-sidecar), implement `/healthz`,
   `/warmup`, `/synthesize` (sentence-chunked streaming), `/transcribe`, `/voices`; pin deps.
3. **Sidecar launch** — `SpineController.startAudioSidecar()` + `voiceEnabled` setting + `GINEXUS_AUDIO_BASE`
   injection.
4. **Core routes** — `POST /v1/tts`, `POST /v1/stt` proxies; the `speak` agent tool.
5. **Swift audio I/O** — `AudioInput.swift` (capture + VAD), `AudioOutput.swift` (streamed playback +
   instant stop); entitlement + usage string.
6. **The loop** — `VoiceConversationController.swift` wiring mic → STT → `/v1/agent/stream` →
   sentence-TTS → playback, with barge-in cancellation.
7. **Voice UI** — mic orb, live transcript, speaking indicator in `ContentView` (MackTrax tokens).
8. **Voice cloning** — register a `~10 s` reference clip → `voice_ref` path threaded through
   `/synthesize`; default voice ships without one.
9. **Tests + latency benchmark** (§7); agent-team review (architecture → code → security) per standing
   process.

---

## 9. Acceptance Criteria

- Speaking to GINEXUS hands-free produces an accurate transcript, a streamed spoken reply in the
  Multilingual V3 voice, and **first audio within ~1 s** of end-of-utterance on the M2 Ultra.
- **Barge-in works:** starting to talk cuts off playback and the in-flight reply, and the system
  returns to listening.
- A **custom voice** can be cloned from a ~10 s reference clip and used for replies.
- All audio stays **on-device**; the sidecar binds loopback only.
- Voice-initiated **irreversible actions still require biometric approval**.
- The STT↔TTS round-trip smoke test and the GinexusCore audio-client unit tests pass.

---

## 10. References

- Chatterbox (source, MIT): https://github.com/resemble-ai/chatterbox
- Chatterbox model card: https://huggingface.co/ResembleAI/chatterbox
- MLX checkpoint (CHOSEN, multilingual, Apache-2.0): https://huggingface.co/theoracleguy/Chatterbox-Multilingual-MLX-v2-fp16 (Q8 fallback: `…-MLX-v2-Q8`)
- MLX ports: `mlx-audio` (multilingual loader) · `mlx-audio-plus` (English base): https://github.com/DePasqualeOrg/mlx-audio-plus
- ANE/CoreML option (future latency play): https://huggingface.co/smdesai/Chatterbox-Multilingual-TTS-8bit
- MLX checkpoint (English reference): https://huggingface.co/mlx-community/Chatterbox-TTS-fp16
- Parakeet STT: master-design roster (`docs/model-roster-2026-06-15.md`), `parakeet-mlx`
- Sidecar pattern to mirror: `app/media-sidecar/server.py`
- UDS/IPC + TCC invariants: master design §3, §5, §7
