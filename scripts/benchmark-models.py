#!/usr/bin/env python3
"""Benchmark script for Darkbloom inference API.

Sends a complex reasoning question to Gemma 4 and Qwen 3.5 in parallel,
measures latency and token throughput.
"""

import asyncio
import time
import json
import aiohttp
import argparse

BASE_URL = "https://api.darkbloom.dev/v1"
API_KEY = "eigeninference-..."

MODELS = [
    "mlx-community/gemma-4-26b-a4b-it-8bit",
    "qwen3.5-27b-claude-opus-8bit",
]

PROMPT = """\
You are given a railway network with 6 cities: A, B, C, D, E, F.
The direct routes and their travel times (in hours) are:
  A-B: 2, A-C: 5, B-C: 1, B-D: 7, C-D: 3, C-E: 4, D-F: 2, E-F: 6, A-F: 15, B-E: 8

A traveler starts at city A and must visit every city exactly once before returning to A.
However, route B-D is closed on weekends, and the traveler departs on Saturday.

1. Find the shortest Hamiltonian cycle that avoids B-D.
2. If the traveler can wait until Monday (adding 48 hours) to use B-D, is it worth it? Show the comparison.
3. What is the minimum spanning tree of the full graph (ignoring the weekend constraint)?

Show all work step by step with clear reasoning.\
"""


async def call_model(session: aiohttp.ClientSession, model: str, run_id: int) -> dict:
    """Make a single chat completion request and collect timing stats."""
    headers = {
        "Authorization": f"Bearer {API_KEY}",
        "Content-Type": "application/json",
    }
    payload = {
        "model": model,
        "messages": [{"role": "user", "content": PROMPT}],
        "temperature": 0.7,
        "max_tokens": 20000,
    }

    short_name = model.split("/")[-1]
    print(f"  [{short_name} run={run_id}] sending request...")

    t0 = time.monotonic()
    first_token_time = None
    full_text = ""
    token_count = 0

    try:
        async with session.post(
            f"{BASE_URL}/chat/completions",
            headers=headers,
            json=payload,
            timeout=aiohttp.ClientTimeout(total=600),
        ) as resp:
            if resp.status != 200:
                body = await resp.text()
                return {
                    "model": model,
                    "run": run_id,
                    "error": f"HTTP {resp.status}: {body[:500]}",
                }

            data = await resp.json()
            elapsed = time.monotonic() - t0
            choice = data["choices"][0]
            full_text = choice["message"]["content"]
            usage = data.get("usage", {})
            prompt_tokens = usage.get("prompt_tokens", 0)
            completion_tokens = usage.get("completion_tokens", 0)

            print(f"  [{short_name} run={run_id}] done in {elapsed:.1f}s — {completion_tokens} tokens")

            return {
                "model": model,
                "run": run_id,
                "elapsed_s": round(elapsed, 2),
                "prompt_tokens": prompt_tokens,
                "completion_tokens": completion_tokens,
                "tokens_per_sec": round(completion_tokens / elapsed, 1) if elapsed > 0 else 0,
                "response": full_text,
            }
    except asyncio.TimeoutError:
        return {"model": model, "run": run_id, "error": "timeout (600s)"}
    except Exception as e:
        return {"model": model, "run": run_id, "error": str(e)}


async def main():
    parser = argparse.ArgumentParser(description="Benchmark Darkbloom inference models")
    parser.add_argument("-n", "--runs", type=int, default=1, help="Number of parallel runs per model (default: 1)")
    parser.add_argument("--json", action="store_true", help="Output raw JSON results")
    parser.add_argument("--continuous", action="store_true", help="Run continuously, back-to-back batches")
    args = parser.parse_args()

    runs_per_model = args.runs
    batch_num = 0

    while True:
        batch_num += 1
        batch_start = time.monotonic()
        print(f"\n{'='*70}")
        print(f"BATCH {batch_num} — {len(MODELS)} models x {runs_per_model} run(s)")
        print(f"{'='*70}\n")

        async with aiohttp.ClientSession() as session:
            tasks = []
            for model in MODELS:
                for run_id in range(1, runs_per_model + 1):
                    tasks.append(call_model(session, model, run_id))

            results = await asyncio.gather(*tasks)

        succeeded = sum(1 for r in results if "error" not in r)
        failed = sum(1 for r in results if "error" in r)
        batch_elapsed = time.monotonic() - batch_start

        if args.json:
            compact = []
            for r in results:
                entry = {k: v for k, v in r.items() if k != "response"}
                entry["response_preview"] = (r.get("response") or "")[:200] + "..."
                compact.append(entry)
            print(json.dumps({"batch": batch_num, "results": compact}, indent=2))
        else:
            print(f"\n--- Batch {batch_num} results ({batch_elapsed:.1f}s) — {succeeded} ok, {failed} failed ---")
            for r in results:
                short_name = r["model"].split("/")[-1]
                if "error" in r:
                    print(f"  {short_name} run={r['run']}: ERROR — {r['error'][:100]}")
                    continue
                print(f"  {short_name} run={r['run']}: {r['elapsed_s']}s, {r['completion_tokens']} tokens, {r['tokens_per_sec']} tok/s")

        if not args.continuous:
            break

        print(f"\nStarting next batch immediately...")


if __name__ == "__main__":
    asyncio.run(main())
