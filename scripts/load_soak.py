#!/usr/bin/env python3
"""
SSD KV-cache stress soak driver — duration-based, stdlib-only (no aiohttp).

Drives a standalone `darkbloom start --local` OpenAI endpoint for a fixed
DURATION with a prompt mix designed to exercise the encrypted SSD prefix cache:

  * SHARED-prefix requests (default 70%): a long fixed system-prompt prefix +
    a small varying suffix. Repeated submission of the same prefix drives
    2nd-use SSD promotion, cache HITS, and reload-from-SSD.
  * DIVERSE-prefix requests (default 30%): a unique long prompt each time.
    Drives STORES -> on-disk growth -> benefit-per-byte EVICTION under a tight
    DARKBLOOM_PREFIX_CACHE_DISK_GB.

Cache hit/miss is NOT exposed over HTTP (X-Timing carries no cache field), so
this driver only measures client-visible signals (TTFB, total time, tokens,
errors). Pair it with cache_soak_monitor.sh on the provider box, which reads the
provider logs + on-disk kv/ tree for the actual cache behavior.

Python 3.9+, standard library only. Concurrency via a thread pool (blocking
urllib per worker) — fine for the modest request rates of a 4h soak.

Usage:
  python3 load_soak.py --base-url http://127.0.0.1:8000/v1 \
      --model gemma-4-26b-a4b-it-8bit --duration-minutes 240 \
      --concurrency 4 --max-tokens 128 --report-every-seconds 60 \
      --out soak_client.csv
  # add --api-key KEY if the endpoint was NOT started with --no-auth
"""
import argparse
import csv
import json
import os
import random
import statistics
import sys
import threading
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor

# A long, fixed "system prompt" used by the SHARED-prefix requests. The point is
# a stable, multi-hundred-token prefix whose KV is worth caching and reusing.
SHARED_PREFIX = (
    "You are a meticulous senior systems engineer assisting with a long-running "
    "distributed inference service. Follow these standing instructions precisely "
    "on every reply. Be concise, technically exact, and never speculate beyond "
    "the evidence. When asked about latency, always distinguish prefill from "
    "decode. When asked about memory, distinguish weights from KV cache from "
    "activations. When asked about correctness, state the invariant first, then "
    "the mechanism that upholds it, then the failure mode if it were violated. "
    "Prefer first principles; enumerate the full state space before concluding. "
    "Treat every cache, key, and file as a security boundary. "
) * 6  # ~ several hundred tokens of stable prefix


def _percentile(values, pct):
    if not values:
        return 0.0
    s = sorted(values)
    k = (len(s) - 1) * (pct / 100.0)
    f = int(k)
    c = min(f + 1, len(s) - 1)
    if f == c:
        return s[f]
    return s[f] + (s[c] - s[f]) * (k - f)


class Stats:
    """Thread-safe rolling stats for one reporting window + cumulative totals."""

    def __init__(self):
        self.lock = threading.Lock()
        self.reset_window()
        self.total_ok = 0
        self.total_err = 0
        self.total_tokens = 0

    def reset_window(self):
        self.w_ttfb = []
        self.w_total = []
        self.w_ok = 0
        self.w_err = 0
        self.w_tokens = 0
        self.w_err_kinds = {}

    def record_ok(self, ttfb, total, tokens):
        with self.lock:
            self.w_ttfb.append(ttfb)
            self.w_total.append(total)
            self.w_ok += 1
            self.w_tokens += tokens
            self.total_ok += 1
            self.total_tokens += tokens

    def record_err(self, kind):
        with self.lock:
            self.w_err += 1
            self.total_err += 1
            self.w_err_kinds[kind] = self.w_err_kinds.get(kind, 0) + 1

    def snapshot_and_reset(self, window_secs):
        with self.lock:
            ok, err, toks = self.w_ok, self.w_err, self.w_tokens
            ttfb, tot, kinds = self.w_ttfb, self.w_total, dict(self.w_err_kinds)
            self.reset_window()
        return {
            "ok": ok,
            "err": err,
            "req_per_s": round((ok + err) / window_secs, 3),
            "tok_per_s": round(toks / window_secs, 2),
            "ttfb_p50": round(_percentile(ttfb, 50), 4),
            "ttfb_p95": round(_percentile(ttfb, 95), 4),
            "ttfb_p99": round(_percentile(ttfb, 99), 4),
            "total_p50": round(_percentile(tot, 50), 4),
            "total_p95": round(_percentile(tot, 95), 4),
            "err_kinds": kinds,
        }


def make_prompt(args, n):
    """Return (messages, is_shared). Shared = long stable prefix + tiny suffix."""
    if random.random() < args.shared_fraction:
        suffix = f" Question #{n % args.shared_variants}: summarize the above in one sentence."
        content = SHARED_PREFIX + suffix
        return [{"role": "user", "content": content}], True
    # Diverse: a unique long prompt (drives stores + eviction).
    filler = " ".join(f"token{random.randint(0, 1_000_000)}" for _ in range(args.diverse_words))
    content = f"Unique request {n} {filler}. In one sentence, describe a distributed cache."
    return [{"role": "user", "content": content}], False


def do_request(args, n, stats):
    messages, _shared = make_prompt(args, n)
    body = json.dumps({
        "model": args.model,
        "messages": messages,
        "max_tokens": args.max_tokens,
        "temperature": 0.0,
        "stream": False,
    }).encode()
    req = urllib.request.Request(
        args.base_url.rstrip("/") + "/chat/completions",
        data=body, method="POST",
        headers={"Content-Type": "application/json",
                 **({"Authorization": f"Bearer {args.api_key}"} if args.api_key else {})},
    )
    start = time.monotonic()
    try:
        with urllib.request.urlopen(req, timeout=args.request_timeout) as resp:
            raw = resp.read()
        elapsed = time.monotonic() - start
        try:
            data = json.loads(raw)
            tokens = int(data.get("usage", {}).get("completion_tokens", 0))
        except Exception:
            tokens = 0
        # Non-streaming: TTFB == total (no first-chunk signal). Kept distinct so
        # a future streaming mode can populate ttfb separately.
        stats.record_ok(ttfb=elapsed, total=elapsed, tokens=tokens)
    except urllib.error.HTTPError as e:
        stats.record_err(f"http_{e.code}")
    except urllib.error.URLError as e:
        stats.record_err(f"urlerr_{type(e.reason).__name__}")
    except Exception as e:
        stats.record_err(f"exc_{type(e).__name__}")


def main():
    p = argparse.ArgumentParser(description="SSD KV-cache stress soak driver (stdlib-only)")
    p.add_argument("--base-url", default="http://127.0.0.1:8000/v1")
    p.add_argument("--model", required=True)
    p.add_argument("--api-key", default=os.environ.get("OPENAI_API_KEY"))
    p.add_argument("--duration-minutes", type=float, default=240.0)
    p.add_argument("--concurrency", type=int, default=4)
    p.add_argument("--max-tokens", type=int, default=128)
    p.add_argument("--shared-fraction", type=float, default=0.70,
                   help="fraction of requests using the shared long prefix (cache hits)")
    p.add_argument("--shared-variants", type=int, default=8,
                   help="number of distinct shared-prefix suffixes (each a reusable checkpoint)")
    p.add_argument("--diverse-words", type=int, default=400,
                   help="filler words per diverse prompt (drives stores + eviction)")
    p.add_argument("--request-timeout", type=float, default=600.0)
    p.add_argument("--report-every-seconds", type=float, default=60.0)
    p.add_argument("--out", default="soak_client.csv")
    args = p.parse_args()

    stats = Stats()
    deadline = time.monotonic() + args.duration_minutes * 60.0
    stop = threading.Event()
    counter = {"n": 0}
    clock = {"start": time.monotonic()}

    fout = open(args.out, "w", newline="")
    writer = csv.writer(fout)
    writer.writerow(["elapsed_s", "ok", "err", "req_per_s", "tok_per_s",
                     "ttfb_p50", "ttfb_p95", "ttfb_p99", "total_p50", "total_p95",
                     "cum_ok", "cum_err", "err_kinds"])
    fout.flush()

    def worker():
        while not stop.is_set() and time.monotonic() < deadline:
            with stats.lock:
                counter["n"] += 1
                n = counter["n"]
            do_request(args, n, stats)

    def reporter():
        last = time.monotonic()
        while not stop.is_set() and time.monotonic() < deadline:
            stop.wait(args.report_every_seconds)
            now = time.monotonic()
            window = now - last
            last = now
            if window <= 0:
                continue
            snap = stats.snapshot_and_reset(window)
            elapsed = round(now - clock["start"], 1)
            line = [elapsed, snap["ok"], snap["err"], snap["req_per_s"],
                    snap["tok_per_s"], snap["ttfb_p50"], snap["ttfb_p95"],
                    snap["ttfb_p99"], snap["total_p50"], snap["total_p95"],
                    stats.total_ok, stats.total_err, json.dumps(snap["err_kinds"])]
            writer.writerow(line)
            fout.flush()
            print(f"[{elapsed:8.0f}s] ok={snap['ok']:4d} err={snap['err']:3d} "
                  f"req/s={snap['req_per_s']:6.2f} tok/s={snap['tok_per_s']:7.1f} "
                  f"ttfb p50/p95/p99={snap['ttfb_p50']:.2f}/{snap['ttfb_p95']:.2f}/{snap['ttfb_p99']:.2f}s "
                  f"cum_err={stats.total_err}"
                  + (f"  ERR={snap['err_kinds']}" if snap['err_kinds'] else ""),
                  flush=True)

    print(f"soak: {args.duration_minutes}min @ concurrency={args.concurrency} "
          f"model={args.model} shared={args.shared_fraction:.0%} -> {args.out}", flush=True)
    rep = threading.Thread(target=reporter, daemon=True)
    rep.start()
    try:
        with ThreadPoolExecutor(max_workers=args.concurrency) as pool:
            for _ in range(args.concurrency):
                pool.submit(worker)
            while time.monotonic() < deadline and not stop.is_set():
                time.sleep(1.0)
    except KeyboardInterrupt:
        print("\ninterrupted — draining", flush=True)
    finally:
        stop.set()
        time.sleep(0.2)
        fout.flush(); fout.close()
        print(f"\nDONE: cum_ok={stats.total_ok} cum_err={stats.total_err} "
              f"cum_tokens={stats.total_tokens}. CSV: {args.out}", flush=True)
        sys.exit(1 if stats.total_ok == 0 else 0)


if __name__ == "__main__":
    main()
