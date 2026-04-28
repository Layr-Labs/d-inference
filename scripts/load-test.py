#!/usr/bin/env python3
"""
Darkbloom network load test — escalating concurrency.

Usage:
    export EIGENINFERENCE_API_KEY="your-key"
    python3 scripts/load-test.py                          # defaults: qwen3.5, levels 1,2,4,8,16
    python3 scripts/load-test.py --model gemma-4          # short alias
    python3 scripts/load-test.py --levels 1 2 4 8         # custom concurrency ramp
    python3 scripts/load-test.py --requests-per-level 5   # requests per concurrency level
    python3 scripts/load-test.py --prompt "Explain gravity in 2 sentences"
"""

import argparse
import asyncio
import json
import os
import sys
import time
from dataclasses import dataclass, field

try:
    import aiohttp
except ImportError:
    print("Need aiohttp: pip install aiohttp")
    sys.exit(1)

# ── Model aliases ──────────────────────────────────────────────────────────

MODEL_ALIASES = {
    "qwen":    "qwen3.5-27b-claude-opus-8bit",
    "qwen3.5": "qwen3.5-27b-claude-opus-8bit",
    "gemma":   "mlx-community/gemma-4-26b-a4b-it-8bit",
    "gemma-4": "mlx-community/gemma-4-26b-a4b-it-8bit",
    "gemma4":  "mlx-community/gemma-4-26b-a4b-it-8bit",
    "trinity": "mlx-community/Trinity-Mini-8bit",
}

DEFAULT_PROMPT = "Write a short paragraph about the history of computing. Be concise."

# ── Result types ───────────────────────────────────────────────────────────

@dataclass
class RequestResult:
    request_id: int
    status: int               # HTTP status
    ttfb: float               # time to first byte (seconds)
    total_time: float          # total request time (seconds)
    tokens: int               # tokens generated
    tps: float                # tokens per second (decode)
    provider_id: str = ""
    provider_chip: str = ""
    error: str = ""
    queued: bool = False      # whether request was queued


@dataclass
class LevelResult:
    concurrency: int
    results: list = field(default_factory=list)

    @property
    def successes(self):
        return [r for r in self.results if r.status == 200]

    @property
    def failures(self):
        return [r for r in self.results if r.status != 200]

    @property
    def avg_ttfb(self):
        s = self.successes
        return sum(r.ttfb for r in s) / len(s) if s else 0

    @property
    def avg_total(self):
        s = self.successes
        return sum(r.total_time for r in s) / len(s) if s else 0

    @property
    def avg_tps(self):
        s = self.successes
        return sum(r.tps for r in s) / len(s) if s else 0

    @property
    def total_tokens(self):
        return sum(r.tokens for r in self.results)

    @property
    def aggregate_tps(self):
        s = self.successes
        if not s:
            return 0
        # wall-clock: from first request start to last request end
        # Since all requests start ~simultaneously, use max total_time
        max_time = max(r.total_time for r in s)
        return self.total_tokens / max_time if max_time > 0 else 0

    @property
    def p50_ttfb(self):
        return self._percentile([r.ttfb for r in self.successes], 50)

    @property
    def p95_ttfb(self):
        return self._percentile([r.ttfb for r in self.successes], 95)

    @property
    def p50_total(self):
        return self._percentile([r.total_time for r in self.successes], 50)

    @property
    def p95_total(self):
        return self._percentile([r.total_time for r in self.successes], 95)

    @staticmethod
    def _percentile(values, pct):
        if not values:
            return 0
        s = sorted(values)
        k = (len(s) - 1) * pct / 100
        f = int(k)
        c = f + 1
        if c >= len(s):
            return s[f]
        return s[f] + (k - f) * (s[c] - s[f])


# ── Single request ─────────────────────────────────────────────────────────

async def send_request(
    session: aiohttp.ClientSession,
    url: str,
    api_key: str,
    model: str,
    prompt: str,
    request_id: int,
    max_tokens: int,
) -> RequestResult:
    """Send a single streaming chat completion and collect metrics."""

    payload = {
        "model": model,
        "messages": [{"role": "user", "content": prompt}],
        "stream": True,
        "max_tokens": max_tokens,
    }

    headers = {
        "Authorization": f"Bearer {api_key}",
        "Content-Type": "application/json",
    }

    t_start = time.monotonic()
    ttfb = 0.0
    tokens = 0
    provider_id = ""
    provider_chip = ""
    error = ""
    status = 0

    try:
        async with session.post(url, json=payload, headers=headers, timeout=aiohttp.ClientTimeout(total=660)) as resp:
            status = resp.status
            provider_id = resp.headers.get("X-Provider-ID", "")
            provider_chip = resp.headers.get("X-Provider-Chip", "")

            if status != 200:
                body = await resp.text()
                try:
                    err_json = json.loads(body)
                    error = err_json.get("error", {}).get("message", body[:200])
                except Exception:
                    error = body[:200]
                total_time = time.monotonic() - t_start
                return RequestResult(
                    request_id=request_id, status=status, ttfb=total_time,
                    total_time=total_time, tokens=0, tps=0,
                    provider_id=provider_id, provider_chip=provider_chip,
                    error=error,
                )

            # Stream SSE chunks
            first_token_time = None
            async for line in resp.content:
                line = line.decode("utf-8", errors="replace").strip()
                if not line.startswith("data: "):
                    continue
                data = line[6:]
                if data == "[DONE]":
                    break
                try:
                    chunk = json.loads(data)
                    choices = chunk.get("choices", [])
                    if choices:
                        delta = choices[0].get("delta", {})
                        # Count all token-bearing fields
                        has_token = False
                        for field in ("content", "reasoning_content", "reasoning"):
                            val = delta.get(field)
                            if val:  # non-empty string
                                has_token = True
                                break
                        if has_token:
                            tokens += 1
                            if first_token_time is None:
                                first_token_time = time.monotonic()
                                ttfb = first_token_time - t_start
                        # Also count usage chunk at the end
                        usage = chunk.get("usage")
                        if usage and "completion_tokens" in usage:
                            tokens = usage["completion_tokens"]  # authoritative count
                except json.JSONDecodeError:
                    pass

    except asyncio.TimeoutError:
        total_time = time.monotonic() - t_start
        return RequestResult(
            request_id=request_id, status=504, ttfb=ttfb or total_time,
            total_time=total_time, tokens=tokens, tps=0, error="timeout",
        )
    except Exception as e:
        total_time = time.monotonic() - t_start
        return RequestResult(
            request_id=request_id, status=0, ttfb=ttfb or total_time,
            total_time=total_time, tokens=tokens, tps=0, error=str(e),
        )

    total_time = time.monotonic() - t_start
    # TPS = tokens / decode_time (exclude prefill/TTFB)
    decode_time = total_time - ttfb if ttfb > 0 else total_time
    tps = tokens / decode_time if decode_time > 0 and tokens > 0 else 0

    return RequestResult(
        request_id=request_id, status=status, ttfb=ttfb,
        total_time=total_time, tokens=tokens, tps=tps,
        provider_id=provider_id, provider_chip=provider_chip,
    )


# ── Run one concurrency level ─────────────────────────────────────────────

async def run_level(
    url: str,
    api_key: str,
    model: str,
    prompt: str,
    concurrency: int,
    requests_per_level: int,
    max_tokens: int,
) -> LevelResult:
    """Fire `requests_per_level` requests at given concurrency."""

    level = LevelResult(concurrency=concurrency)

    # Process in batches of `concurrency`
    connector = aiohttp.TCPConnector(limit=concurrency + 5)
    async with aiohttp.ClientSession(connector=connector) as session:
        req_id = 0
        remaining = requests_per_level
        while remaining > 0:
            batch_size = min(concurrency, remaining)
            tasks = []
            for _ in range(batch_size):
                req_id += 1
                tasks.append(send_request(session, url, api_key, model, prompt, req_id, max_tokens))
            results = await asyncio.gather(*tasks)
            level.results.extend(results)
            remaining -= batch_size

            # Live progress
            for r in results:
                status_icon = "OK" if r.status == 200 else f"ERR {r.status}"
                chip_short = r.provider_chip.replace("Apple ", "") if r.provider_chip else "?"
                if r.status == 200:
                    print(f"  req {r.request_id:3d} | {status_icon} | {r.tokens:4d} tok | "
                          f"TTFB {r.ttfb:5.1f}s | total {r.total_time:5.1f}s | "
                          f"{r.tps:5.1f} tok/s | {chip_short} ({r.provider_id[:8]})")
                else:
                    print(f"  req {r.request_id:3d} | {status_icon} | {r.error[:60]}")

    return level


# ── Main ───────────────────────────────────────────────────────────────────

def print_summary(levels: list[LevelResult], model: str):
    """Print final summary table."""
    print("\n" + "=" * 100)
    print(f"LOAD TEST SUMMARY — {model}")
    print("=" * 100)
    print(f"{'Conc':>5} | {'Reqs':>4} | {'OK':>3} | {'Fail':>4} | "
          f"{'Avg TTFB':>9} | {'p95 TTFB':>9} | "
          f"{'Avg Total':>10} | {'p95 Total':>10} | "
          f"{'Avg TPS':>8} | {'Agg TPS':>8}")
    print("-" * 100)
    for lv in levels:
        ok = len(lv.successes)
        fail = len(lv.failures)
        print(f"{lv.concurrency:5d} | {len(lv.results):4d} | {ok:3d} | {fail:4d} | "
              f"{lv.avg_ttfb:8.1f}s | {lv.p95_ttfb:8.1f}s | "
              f"{lv.avg_total:9.1f}s | {lv.p95_total:9.1f}s | "
              f"{lv.avg_tps:7.1f} | {lv.aggregate_tps:7.1f}")
    print("=" * 100)

    # Provider distribution
    print("\nProvider distribution:")
    provider_counts: dict[str, int] = {}
    provider_chips: dict[str, str] = {}
    for lv in levels:
        for r in lv.successes:
            pid = r.provider_id[:8] if r.provider_id else "unknown"
            provider_counts[pid] = provider_counts.get(pid, 0) + 1
            if r.provider_chip:
                provider_chips[pid] = r.provider_chip
    for pid, count in sorted(provider_counts.items(), key=lambda x: -x[1]):
        chip = provider_chips.get(pid, "?")
        print(f"  {pid} ({chip}): {count} requests")

    # Errors
    all_errors = []
    for lv in levels:
        all_errors.extend(lv.failures)
    if all_errors:
        print(f"\nErrors ({len(all_errors)} total):")
        error_types: dict[str, int] = {}
        for r in all_errors:
            key = f"{r.status}: {r.error[:80]}"
            error_types[key] = error_types.get(key, 0) + 1
        for err, count in sorted(error_types.items(), key=lambda x: -x[1]):
            print(f"  {count}x {err}")


async def main():
    parser = argparse.ArgumentParser(description="Darkbloom escalating load test")
    parser.add_argument("--url", default="https://inference-test.openinnovation.dev/v1/chat/completions",
                        help="Chat completions endpoint")
    parser.add_argument("--model", default="qwen3.5",
                        help="Model name or alias (qwen3.5, gemma-4, trinity)")
    parser.add_argument("--levels", type=int, nargs="+", default=[1, 2, 4, 8],
                        help="Concurrency levels to test (default: 1 2 4 8)")
    parser.add_argument("--requests-per-level", type=int, default=4,
                        help="Requests per concurrency level (default: 4)")
    parser.add_argument("--max-tokens", type=int, default=150,
                        help="Max tokens per request (default: 150)")
    parser.add_argument("--prompt", default=DEFAULT_PROMPT,
                        help="Prompt to send")
    parser.add_argument("--pause", type=int, default=5,
                        help="Pause between levels in seconds (default: 5)")
    parser.add_argument("--skip-warmup", action="store_true",
                        help="Skip warmup phase")
    args = parser.parse_args()

    api_key = os.environ.get("EIGENINFERENCE_API_KEY") or os.environ.get("EIGENINFERENCE_ADMIN_KEY")
    if not api_key:
        print("Set EIGENINFERENCE_API_KEY or EIGENINFERENCE_ADMIN_KEY env var")
        sys.exit(1)

    model = MODEL_ALIASES.get(args.model, args.model)

    print(f"Darkbloom Load Test")
    print(f"  Model:      {model}")
    print(f"  Levels:     {args.levels}")
    print(f"  Reqs/level: {args.requests_per_level}")
    print(f"  Max tokens: {args.max_tokens}")
    print(f"  Endpoint:   {args.url}")
    print()

    # Quick pre-flight: verify auth and model availability
    async with aiohttp.ClientSession() as session:
        headers = {"Authorization": f"Bearer {api_key}", "Content-Type": "application/json"}
        async with session.post(args.url, json={
            "model": model,
            "messages": [{"role": "user", "content": "hi"}],
            "stream": False,
            "max_tokens": 1,
        }, headers=headers, timeout=aiohttp.ClientTimeout(total=120)) as resp:
            if resp.status == 401:
                print("Auth failed. Check your API key.")
                sys.exit(1)
            elif resp.status == 404:
                print(f"Model '{model}' not found.")
                sys.exit(1)
            elif resp.status == 402:
                print("Insufficient balance.")
                sys.exit(1)
            elif resp.status == 200:
                print("Pre-flight OK")
            else:
                body = await resp.text()
                print(f"Pre-flight returned {resp.status}: {body[:200]}")
                print("Continuing anyway...")

    # Warmup: send parallel requests to wake all providers
    if not args.skip_warmup:
        # Get provider count from stats
        async with aiohttp.ClientSession() as session:
            try:
                async with session.get(
                    args.url.replace("/v1/chat/completions", "/v1/stats"),
                    timeout=aiohttp.ClientTimeout(total=10),
                ) as resp:
                    stats = await resp.json()
                    provider_count = sum(
                        1 for p in stats.get("providers", [])
                        if model in p.get("models", [])
                    )
            except Exception:
                provider_count = 5  # reasonable default

        print(f"Warming up {provider_count} providers (sending {provider_count} parallel requests)...")
        warmup_results = await run_level(
            url=args.url, api_key=api_key, model=model,
            prompt="Say hi", concurrency=provider_count,
            requests_per_level=provider_count, max_tokens=5,
        )
        ok = len(warmup_results.successes)
        fail = len(warmup_results.failures)
        print(f"Warmup done: {ok} OK, {fail} failed\n")
        # Give providers a moment to settle
        await asyncio.sleep(3)

    levels: list[LevelResult] = []

    for i, concurrency in enumerate(args.levels):
        print(f"{'─' * 80}")
        print(f"Level {i+1}/{len(args.levels)}: concurrency={concurrency}, "
              f"requests={args.requests_per_level}")
        print(f"{'─' * 80}")

        level_result = await run_level(
            url=args.url,
            api_key=api_key,
            model=model,
            prompt=args.prompt,
            concurrency=concurrency,
            requests_per_level=args.requests_per_level,
            max_tokens=args.max_tokens,
        )
        levels.append(level_result)

        ok = len(level_result.successes)
        fail = len(level_result.failures)
        print(f"\n  Level summary: {ok} OK, {fail} failed | "
              f"avg TTFB {level_result.avg_ttfb:.1f}s | "
              f"aggregate {level_result.aggregate_tps:.1f} tok/s")

        # Pause between levels to let providers recover
        if i < len(args.levels) - 1:
            print(f"\n  Pausing {args.pause}s before next level...\n")
            await asyncio.sleep(args.pause)

    print_summary(levels, model)


if __name__ == "__main__":
    asyncio.run(main())
