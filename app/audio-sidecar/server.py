"""GINEXUS audio sidecar — local conversational voice on Apple MLX.

Two halves, both loopback-only:
  - TTS: Chatterbox Multilingual (theoracleguy/Chatterbox-Multilingual-MLX-v2-fp16) via mlx-audio.
         Default voice ships in the checkpoint (pre-computed conds.safetensors); zero-shot cloning
         via a reference clip. Output is 24 kHz; /synthesize streams int16 PCM sentence-by-sentence
         so playback starts before the whole reply is generated (sub-second to first audio).
  - STT: Parakeet-TDT-0.6b-v3 via parakeet-mlx.

The Rust core calls /synthesize and /transcribe (as /v1/tts, /v1/stt). The sidecar owns output
filenames; the model never controls a path.

IMPORTANT: MLX/Metal streams are thread-local, so ALL MLX work (both model loads + every
generate/transcribe) runs on ONE dedicated single-thread executor. That also serialises generation,
avoiding unified-memory thrash with the co-resident chat model. (Same rule as media-sidecar.)
"""
import os
import re
import time
import queue
import secrets
import pathlib
import tempfile
import threading
from concurrent.futures import ThreadPoolExecutor

import numpy as np
import soundfile as sf
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import StreamingResponse
from pydantic import BaseModel

HOME = os.path.expanduser("~")
SUPPORT = pathlib.Path(
    os.environ.get("GINEXUS_AUDIO_DIR", f"{HOME}/Library/Application Support/GINEXUS/audio")
)
VOICE_DIR = pathlib.Path(
    os.environ.get("GINEXUS_VOICE_REF_DIR", f"{HOME}/Library/Application Support/GINEXUS/voices")
)
for d in (SUPPORT, VOICE_DIR):
    d.mkdir(parents=True, exist_ok=True)
    try:
        os.chmod(d, 0o700)
    except OSError:
        pass

TTS_MODEL = os.environ.get("GINEXUS_TTS_MODEL", "theoracleguy/Chatterbox-Multilingual-MLX-v2-fp16")
STT_MODEL = os.environ.get("GINEXUS_STT_MODEL", "mlx-community/parakeet-tdt-0.6b-v3")
SR = 24000  # Chatterbox / S3Gen native rate; we still read GenerationResult.sample_rate at runtime.

# One thread for everything MLX so the Metal stream stays consistent + work is serialised.
_mlx = ThreadPoolExecutor(max_workers=1, thread_name_prefix="mlx")
_tts = None
_stt = None
_tts_err = ""
_stt_err = ""


def _load_tts():
    global _tts, _tts_err
    if _tts is None:
        try:
            from mlx_audio.tts.utils import load_model
            _tts = load_model(TTS_MODEL)
            _tts_err = ""
        except Exception as e:  # noqa: BLE001 — surfaced via /healthz
            _tts_err = str(e)
            raise
    return _tts


def _load_stt():
    global _stt, _stt_err
    if _stt is None:
        try:
            from parakeet_mlx import from_pretrained
            _stt = from_pretrained(STT_MODEL)
            _stt_err = ""
        except Exception as e:  # noqa: BLE001
            _stt_err = str(e)
            raise
    return _stt


_SENT_SPLIT = re.compile(r"(.+?(?:[.!?。！?…]+|\n+|$))", re.S)


def split_sentences(text: str):
    """Sentence-ish chunks for streaming. Keeps a short first chunk → fast first audio."""
    text = text.strip()
    if not text:
        return []
    out = []
    for m in _SENT_SPLIT.finditer(text):
        s = m.group(1).strip()
        if s:
            out.append(s)
    return out or [text]


def _to_pcm16(audio) -> bytes:
    a = np.asarray(audio, dtype=np.float32).reshape(-1)
    a = np.clip(a, -1.0, 1.0)
    return (a * 32767.0).astype("<i2").tobytes()


def _resolve_voice_ref(voice_ref):
    """A clone reference is a filename inside VOICE_DIR (no traversal) or empty for the default voice."""
    if not voice_ref:
        return None
    name = pathlib.PurePath(voice_ref).name
    p = VOICE_DIR / name
    return str(p) if p.exists() else None


def synth_pcm_stream(text, lang_code="en", exaggeration=0.5, cfg_weight=0.5,
                     temperature=0.8, voice_ref=None):
    """Yield int16 PCM bytes as each sentence (and sub-chunk) is generated.

    The generation runs on the single MLX thread; chunks flow back through a queue so HTTP can
    stream them out while later audio is still being produced.
    """
    ref = _resolve_voice_ref(voice_ref)
    sentences = split_sentences(text)
    if not sentences:
        return
    q: "queue.Queue" = queue.Queue(maxsize=64)
    DONE = object()

    def worker():
        try:
            model = _load_tts()
            for sentence in sentences:
                for r in model.generate(
                    text=sentence, lang_code=lang_code, exaggeration=exaggeration,
                    cfg_weight=cfg_weight, temperature=temperature, ref_audio=ref,
                    stream=True, streaming_interval=0.5, verbose=False,
                ):
                    if getattr(r, "audio", None) is not None:
                        q.put(_to_pcm16(r.audio))
        except Exception as e:  # noqa: BLE001
            q.put(("ERR", str(e)))
        finally:
            q.put(DONE)

    _mlx.submit(worker)
    while True:
        item = q.get()
        if item is DONE:
            break
        if isinstance(item, tuple) and item and item[0] == "ERR":
            raise RuntimeError(item[1])
        yield item


def synth_to_wav(text, lang_code="en", exaggeration=0.5, cfg_weight=0.5,
                 temperature=0.8, voice_ref=None) -> dict:
    """Synthesize the whole text to a single WAV in the audio dir (the `speak` agent tool path).

    The sidecar owns the filename — the model never controls the path."""
    import datetime
    t0 = time.time()
    chunks = [np.frombuffer(b, dtype="<i2") for b in synth_pcm_stream(
        text, lang_code=lang_code, exaggeration=exaggeration, cfg_weight=cfg_weight,
        temperature=temperature, voice_ref=voice_ref)]
    if not chunks:
        raise RuntimeError("no audio generated")
    pcm = np.concatenate(chunks)
    ts = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    out = SUPPORT / f"{ts}-{secrets.token_hex(3)}.wav"
    sf.write(str(out), (pcm.astype(np.float32) / 32768.0), SR)
    return {"path": str(out), "ms": int((time.time() - t0) * 1000),
            "sample_rate": SR, "duration_s": round(len(pcm) / SR, 2)}


def transcribe_file(path: str) -> dict:
    def work():
        model = _load_stt()
        res = model.transcribe(path)
        # parakeet returns an AlignedResult; .text is "" for silence. NEVER str(res) — that leaks a
        # repr like "AlignedResult(text='', sentences=[])" which would be sent to the LLM as input.
        text = getattr(res, "text", "")
        if not isinstance(text, str):
            text = ""
        return {"text": text.strip()}
    return _mlx.submit(work).result(timeout=120)


app = FastAPI(title="ginexus-audio-sidecar")


class SynthReq(BaseModel):
    text: str
    language_id: str = "en"
    exaggeration: float = 0.5
    cfg_weight: float = 0.5
    temperature: float = 0.8
    voice_ref: str | None = None


@app.get("/healthz")
def healthz():
    return {
        "status": "ready",
        "tts": {"model": TTS_MODEL, "loaded": _tts is not None, "error": _tts_err},
        "stt": {"model": STT_MODEL, "loaded": _stt is not None, "error": _stt_err},
        "sample_rate": SR,
    }


@app.post("/warmup")
def warmup():
    errs = {}
    for name, fn in (("tts", _load_tts), ("stt", _load_stt)):
        try:
            _mlx.submit(fn).result(timeout=600)
        except Exception as e:  # noqa: BLE001
            errs[name] = str(e)
    return {"warmed": not errs, "errors": errs}


@app.get("/voices")
def voices():
    clones = sorted(p.name for p in VOICE_DIR.glob("*.wav"))
    return {"default": "builtin", "clones": clones}


@app.post("/synthesize")
def synthesize(req: SynthReq):
    text = req.text.strip()
    if not text:
        raise HTTPException(400, "empty text")

    def gen():
        try:
            yield from synth_pcm_stream(
                text, lang_code=req.language_id, exaggeration=req.exaggeration,
                cfg_weight=req.cfg_weight, temperature=req.temperature, voice_ref=req.voice_ref,
            )
        except Exception as e:  # noqa: BLE001
            # The stream has already started (200) — log; the client detects the short read.
            print(f"synthesize failed: {e}")

    return StreamingResponse(
        gen(),
        media_type="application/octet-stream",
        headers={"X-Sample-Rate": str(SR), "X-Audio-Format": "pcm_s16le_mono"},
    )


@app.post("/speak")
def speak(req: SynthReq):
    """Non-streaming: synthesize the whole text to a WAV file and return its path (agent `speak`)."""
    text = req.text.strip()
    if not text:
        raise HTTPException(400, "empty text")
    try:
        return synth_to_wav(text, lang_code=req.language_id, exaggeration=req.exaggeration,
                            cfg_weight=req.cfg_weight, temperature=req.temperature,
                            voice_ref=req.voice_ref)
    except Exception as e:  # noqa: BLE001
        raise HTTPException(500, f"synthesis failed: {e}")


@app.post("/transcribe")
async def transcribe(request: Request):
    """Body = raw WAV bytes (any sample rate; soundfile + parakeet handle resampling)."""
    body = await request.body()
    if not body:
        raise HTTPException(400, "empty body")
    tmp = pathlib.Path(tempfile.gettempdir()) / f"ginexus-stt-{secrets.token_hex(4)}.wav"
    try:
        tmp.write_bytes(body)
        return transcribe_file(str(tmp))
    except Exception as e:  # noqa: BLE001
        raise HTTPException(500, f"transcription failed: {e}")
    finally:
        tmp.unlink(missing_ok=True)


# Warm both models on the MLX thread at startup so the first real turn is fast. Opt-in via env.
if os.environ.get("GINEXUS_AUDIO_PRELOAD") == "1":
    def _preload():
        for fn in (_load_tts, _load_stt):
            try:
                _mlx.submit(fn).result()
            except Exception:
                pass  # /healthz surfaces the error
    threading.Thread(target=_preload, daemon=True).start()
