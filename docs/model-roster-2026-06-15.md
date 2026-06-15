# GINEXUS Model Roster — 2026-06-15

> **Dated, replaceable.** Models move fast; this file is the single place to update the concrete
> picks. The master design carries only *policy* (tiering, license rules, engineering constraints).
> **Re-scan the HuggingFace Hub before locking** (researched June 2026; newer generations exist).
> SP1 records pinned HF revision SHAs + quant provenance in `models.lock` and flips
> `verify_lock(strict=True)`.

**Target hardware:** Apple M2 Ultra, 192 GB unified memory (`iogpu.wired_limit_mb` ≈ 144 GB default).
**Default roster license bar:** Apache-2.0 / MIT (commercial-safe for the GiNexus product). Parakeet
is CC-BY-4.0 (attribute NVIDIA).

| Capability | Default | HF repo (MLX) | Runtime | License |
|---|---|---|---|---|
| Chat & reasoning | **Qwen3-30B-A3B-Instruct-2507** | `Qwen/Qwen3-30B-A3B-Instruct-2507` → `mlx-community/Qwen3-30B-A3B-Instruct-2507-4bit` | MLX / Ollama | Apache-2.0 |
| Agentic tool-calling | Qwen3-30B-A3B + **Qwen3-Coder-30B-A3B** (code lane) | `Qwen/Qwen3-Coder-30B-A3B-Instruct` | MLX, smolagents/tiny-agents | Apache-2.0 |
| Hard reasoning (escalate, hot-load) | **gpt-oss-120b** (~63 GB MXFP4) | `openai/gpt-oss-120b` → `mlx-community/gpt-oss-120b-MXFP4-Q8` | MLX / Ollama | Apache-2.0 |
| Fast / glue / router | gpt-oss-20b · **Qwen3-4B-Instruct-2507** | `openai/gpt-oss-20b`, `Qwen/Qwen3-4B-Instruct-2507` | MLX / Ollama | Apache-2.0 |
| Vision (VLM) | **Qwen3-VL-8B-Instruct** (escalate 30B-A3B) | `Qwen/Qwen3-VL-8B-Instruct` | mlx-vlm | Apache-2.0 |
| Embeddings | **Qwen3-Embedding-0.6B** (8B if SP3 retrieval-eval shows under-recall) | `Qwen/Qwen3-Embedding-0.6B` | MLX / Ollama | Apache-2.0 |
| Reranker | **Qwen3-Reranker-0.6B** | `Qwen/Qwen3-Reranker-0.6B` | MLX | Apache-2.0 |
| Image gen | **Z-Image-Turbo** (Qwen-Image-2512 for CJK text) | `Tongyi-MAI/Z-Image-Turbo` | mflux (MLX) / ComfyUI | Apache-2.0 |
| Video gen | **Wan2.2-TI2V-5B** (local batch) → **API for interactive** | `Wan-AI/Wan2.2-TI2V-5B-Diffusers` | ComfyUI-GGUF / diffusers-MPS | Apache-2.0 |
| STT | **Parakeet-TDT-0.6b-v3** (Whisper-v3-turbo for CJK) | `mlx-community/parakeet-tdt-0.6b-v3` | MLX (parakeet-mlx) | CC-BY-4.0 (attribute NVIDIA) |
| TTS | **Kokoro-82M** (Chatterbox for clone/Japanese) | `mlx-community/Kokoro-82M-bf16` | MLX / CoreML-ANE | Apache-2.0 |

## MoE sizing note
Model metadata must carry **total params** (→ memory residency) and **active params** (→ latency)
separately. Qwen3-30B-A3B = 30B resident / ~3.3B active; gpt-oss-120b = ~63 GB resident MXFP4.

## Memory-budget reality (SP1 must measure, not estimate)
Resident **weights** ≠ working set. The SP1 installer produces a measured budget table:
`weights + KV-cache(context × concurrency) + activation headroom + media model + OS/app reserve`,
evaluated against `iogpu.wired_limit_mb` (~144 GB, not 192 GB). Example: Qwen3-30B KV at 128k ctx is
~12.9 GB by itself. State explicitly whether gpt-oss-120b **co-resides or evicts**; surface its
~9–13 s cold-load in the auto-mode heuristics.

## License policy (product-clean)
- **Default roster = Apache-2.0/MIT only.** Attribute NVIDIA for Parakeet (CC-BY-4.0).
- **Internal-only / gated (buy license to ship outputs):** FLUX.1/2-dev, FLUX-Krea, FLUX.2-klein-9B.
- **Revenue-capped:** SD3.5 (Stability Community License terminates > $1M ARR).
- **Restricted (legal review before commercial):** LTX-Video, HunyuanVideo, CogVideoX-5b, Gemma family, Llama community license, Qwen2.5-VL-72B, InternVL3 1B/2B/8B.
- **Avoid in product (non-commercial):** jina-embeddings-v3, xLAM-2, XTTS-v2, Spark-TTS, Moonshine non-English flavors.

## Engineering constraints
- **Reject native-FP8 checkpoints** (`Float8_e4m3fn` / `e5m2`) the MLX runtime cannot dequantize;
  prefer INT4/INT8 and the model's native MXFP4. **MXFP4 (gpt-oss) is a 4-bit micro-scaled format
  and is NOT FP8** — it is allowed.
- Strict JSON-schema validation on all tool calls.
- Consolidate to one local OpenAI-compatible server.
- Every rostered quant must pass the SP1/SP2 eval harness (schema adherence + reasoning golden set +
  injection corpus) vs its fp16/API reference before it is selectable in auto-mode.
