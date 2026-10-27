"""Sequential cold-prompt TTFT probe for the FIRST requests after process start.

Usage: first_ttft.py --base URL --key KEY --model ID --plan 8192,8192,8192 [--gap 3] [--max-tokens 16]

Every request starts with a unique nonce, so nothing beyond the chat-template header can be reused.
No warmup request is sent: request #1 is the first customer-shaped request the engine sees.
Prints one JSON line per request and a final summary line.
"""
import argparse
import json
import random
import string
import time
import urllib.request

WORDS = ("alpha beta gamma delta epsilon zeta theta iota kappa lambda river mountain forest "
         "engine kernel matrix vector token cache memory signal window layer expert router "
         "prefill decode latency throughput budget schedule thread queue stream buffer").split()


def make_text(approx_tokens, rng):
    n = max(1, int(approx_tokens / 1.3))
    return " ".join(rng.choice(WORDS) for _ in range(n))


def stream_request(base, key, model, content, max_tokens, temperature):
    body = {
        "model": model,
        "messages": [{"role": "user", "content": content}],
        "max_tokens": max_tokens,
        "stream": True,
        "stream_options": {"include_usage": True},
    }
    if temperature is not None:
        body["temperature"] = temperature
    req = urllib.request.Request(base.rstrip("/") + "/chat/completions", data=json.dumps(body).encode(),
                                 method="POST",
                                 headers={"Content-Type": "application/json", "Authorization": f"Bearer {key}"})
    t0 = time.perf_counter()
    first = last = None
    chunks = 0
    usage = None
    text = []
    with urllib.request.urlopen(req, timeout=900) as resp:
        for raw in resp:
            line = raw.decode("utf-8", "replace").strip()
            if not line.startswith("data:"):
                continue
            payload = line[5:].strip()
            if payload == "[DONE]":
                break
            try:
                obj = json.loads(payload)
            except Exception:
                continue
            if obj.get("usage"):
                usage = obj["usage"]
            for ch in obj.get("choices", []):
                d = ch.get("delta") or {}
                txt = (d.get("content") or "") + (d.get("reasoning_content") or d.get("reasoning") or "")
                if txt:
                    now = time.perf_counter()
                    if first is None:
                        first = now
                    last = now
                    chunks += 1
                    text.append(txt)
    t_end = time.perf_counter()
    dec = (chunks - 1) / (last - first) if first and last and chunks > 1 and last > first else None
    return {"ttft_ms": round((first - t0) * 1000, 1) if first else None,
            "total_ms": round((t_end - t0) * 1000, 1), "chunks": chunks,
            "decode_chunks_per_s": round(dec, 1) if dec else None,
            "prompt_tokens": (usage or {}).get("prompt_tokens"), "text": "".join(text)[:160]}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", required=True)
    ap.add_argument("--key", required=True)
    ap.add_argument("--model", required=True)
    ap.add_argument("--plan", default="8192,8192,8192")
    ap.add_argument("--gap", type=float, default=3.0)
    ap.add_argument("--max-tokens", type=int, default=16)
    ap.add_argument("--temperature", type=float, default=None)
    ap.add_argument("--seed", type=int, default=None)
    ap.add_argument("--tag", default="")
    args = ap.parse_args()
    rng = random.Random(args.seed if args.seed is not None else time.time_ns())
    results = []
    for i, L in enumerate(int(x) for x in args.plan.split(",")):
        if i:
            time.sleep(args.gap)
        nonce = "".join(rng.choice(string.ascii_letters + string.digits) for _ in range(24))
        content = f"[{nonce}] " + make_text(L, rng) + "\nSummarize the text above in one sentence."
        res = stream_request(args.base, args.key, args.model, content, args.max_tokens, args.temperature)
        res.update({"idx": i, "target_tokens": L, "tag": args.tag})
        results.append(res)
        print(json.dumps(res), flush=True)
    print(json.dumps({"summary": args.tag, "ttft_ms": [r["ttft_ms"] for r in results],
                      "prompt_tokens": [r["prompt_tokens"] for r in results]}), flush=True)


if __name__ == "__main__":
    main()
