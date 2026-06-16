"""GINEXUS media sidecar — local image generation via mflux / Z-Image-Turbo on Apple MLX.

Bound to loopback only. The Rust core calls POST /generate as the `image_generate` tool; the
sidecar owns filenames + writes PNGs into the app-owned media dir (the model never controls the
output path). Model: Tongyi-MAI/Z-Image-Turbo (Apache-2.0), integer quant (-q 8, never FP8).

IMPORTANT: MLX/Metal streams are thread-local, so ALL MLX work (load + every generate) runs on ONE
dedicated single-thread executor. That also serialises generation (concurrency=1), avoiding unified-
memory thrash with the co-resident 30B chat model.
"""
import os
import time
import secrets
import datetime
import pathlib
import threading
from concurrent.futures import ThreadPoolExecutor

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel

HOME = os.path.expanduser("~")
MEDIA_DIR = pathlib.Path(
    os.environ.get("GINEXUS_MEDIA_DIR", f"{HOME}/Library/Application Support/GINEXUS/media")
)
MEDIA_DIR.mkdir(parents=True, exist_ok=True)
try:
    os.chmod(MEDIA_DIR, 0o700)
except OSError:
    pass

QUANT = int(os.environ.get("GINEXUS_MEDIA_QUANT", "8"))   # integer quant only — avoids FP8 crash class
ALLOWED_MODELS = {"z-image-turbo"}
MAX_DIM = 1536

# One thread for everything MLX so the Metal stream stays consistent + generation is serialised.
_mlx = ThreadPoolExecutor(max_workers=1, thread_name_prefix="mlx")
_model = None
_model_loaded = False
_load_error = ""


def _do_load():
    """Lazy single load of Z-Image-Turbo (downloads weights once, then caches). Runs on _mlx."""
    global _model, _model_loaded, _load_error
    if _model is None:
        try:
            from mflux.models.z_image.variants.z_image import ZImage
            from mflux.models.common.config import ModelConfig
            _model = ZImage(model_config=ModelConfig.z_image_turbo(), quantize=QUANT)
            _model_loaded = True
            _load_error = ""
        except Exception as e:  # noqa: BLE001 — surfaced via /healthz
            _load_error = str(e)
            raise
    return _model


def _do_generate(prompt, w, h, seed, steps, out_path):
    """Runs on _mlx (same thread as the load → valid Metal stream)."""
    model = _do_load()
    image = model.generate_image(
        seed=seed, prompt=prompt, width=w, height=h, num_inference_steps=steps
    )
    image.save(path=out_path, export_json_metadata=True)  # recipe embedded for reproducibility
    return out_path


app = FastAPI(title="ginexus-media-sidecar")


class GenReq(BaseModel):
    prompt: str
    width: int = 1024
    height: int = 1024
    seed: int | None = None
    steps: int = 9
    model: str = "z-image-turbo"


@app.get("/healthz")
def healthz():
    return {"status": "ready", "engine": "mflux", "model": "z-image-turbo",
            "model_loaded": _model_loaded, "load_error": _load_error}


@app.post("/generate")
def generate(req: GenReq):
    if req.model not in ALLOWED_MODELS:
        raise HTTPException(400, f"model not allowed: {req.model}")
    prompt = req.prompt.strip()
    if not prompt:
        raise HTTPException(400, "empty prompt")
    w = max(256, min(MAX_DIM, req.width))
    h = max(256, min(MAX_DIM, req.height))
    steps = max(1, min(20, req.steps))
    seed = req.seed if req.seed is not None else secrets.randbelow(2**31)
    ts = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    out = MEDIA_DIR / f"{ts}-{secrets.token_hex(3)}.png"

    t0 = time.time()
    try:
        _mlx.submit(_do_generate, prompt, w, h, seed, steps, str(out)).result(timeout=300)
    except Exception as e:  # noqa: BLE001
        raise HTTPException(500, f"generation failed: {e}")
    return {"path": str(out), "seed": seed, "width": w, "height": h,
            "steps": steps, "ms": int((time.time() - t0) * 1000)}


# Warm the model on the MLX thread at startup so the first chat-time request doesn't stall on a
# cold load. Opt-in via env so tests can skip it.
if os.environ.get("GINEXUS_MEDIA_PRELOAD") == "1":
    def _preload():
        try:
            _mlx.submit(_do_load).result()
        except Exception:
            pass  # /healthz surfaces load_error
    threading.Thread(target=_preload, daemon=True).start()
