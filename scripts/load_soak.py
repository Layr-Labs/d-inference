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

# A long, fixed "system prompt" base. Repeated to a multi-hundred-token block
# whose KV crosses the model's checkpoint boundaries (Gemma window 1024 ->
# boundaries [256, 512, 1024]) and is therefore worth caching and reusing.
_BASE = (
    "You are a meticulous senior systems engineer assisting with a long-running "
    "distributed inference service. Follow these standing instructions precisely "
    "on every reply. Be concise, technically exact, and never speculate beyond "
    "the evidence. When asked about latency, always distinguish prefill from "
    "decode. When asked about memory, distinguish weights from KV cache from "
    "activations. When asked about correctness, state the invariant first, then "
    "the mechanism that upholds it, then the failure mode if it were violated. "
    "Prefer first principles; enumerate the full state space before concluding. "
    "Treat every cache, key, and file as a security boundary. "
)
SHARED_PREFIX = _BASE * 6  # ~ several hundred tokens of stable prefix


# Calibration: tokens produced per `_BASE` repeat, measured against the real
# server tokenizer (usage.prompt_tokens). Default is a conservative estimate;
# override with --tokens-per-base after a one-shot calibration request so
# --prompt-tokens lands close to the intended length (and crosses the intended
# checkpoint boundaries). gpt-oss past-window ladder = 2048/4096/8192/...; a
# ~4-8k-token prefix crosses several of those, exercising the proven bit-exact
# restore PAST the 128-token sliding window.
DEFAULT_TOKENS_PER_BASE = 140.0


def repeats_for_tokens(target_tokens, tokens_per_base):
    """How many _BASE repeats approximate `target_tokens`. >=1."""
    if target_tokens <= 0:
        return None
    return max(1, round(target_tokens / max(1.0, tokens_per_base)))


def build_prefix_pool(pool_size, repeat):
    """K DISTINCT long prefixes. Each is the common base repeated `repeat` times
    plus a pool-unique tag, so every prefix is its own cacheable checkpoint chain
    but they all cross the same boundaries. Reusing a pool member across requests
    drives: 1st use -> RAM store; 2nd use -> SSD promotion (write-back); reuse
    after RAM eviction -> SSD reload (decrypt). With pool_size * file_bytes >
    DISK_GB the SSD disk-eviction path engages too.

    For the SHORT-window models (gpt-oss window=128) a large `repeat` (long
    prefix) is what crosses the past-window ladder; for Gemma (window=1024) the
    Gemma run used repeat=6 (~700 tok) to cross 256/512."""
    pool = []
    for i in range(pool_size):
        # Tag FIRST so the prefixes diverge from token 0 (distinct digests at
        # every checkpoint boundary), then the shared instruction body.
        pool.append(f"[session-context #{i:04d}] " + (_BASE * repeat))
    return pool


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


def make_prompt(args, n, pool):
    """Return (messages, kind).

    Two regimes:

    * pool mode (--prefix-pool > 0, the soak default): pick one of K distinct
      long prefixes and append a tiny unique suffix. Repeated selection of the
      same prefix drives RAM-store -> SSD-promotion -> (after eviction)
      SSD-reload/decrypt; K large enough vs DISK_GB drives SSD disk-eviction.
      A small `--unique-fraction` of requests use a one-off long prompt for
      churn so the pool members keep getting evicted and reloaded.

      --rotate flips selection from RANDOM to ROUND-ROBIN (idx = n % K). With a
      pool LARGER than the RAM tier, round-robin guarantees that by the time a
      prefix comes around again it has been RAM-evicted, so every touch after
      the first cycle is a RAM-miss + SSD reload (decrypt) — the heaviest SSD
      stress, which a high-hit-rate model (gpt-oss ~99% under random reuse)
      otherwise never produces because the hot set stays RAM-resident.

    * legacy mode (--prefix-pool 0): the original shared/diverse split, kept for
      back-compat with the simple smoke test.
    """
    if pool:
        if args.unique_fraction > 0 and random.random() < args.unique_fraction:
            filler = " ".join(f"token{random.randint(0, 1_000_000)}" for _ in range(args.diverse_words))
            content = f"Unique request {n} {filler}. In one sentence, describe a distributed cache."
            return [{"role": "user", "content": content}], "unique"
        idx = (n % len(pool)) if args.rotate else random.randint(0, len(pool) - 1)
        suffix = f" [q{n}] In one sentence, summarize the standing instructions above."
        return [{"role": "user", "content": pool[idx] + suffix}], f"pool{idx}"
    # legacy shared/diverse split
    if random.random() < args.shared_fraction:
        suffix = f" Question #{n % args.shared_variants}: summarize the above in one sentence."
        return [{"role": "user", "content": SHARED_PREFIX + suffix}], "shared"
    filler = " ".join(f"token{random.randint(0, 1_000_000)}" for _ in range(args.diverse_words))
    content = f"Unique request {n} {filler}. In one sentence, describe a distributed cache."
    return [{"role": "user", "content": content}], "diverse"


def do_request(args, n, stats, pool):
    messages, _kind = make_prompt(args, n, pool)
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
    p.add_argument("--prefix-pool", type=int, default=48,
                   help="POOL MODE (soak default): number of DISTINCT long prefixes "
                        "reused across requests. Each promotes to SSD on 2nd use; "
                        "pool_size * file_bytes > DISK_GB forces SSD eviction; reuse "
                        "after RAM/SSD eviction forces decrypt-reload. 0 = legacy "
                        "shared/diverse mode.")
    p.add_argument("--prefix-repeat", type=int, default=6,
                   help="how many times the instruction base is repeated per pool "
                        "prefix (controls prefix length / checkpoint chain depth)")
    p.add_argument("--prompt-tokens", type=int, default=0,
                   help="TARGET prefix length in tokens; when >0 it overrides "
                        "--prefix-repeat (repeat = round(prompt-tokens / tokens-per-base)). "
                        "Use ~4000-8000 for gpt-oss to cross the past-window ladder "
                        "(2048/4096/8192).")
    p.add_argument("--tokens-per-base", type=float, default=DEFAULT_TOKENS_PER_BASE,
                   help="measured tokens produced per _BASE repeat for the target "
                        "model's tokenizer; calibrate once (usage.prompt_tokens) so "
                        "--prompt-tokens lands accurately.")
    p.add_argument("--unique-fraction", type=float, default=0.15,
                   help="pool mode: fraction of requests that are one-off long prompts "
                        "(churn so pool members keep getting evicted and reloaded)")
    p.add_argument("--rotate", action="store_true",
                   help="pool mode: ROUND-ROBIN through the pool (idx = n %% K) instead "
                        "of random. With pool > RAM-tier capacity this guarantees every "
                        "post-first-cycle touch is a RAM-miss + SSD reload (max SSD stress).")
    p.add_argument("--shared-fraction", type=float, default=0.70,
                   help="legacy mode: fraction using the single shared long prefix")
    p.add_argument("--shared-variants", type=int, default=8,
                   help="legacy mode: number of distinct shared-prefix suffixes")
    p.add_argument("--diverse-words", type=int, default=400,
                   help="filler words per unique/diverse prompt (drives stores + eviction)")
    p.add_argument("--request-timeout", type=float, default=600.0)
    p.add_argument("--report-every-seconds", type=float, default=60.0)
    p.add_argument("--out", default="soak_client.csv")
    args = p.parse_args()

    # --prompt-tokens (if set) overrides --prefix-repeat via the calibration.
    effective_repeat = args.prefix_repeat
    if args.prompt_tokens > 0:
        effective_repeat = repeats_for_tokens(args.prompt_tokens, args.tokens_per_base)
    pool = build_prefix_pool(args.prefix_pool, effective_repeat) if args.prefix_pool > 0 else []

    stats = Stats()
    deadline = time.monotonic() + args.duration_minutes * 60.0
    stop = threading.Event()
    counter = {"n": 0}
    clock = {"start": time.monotonic()}

    # Context manager so the CSV handle is always closed deterministically,
    # even if an exception fires during setup or the soak run.
    with open(args.out, "w", newline="") as fout:
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
                do_request(args, n, stats, pool)

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

        if pool:
            tok = f" ~{args.prompt_tokens}tok" if args.prompt_tokens > 0 else ""
            mode = f"pool={args.prefix_pool}x(base*{effective_repeat}{tok}) unique={args.unique_fraction:.0%}"
        else:
            mode = f"legacy shared={args.shared_fraction:.0%}"
        print(f"soak: {args.duration_minutes}min @ concurrency={args.concurrency} "
              f"model={args.model} {mode} -> {args.out}", flush=True)
        rep = threading.Thread(target=reporter, daemon=True)
        rep.start()
        try:
            with ThreadPoolExecutor(max_workers=args.concurrency) as ex:
                for _ in range(args.concurrency):
                    ex.submit(worker)
                while time.monotonic() < deadline and not stop.is_set():
                    time.sleep(1.0)
        except KeyboardInterrupt:
            print("\ninterrupted — draining", flush=True)
        finally:
            stop.set()
            time.sleep(0.2)
            fout.flush()  # the `with` closes the handle on exit (incl. SystemExit)
            print(f"\nDONE: cum_ok={stats.total_ok} cum_err={stats.total_err} "
                  f"cum_tokens={stats.total_tokens}. CSV: {args.out}", flush=True)
            sys.exit(1 if stats.total_ok == 0 else 0)


if __name__ == "__main__":
    main()
