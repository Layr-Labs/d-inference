#!/usr/bin/env python3
"""Lightweight continuous load test — short requests, 3 in parallel."""

import asyncio
import time
import aiohttp

BASE_URL = "https://api.darkbloom.dev/v1"
API_KEY = "darkbloom-e47e7299dc7d798ea1bcd706e0f780cb9a98536c7d2124a067f0e40e2b3b5b44"

MODELS = [
    "mlx-community/gemma-4-26b-a4b-it-8bit",
    "qwen3.5-27b-claude-opus-8bit",
]

PROMPTS = [
    "Explain the difference between TCP and UDP in 3 sentences.",
    "What is a Merkle tree and why is it useful in distributed systems?",
    "Write a Python function that checks if a string is a palindrome.",
]


async def worker(worker_id: int, model: str, prompt: str):
    """Continuously send short requests."""
    headers = {
        "Authorization": f"Bearer {API_KEY}",
        "Content-Type": "application/json",
    }
    short_name = model.split("/")[-1]
    req_num = 0

    async with aiohttp.ClientSession() as session:
        while True:
            req_num += 1
            payload = {
                "model": model,
                "messages": [{"role": "user", "content": prompt}],
                "temperature": 0.7,
                "max_tokens": 200,
            }

            t0 = time.monotonic()
            try:
                async with session.post(
                    f"{BASE_URL}/chat/completions",
                    headers=headers,
                    json=payload,
                    timeout=aiohttp.ClientTimeout(total=120),
                ) as resp:
                    elapsed = time.monotonic() - t0
                    if resp.status != 200:
                        body = await resp.text()
                        print(f"  w{worker_id} [{short_name}] #{req_num}: ERROR {resp.status} ({elapsed:.1f}s)")
                        continue

                    data = await resp.json()
                    usage = data.get("usage", {})
                    tokens = usage.get("completion_tokens", 0)
                    tps = round(tokens / elapsed, 1) if elapsed > 0 else 0
                    print(f"  w{worker_id} [{short_name}] #{req_num}: {elapsed:.1f}s, {tokens} tok, {tps} tok/s")

            except asyncio.TimeoutError:
                print(f"  w{worker_id} [{short_name}] #{req_num}: TIMEOUT")
            except Exception as e:
                print(f"  w{worker_id} [{short_name}] #{req_num}: ERROR {e}")


async def main():
    print("Light load test — 3 workers, max_tokens=200, continuous\n")
    workers = [
        worker(1, MODELS[0], PROMPTS[0]),
        worker(2, MODELS[1], PROMPTS[1]),
        worker(3, MODELS[0], PROMPTS[2]),
    ]
    await asyncio.gather(*workers)


if __name__ == "__main__":
    asyncio.run(main())
