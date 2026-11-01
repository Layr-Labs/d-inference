"""Self-test proxy: one streaming "Hi" request with max_tokens=1 (what the coordinator-mode
startup self-test sends). Prints {"hi_total_ms": ..., "hi_first_ms": ...}."""
import argparse
import json
import time
import urllib.request

ap = argparse.ArgumentParser()
ap.add_argument("--base", required=True)
ap.add_argument("--key", required=True)
ap.add_argument("--model", required=True)
args = ap.parse_args()
body = {"model": args.model, "messages": [{"role": "user", "content": "Hi"}], "max_tokens": 1,
        "temperature": 0, "stream": True}
req = urllib.request.Request(args.base.rstrip("/") + "/chat/completions", data=json.dumps(body).encode(),
                             method="POST",
                             headers={"Content-Type": "application/json", "Authorization": f"Bearer {args.key}"})
t0 = time.perf_counter()
first = None
with urllib.request.urlopen(req, timeout=600) as resp:
    for raw in resp:
        line = raw.decode("utf-8", "replace").strip()
        if line.startswith("data:") and first is None and '"choices"' in line:
            first = time.perf_counter()
        if line == "data: [DONE]":
            break
t1 = time.perf_counter()
print(json.dumps({"hi_total_ms": round((t1 - t0) * 1000, 1),
                  "hi_first_ms": round((first - t0) * 1000, 1) if first else None}))
