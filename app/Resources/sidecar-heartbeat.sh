#!/usr/bin/env bash
# SP1.5 tracer-bullet "sidecar": shipped INSIDE the .app bundle (Contents/Resources) and
# spawned by the signed app to prove bundle-relative child-process launch + TCC attribution.
# In SP2 this is replaced by the real UDS FastAPI sidecar (run_sandboxed.sh from MTX-NEXUS).
# Writes a timestamped heartbeat to $1 each second.
HB="${1:?heartbeat path}"
echo "sidecar up (pid $$) $(date '+%H:%M:%S')" >> "$HB"
while true; do
  echo "heartbeat $(date '+%H:%M:%S') pid=$$" >> "$HB"
  sleep 1
done
