#!/usr/bin/env python3
"""Serving policy benchmark for the Nemotron Super qualification runner.

Natural chat prompts (serving_prompts.json) at several client counts, greedy,
streamed through the runner's real HTTP stack. Records per-request TTFT and
decode rate, aggregate throughput, the engine's speculation counters per level
(acceptance, depth selections) and every output's text, so `compare` can check
byte-identical greedy output across arms (for example plain against each
speculation depth). Run with ``python3 -I`` through the GPU lane.
"""
import argparse
import hashlib
import importlib.util
import json
import random
import sys
import threading
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.dont_write_bytecode = True
_spec = importlib.util.spec_from_file_location("super_runner_client", HERE / "super_runner_client.py")
client = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(client)

SCHEMA = "nemotron-super-serving-bench/1"


def stream_text(runner, body, timeout):
    """`client.stream_chat` timings plus the streamed content text."""
    import http.client
    host, port = client._host_port(runner.base_url)
    body = dict(body, stream=True, stream_options={"include_usage": True})
    data = json.dumps(body).encode()
    result = {"status": None, "ttft_s": None, "error": None, "text": "", "usage": None}
    deltas = []
    connection = http.client.HTTPConnection(host, port, timeout=timeout)
    start = time.perf_counter()
    try:
        connection.request("POST", "/v1/chat/completions", body=data, headers={
            "Authorization": "Bearer " + runner.token, "Content-Type": "application/json"})
        start = time.perf_counter()
        response = connection.getresponse()
        result["status"] = response.status
        if response.status != 200:
            result["error"] = client._error_text(response.read())
        else:
            while True:
                line = response.readline()
                if not line:
                    break
                line = line.strip()
                if not line.startswith(b"data:"):
                    continue
                payload = line[5:].strip()
                if payload == b"[DONE]":
                    break
                now = time.perf_counter() - start
                chunk = json.loads(payload)
                if "error" in chunk:
                    result["error"] = client._error_text(payload)
                    continue
                if chunk.get("usage"):
                    result["usage"] = chunk["usage"]
                for choice in chunk.get("choices") or []:
                    delta = choice.get("delta") or {}
                    text = (delta.get("content") or "") + (delta.get("reasoning_content") or "")
                    if text:
                        if result["ttft_s"] is None:
                            result["ttft_s"] = now
                        deltas.append(now)
                        result["text"] += text
    except (OSError, http.client.HTTPException, ValueError) as error:
        result["error"] = f"{type(error).__name__}: {error}"
    finally:
        connection.close()
    result["total_s"] = time.perf_counter() - start
    usage = result["usage"] or {}
    result["prompt_tokens"] = usage.get("prompt_tokens")
    completion = usage.get("completion_tokens")
    result["completion_tokens"] = completion
    if completion and completion > 1 and len(deltas) > 1 and deltas[-1] > deltas[0]:
        result["decode_tokens_per_s"] = (completion - 1) / (deltas[-1] - deltas[0])
    result["text_sha256"] = hashlib.sha256(result["text"].encode()).hexdigest()
    return result


def mtp_delta(before, after):
    if not before or not after:
        return None
    keys = ("rounds", "seed_steps", "drafted_tokens", "accepted_tokens", "emitted_tokens",
            "rectangular_verification_rounds")
    delta = {key: after[key] - before[key] for key in keys}
    delta["per_position_accepted"] = [
        a - (before["per_position_accepted"][i] if i < len(before["per_position_accepted"]) else 0)
        for i, a in enumerate(after["per_position_accepted"])]
    delta["depth_selections"] = {
        depth: count - before["depth_selections"].get(depth, 0)
        for depth, count in after["depth_selections"].items()
        if count - before["depth_selections"].get(depth, 0)}
    if delta["drafted_tokens"]:
        delta["acceptance_rate"] = delta["accepted_tokens"] / delta["drafted_tokens"]
    if delta["rounds"]:
        delta["emitted_per_round"] = delta["emitted_tokens"] / delta["rounds"]
    return delta


def padded_text(prompt, pad_words, nonce):
    """The prompt behind a filler document; the nonce leads so no prefix is shared."""
    if pad_words <= 0:
        return prompt["text"]
    rng = random.Random(int(hashlib.sha256(prompt["id"].encode()).hexdigest()[:8], 16))
    words = client.WORDS.split() if isinstance(client.WORDS, str) else list(client.WORDS)
    filler = " ".join(rng.choice(words) for _ in range(pad_words))
    return (f"Document {nonce}. Unrelated background notes follow; ignore them. {filler}\n\n"
            f"Using your own knowledge, answer: {prompt['text']}")


def run_level(runner, prompts, level, pad_words, args):
    results = [None] * (level * args.requests_per_client)
    runner._diagnostics("POST", "/runner/peaks/reset", {})
    before = runner._diagnostics("GET", "/runner/engine")
    started = time.perf_counter()

    def worker(index):
        for j in range(args.requests_per_client):
            slot = index * args.requests_per_client + j
            prompt = prompts[(slot + level) % len(prompts)]
            nonce = f"{args.pad_nonce}-{prompt['id']}-{pad_words}-{level}-{slot}" if pad_words else None
            body = client.chat_body(padded_text(prompt, pad_words, nonce), args.max_tokens,
                                    args.seed, thinking=False)
            sample = stream_text(runner, body, args.request_timeout)
            sample["prompt_id"] = prompt["id"]
            sample["nonce"] = nonce
            sample["category"] = prompt["category"]
            sample["client"] = index
            results[slot] = sample

    threads = [threading.Thread(target=worker, args=(i,)) for i in range(level)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()
    wall = time.perf_counter() - started
    after = runner._diagnostics("GET", "/runner/engine")
    window = runner._diagnostics("POST", "/runner/peaks/reset", {})
    ok = [r for r in results if r and r["status"] == 200 and not r["error"]]
    completion = sum(r["completion_tokens"] or 0 for r in ok)
    return {
        "concurrency": level, "pad_words": pad_words, "requests": len(results), "succeeded": len(ok), "wall_s": wall,
        "aggregate_tokens_per_s": completion / wall if wall > 0 else None,
        "ttft_s": client.summarize([r["ttft_s"] for r in ok if r["ttft_s"] is not None]),
        "decode_tokens_per_s": client.summarize(
            [r["decode_tokens_per_s"] for r in ok if r.get("decode_tokens_per_s")]),
        "prompt_tokens": client.summarize([r["prompt_tokens"] for r in ok if r.get("prompt_tokens")]),
        "completion_tokens": completion,
        "errors": [r["error"] for r in results if r and r["error"]],
        "mtp": mtp_delta(before.get("mtp"), after.get("mtp")),
        "profile": after.get("profile"),
        # The level's memory window: MLX peak, sampled maxima, kernel footprint.
        "memory_window": window,
        "samples": results,
    }


def run(args):
    prompts = json.loads(Path(args.prompts).read_text())["prompts"]
    if args.categories:
        wanted = set(args.categories.split(","))
        prompts = [p for p in prompts if p["category"] in wanted]
    out = Path(args.out)
    work = Path(args.work_dir) if args.work_dir else out.with_suffix(".work")
    runner = client.Runner.launch_process([args.launch_runner] + args.runner_arg, work,
                                          timeout=args.ready_timeout)
    receipt = {"schema": SCHEMA, "arm": args.arm, "created": time.strftime("%Y-%m-%dT%H:%M:%S"),
               "settings": {k: v for k, v in vars(args).items() if k != "func"},
               "ready": runner.ready, "levels": []}
    try:
        if args.warmup:
            body = client.chat_body("Say hello.", 8, args.seed, thinking=False)
            stream_text(runner, body, args.request_timeout)
        for pad_words in [int(x) for x in str(args.pad_words).split(",")]:
            for level in [int(x) for x in args.concurrency.split(",")]:
                if args.profile_reset:
                    runner._diagnostics("POST", "/runner/engine/profile/reset", {})
                receipt["levels"].append(run_level(runner, prompts, level, pad_words, args))
                out.write_text(json.dumps(receipt, indent=1))
    finally:
        receipt["runner_exit_code"] = runner.stop()
        out.write_text(json.dumps(receipt, indent=1))
    summary = {"arm": args.arm}
    for level in receipt["levels"]:
        mtp = level["mtp"] or {}
        pad = level.get("pad_words") or 0
        summary[f"c{level['concurrency']}" + (f"-p{pad}" if pad else "")] = {
            "agg_tps": round(level["aggregate_tokens_per_s"] or 0, 2),
            "req_tps_p50": round((level["decode_tokens_per_s"] or {}).get("p50") or 0, 2),
            "ttft_p50": round((level["ttft_s"] or {}).get("p50") or 0, 3),
            "ttft_p90": round((level["ttft_s"] or {}).get("p90") or 0, 3),
            "prompt_p50": (level.get("prompt_tokens") or {}).get("p50"),
            "accept": round(mtp.get("acceptance_rate") or 0, 3),
            "emit_per_round": round(mtp.get("emitted_per_round") or 0, 3),
            "depths": mtp.get("depth_selections"),
            "ok": f"{level['succeeded']}/{level['requests']}",
        }
    summary["runner_exit_code"] = receipt["runner_exit_code"]
    print(json.dumps(summary, indent=1))
    return 0


def compare(args):
    """Every (prompt, nonce) output must be byte-identical across receipts and
    levels; a run cut at a smaller max_tokens must be a prefix of a longer one."""
    seen = {}
    mismatches = []
    for path in args.receipts:
        receipt = json.loads(Path(path).read_text())
        limit = receipt["settings"]["max_tokens"]
        for level in receipt["levels"]:
            for sample in level["samples"]:
                if not sample or sample["status"] != 200 or sample["error"]:
                    continue
                # Unpadded prompts repeat across levels; a padded one is keyed
                # by its nonce, so only receipts with equal settings share it.
                key = sample["prompt_id"] + (f"@{sample['nonce']}" if sample.get("nonce") else "")
                current = (receipt["arm"], sample["text"], sample["completion_tokens"] == limit)
                previous = seen.setdefault(key, current)
                if previous[1] == current[1]:
                    continue
                short, long = sorted((previous, current), key=lambda item: len(item[1]))
                if short[2] and long[1].startswith(short[1]):
                    seen[key] = long
                    continue
                mismatches.append({"prompt": key, "first": previous[0], "other": receipt["arm"],
                                   "concurrency": level["concurrency"]})
    print(json.dumps({"prompts": len(seen), "mismatches": mismatches}, indent=1))
    return 1 if mismatches else 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    r = sub.add_parser("run")
    r.add_argument("--out", required=True)
    r.add_argument("--launch-runner", required=True)
    r.add_argument("--runner-arg", action="append", default=[])
    r.add_argument("--work-dir")
    r.add_argument("--ready-timeout", type=float, default=3600)
    r.add_argument("--arm", default="arm")
    r.add_argument("--prompts", default=str(HERE / "serving_prompts.json"))
    r.add_argument("--categories")
    r.add_argument("--concurrency", default="1,2,4,8")
    r.add_argument("--requests-per-client", type=int, default=2)
    r.add_argument("--max-tokens", type=int, default=256)
    r.add_argument("--pad-words", default="0",
                   help="comma list; each value prepends a filler document of that many words to every prompt")
    r.add_argument("--pad-nonce", default="n")
    r.add_argument("--seed", type=int, default=1234)
    r.add_argument("--request-timeout", type=float, default=1800)
    r.add_argument("--warmup", action="store_true")
    r.add_argument("--profile-reset", action="store_true")
    r.set_defaults(func=run)
    c = sub.add_parser("compare")
    c.add_argument("receipts", nargs="+")
    c.set_defaults(func=compare)
    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    client.exit_on_sigterm()
    sys.exit(main())
