"""Round-trip smoke test: TTS a known phrase, STT it back, check overlap. Also reports latency."""
import time, pathlib, numpy as np, soundfile as sf
from server import synth_pcm_stream, transcribe_file, SR

TEXT = "Hello, this is a test of the GINEXUS local voice system. The quick brown fox jumps over the lazy dog."

t0 = time.time()
first = None
chunks = []
for b in synth_pcm_stream(TEXT):
    if first is None:
        first = time.time() - t0
    chunks.append(np.frombuffer(b, dtype="<i2"))
total = time.time() - t0
pcm = np.concatenate(chunks)
dur = len(pcm) / SR
print(f"TTS: first_audio={first:.2f}s total={total:.2f}s audio_dur={dur:.2f}s RTF={total/dur:.2f}")

out = pathlib.Path("/tmp/ginexus_smoke.wav")
sf.write(str(out), (pcm.astype(np.float32) / 32768.0), SR)
print(f"wrote {out}")

t0 = time.time()
res = transcribe_file(str(out))
print(f"STT ({time.time()-t0:.2f}s): {res['text']!r}")

# crude overlap check
said = set(w.strip(".,!?").lower() for w in TEXT.split())
heard = set(w.strip(".,!?").lower() for w in res["text"].split())
overlap = len(said & heard) / max(1, len(said))
print(f"word overlap: {overlap:.0%}")
print("RESULT:", "PASS" if overlap >= 0.6 else "FAIL")
