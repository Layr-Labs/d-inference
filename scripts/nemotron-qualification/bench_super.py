#!/usr/bin/env python3
"""Benchmark the Nemotron Super qualification runner over its loopback HTTP endpoint.

Run with ``python3 -I``. Measures cold load (runner events), first/cold/warm
TTFT, prefill, steady decode and end-to-end output rates for text contexts and
inline PNG images, plus latency percentiles under concurrency. Greedy sampling
with fixed seeds; every raw sample lands in the JSON receipt.

  python3 -I bench_super.py run --out R.json --launch-runner BIN --runner-arg=--synthetic ...
  python3 -I bench_super.py run --out R.json --runner-state STATE_DIR
  python3 -I bench_super.py compare plain.json speculative.json
"""
import argparse
import datetime
import importlib.util
import json
from pathlib import Path
import sys
import threading
import time

HERE = Path(__file__).resolve().parent
sys.dont_write_bytecode = True  # never write a cache into the source checkout
_spec = importlib.util.spec_from_file_location("super_runner_client", HERE / "super_runner_client.py")
client = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(client)

SCHEMA = "nemotron-super-bench/1"


class Bench:
    def __init__(self, runner, args):
        self.runner = runner
        self.args = args
        self.extra = json.loads(args.extra_body) if args.extra_body else {}
        self.seed = args.seed
        self.nonce = 0
        self.words_per_token = args.initial_words_per_token
        self.calibrated_words = {}
        self.warnings = []

    def body(self, words, max_tokens, nonce, image=None):
        text = client.prompt_text(words, self.seed, nonce)
        thinking = {"off": False, "on": True, "default": None}[self.args.thinking]
        return client.chat_body(text, max_tokens, self.seed, self.extra, image_png=image, thinking=thinking)

    def next_nonce(self):
        self.nonce += 1
        return f"{self.seed:x}-{self.nonce:06d}"

    def measured(self, body, memory=True):
        """One request at concurrency 1 with a fresh runner memory window."""
        engine_before = self.runner._diagnostics("GET", "/runner/engine")
        if memory:
            self.runner.reset_peaks()
        sample = self.runner.chat(body, timeout=self.args.request_timeout)
        sample["engine_before"] = engine_before
        sample["engine_after"] = self.runner._diagnostics("GET", "/runner/engine")
        if memory:
            snapshot = self.runner.memory()
            sample["memory_window"] = snapshot["window"]
            sample["charges_after"] = snapshot["charges"]["by_kind"]
            # Cumulative bank counters (null without a bank); successive samples
            # differ by this request's restored tokens.
            sample["prefix_cache_after"] = (snapshot.get("context") or {}).get("prefix_cache")
        return sample

    def text_context(self, name, target):
        # The first execution of a shape is the "first" TTFT sample and the first
        # calibration point; secant steps then fit words to the target length.
        words = max(1, int(target * self.words_per_token) - 30)
        first = self.measured(self.body(words, self.args.max_tokens, self.next_nonce()))
        words, calibration = self.calibrate(target, [(words, first.get("prompt_tokens"))])
        self.calibrated_words[name] = words
        result = {"target_prompt_tokens": target, "words": words, "first": first,
                  "calibration": calibration, "cold": [], "warm": []}
        for _ in range(self.args.warmup):
            self.measured(self.body(words, self.args.max_tokens, self.next_nonce()), memory=False)
        warm_body = self.body(words, self.args.max_tokens, self.next_nonce())
        result["warm_seed_request"] = self.measured(warm_body)
        for _ in range(self.args.repetitions):
            result["cold"].append(self.measured(self.body(words, self.args.max_tokens, self.next_nonce())))
            result["warm"].append(self.measured(warm_body))
        result["summary"] = {kind: summary(result[kind]) for kind in ("cold", "warm")}
        return result

    def calibrate(self, target, points):
        samples = []
        tolerance = max(2, target // 100)
        for step in range(self.args.calibration_steps + 1):
            words, tokens = points[-1]
            if not tokens or abs(tokens - target) <= tolerance:
                break
            if len(points) > 1 and points[-1][1] and points[-2][1] and points[-1][0] != points[-2][0]:
                slope = (points[-1][1] - points[-2][1]) / (points[-1][0] - points[-2][0])
            else:
                slope = tokens / words
            words = max(1, round(words + (target - tokens) / max(slope, 1e-3)))
            if step == self.args.calibration_steps:
                break  # extrapolated estimate, not measured
            sample = self.measured(self.body(words, 1, self.next_nonce()), memory=False)
            samples.append(sample)
            points.append((words, sample.get("prompt_tokens")))
        return words, samples

    def image(self, width, height):
        png = client.png_rgb(width, height, self.seed)
        words = 16
        result = {"width": width, "height": height, "png_bytes": len(png), "samples": []}
        result["first"] = self.measured(self.body(words, self.args.max_tokens, self.next_nonce(), png))
        for _ in range(self.args.warmup):
            self.measured(self.body(words, self.args.max_tokens, self.next_nonce(), png), memory=False)
        for _ in range(self.args.repetitions):
            result["samples"].append(self.measured(
                self.body(words, self.args.max_tokens, self.next_nonce(), png)))
        result["summary"] = summary(result["samples"])
        return result

    def concurrency(self, level, name, target):
        words = self.calibrated_words.get(name) or max(1, int(target * self.words_per_token))
        bodies = [[self.body(words, self.args.max_tokens, self.next_nonce())
                   for _ in range(self.args.concurrency_requests)] for _ in range(level)]
        results = [[] for _ in range(level)]
        barrier = threading.Barrier(level)

        def worker(index):
            barrier.wait()
            for body in bodies[index]:
                results[index].append(self.runner.chat(body, timeout=self.args.request_timeout))

        engine_before = self.runner._diagnostics("GET", "/runner/engine")
        self.runner.reset_peaks()
        start = time.perf_counter()
        threads = [threading.Thread(target=worker, args=(index,)) for index in range(level)]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join()
        wall = time.perf_counter() - start
        engine_after = self.runner._diagnostics("GET", "/runner/engine")
        snapshot = self.runner.memory()
        samples = [sample for worker_results in results for sample in worker_results]
        ok = [s for s in samples if s["status"] == 200 and not s.get("error")]
        statuses = {}
        for sample in samples:
            key = str(sample["status"]) + (" error" if sample.get("error") else "")
            statuses[key] = statuses.get(key, 0) + 1
        output_tokens = sum(s.get("completion_tokens") or 0 for s in ok)
        return {"concurrency": level, "requests": len(samples), "succeeded": len(ok),
                "statuses": statuses, "wall_s": wall,
                "aggregate_output_tokens_per_s": output_tokens / wall if wall > 0 else None,
                "latency_s": client.summarize([s["total_s"] for s in ok]),
                "ttft_s": client.summarize([s["ttft_s"] for s in ok]),
                "memory_window": snapshot["window"], "samples": samples,
                "engine_before": engine_before, "engine_after": engine_after}


def summary(samples):
    ok = [s for s in samples if s["status"] == 200 and not s.get("error")]
    return {"succeeded": len(ok), "failed": len(samples) - len(ok),
            "prompt_tokens": client.summarize([s.get("prompt_tokens") for s in ok]),
            "completion_tokens": client.summarize([s.get("completion_tokens") for s in ok]),
            "ttft_s": client.summarize([s.get("ttft_s") for s in ok]),
            "prefill_tokens_per_s": client.summarize([s.get("prefill_tokens_per_s") for s in ok]),
            "decode_tokens_per_s": client.summarize([s.get("decode_tokens_per_s") for s in ok]),
            "e2e_output_tokens_per_s": client.summarize([s.get("e2e_output_tokens_per_s") for s in ok]),
            "latency_s": client.summarize([s.get("total_s") for s in ok])}


def comparable_settings(args):
    return {"contexts": args.contexts, "images": args.images, "concurrency": args.concurrency,
            "concurrency_context": args.concurrency_context,
            "concurrency_requests": args.concurrency_requests, "max_tokens": args.max_tokens,
            "warmup": args.warmup, "repetitions": args.repetitions, "seed": args.seed,
            "thinking": args.thinking, "workloads": args.workloads,
            "calibration_steps": args.calibration_steps,
            "initial_words_per_token": args.initial_words_per_token,
            "sampling": {"temperature": 0, "top_p": 1}}


def run(args):
    work = Path(args.work_dir or Path(args.out).with_suffix(".work")).resolve()
    if args.launch_runner:
        runner = client.Runner.launch_process([args.launch_runner] + args.runner_arg, work,
                                              timeout=args.ready_timeout)
    else:
        runner = client.Runner(args.runner_state)
    bench = Bench(runner, args)
    workloads = set(args.workloads.split(","))
    receipt = {"schema": SCHEMA, "created": datetime.datetime.now(datetime.timezone.utc).isoformat(),
               "claim_scope": client.claim_scope(runner), "arm": args.arm, "extra_body": bench.extra,
               "settings": comparable_settings(args),
               "settings_sha256": client.load_settings_hash(comparable_settings(args)),
               "definitions": DEFINITIONS}
    receipt.update(client.provenance(runner, args.source, args.model_dir))
    if runner.ready.get("build_configuration") != "release":
        bench.warnings.append("runner is a debug build: host-side timings are not performance evidence")
    load_end = (runner.events("load.end") or [{}])[-1]
    receipt["cold_load"] = {"runner_load_seconds": load_end.get("seconds"), "phases": load_end.get("phases"),
                            "process_start_to_ready_s": runner.launch.get("process_start_to_ready_s"),
                            "load_window": load_end.get("load_window"),
                            "quote": (runner.events("load.quote") or [None])[-1]}
    contexts = client.parse_contexts(args.contexts)
    try:
        if "text" in workloads:
            receipt["text"] = {name: bench.text_context(name, target) for name, target in contexts.items()}
        if "image" in workloads:
            receipt["images"] = [bench.image(w, h) for w, h in client.parse_images(args.images)]
        if "concurrency" in workloads:
            name = args.concurrency_context if args.concurrency_context in contexts else next(iter(contexts))
            receipt["concurrency"] = [bench.concurrency(int(level), name, contexts[name])
                                      for level in args.concurrency.split(",")]
    finally:
        receipt["warnings"] = bench.warnings
        Path(args.out).write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n")
        if runner.process is not None:
            try:
                code = runner.stop()
                receipt["runner_exit"] = {"code": code,
                                          "retirement": (runner.events("retirement") or [None])[-1]}
            except client.RunnerError as error:
                receipt["runner_exit"] = {"code": None, "error": str(error)}
            Path(args.out).write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n")
    print(json.dumps(headline(receipt), indent=2))
    return 0 if receipt.get("runner_exit", {}).get("code", 0) == 0 else 1


def headline(receipt):
    result = {"claim_scope": receipt["claim_scope"], "arm": receipt["arm"],
              "cold_load_s": receipt["cold_load"]["runner_load_seconds"]}
    for name, value in (receipt.get("text") or {}).items():
        result[f"text.{name}"] = {
            "prompt_tokens": value["first"].get("prompt_tokens"),
            "first_ttft_s": value["first"].get("ttft_s"),
            "cold_ttft_p50_s": value["summary"]["cold"]["ttft_s"].get("p50"),
            "warm_ttft_p50_s": value["summary"]["warm"]["ttft_s"].get("p50"),
            "prefill_tps_p50": value["summary"]["cold"]["prefill_tokens_per_s"].get("p50"),
            "decode_tps_p50": value["summary"]["cold"]["decode_tokens_per_s"].get("p50")}
    for image in receipt.get("images") or []:
        result[f"image.{image['width']}x{image['height']}"] = {
            "prompt_tokens": image["first"].get("prompt_tokens"), "first_ttft_s": image["first"].get("ttft_s"),
            "ttft_p50_s": image["summary"]["ttft_s"].get("p50"),
            "decode_tps_p50": image["summary"]["decode_tokens_per_s"].get("p50")}
    for level in receipt.get("concurrency") or []:
        result[f"concurrency.{level['concurrency']}"] = {
            "statuses": level["statuses"], "aggregate_tps": level["aggregate_output_tokens_per_s"],
            "latency_p50_s": level["latency_s"].get("p50"), "latency_p99_s": level["latency_s"].get("p99")}
    if "runner_exit" in receipt:
        result["runner_exit_code"] = receipt["runner_exit"]["code"]
    result["warnings"] = receipt["warnings"]
    return result


DEFINITIONS = {
    "ttft_s": "request written -> first SSE delta with content or reasoning text (includes HTTP, "
              "template, media preparation and prefill)",
    "first": "first request of each context, at its uncalibrated initial length (first-use kernel and "
             "allocator cost for that shape); only the first workload runs directly after load",
    "cold": "new leading nonce on a warmed process; no prompt prefix is shared",
    "warm": "byte-identical repeat of one body; without DARKBLOOM_PREFIX_CACHE_MEMORY=1 the owner "
            "has no prefix store and prefills it cold; with it, prefix_cache_after.tokens_saved rises by "
            "the restored tokens (cached_prompt_tokens stays 0 on this route)",
    "prefill_tokens_per_s": "prompt_tokens / ttft_s (an end-to-end lower bound on prefill rate)",
    "decode_tokens_per_s": "(completion_tokens - 1) / (last delta - first delta)",
    "e2e_output_tokens_per_s": "completion_tokens / total request time",
    "aggregate_output_tokens_per_s": "successful completion tokens / wall time of the concurrency batch",
    "percentiles": "linear interpolation between closest ranks",
}


def compare(args):
    a, b = (json.loads(Path(p).read_text()) for p in (args.a, args.b))
    if a["settings_sha256"] != b["settings_sha256"]:
        print("receipts used different workload settings; refusing to compare", file=sys.stderr)
        return 2
    for key in ("mode", "index_sha256"):
        if (a["model"]["identity"] or {}).get(key) != (b["model"]["identity"] or {}).get(key):
            print(f"receipts differ in model {key}; refusing to compare", file=sys.stderr)
            return 2
    if a["runner"]["ready"].get("build_configuration") != b["runner"]["ready"].get("build_configuration"):
        print("receipts differ in runner build configuration; refusing to compare", file=sys.stderr)
        return 2
    rows = {}
    for name in sorted(set(a.get("text", {})) & set(b.get("text", {}))):
        for kind in ("cold", "warm"):
            for metric in ("ttft_s", "decode_tokens_per_s", "e2e_output_tokens_per_s"):
                left = a["text"][name]["summary"][kind][metric].get("p50")
                right = b["text"][name]["summary"][kind][metric].get("p50")
                rows[f"text.{name}.{kind}.{metric}.p50"] = ratio_row(left, right)
    for left, right in zip(a.get("concurrency") or [], b.get("concurrency") or []):
        rows[f"concurrency.{left['concurrency']}.aggregate_tps"] = ratio_row(
            left["aggregate_output_tokens_per_s"], right["aggregate_output_tokens_per_s"])
    print(json.dumps({"a": {"arm": a["arm"], "extra_body": a["extra_body"],
                            "engine_environment": a["runner"]["ready"]["settings"]["engine_environment"]},
                      "b": {"arm": b["arm"], "extra_body": b["extra_body"],
                            "engine_environment": b["runner"]["ready"]["settings"]["engine_environment"]},
                      "b_over_a": rows}, indent=2))
    return 0


def ratio_row(left, right):
    return {"a": left, "b": right, "b_over_a": (right / left) if left and right else None}


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    bench = commands.add_parser("run")
    bench.add_argument("--out", required=True)
    target = bench.add_mutually_exclusive_group(required=True)
    target.add_argument("--launch-runner", help="runner executable; started with a new state dir")
    target.add_argument("--runner-state", help="state dir of an already running runner")
    bench.add_argument("--runner-arg", action="append", default=[],
                       help="argument for a launched runner, e.g. --runner-arg=--synthetic (repeatable)")
    bench.add_argument("--work-dir", help="launch directory (default: <out>.work)")
    bench.add_argument("--ready-timeout", type=float, default=3600)
    bench.add_argument("--contexts", default="short=128,medium=2048,long=15360")
    bench.add_argument("--images", default="512x512,1024x1024,2048x1536")
    bench.add_argument("--concurrency", default="1,2,4,8")
    bench.add_argument("--concurrency-context", default="medium")
    bench.add_argument("--concurrency-requests", type=int, default=2, help="requests per concurrent client")
    bench.add_argument("--workloads", default="text,image,concurrency")
    bench.add_argument("--max-tokens", type=int, default=128)
    bench.add_argument("--warmup", type=int, default=1)
    bench.add_argument("--repetitions", type=int, default=3)
    bench.add_argument("--seed", type=int, default=1234)
    bench.add_argument("--thinking", choices=("off", "on", "default"), default="off")
    bench.add_argument("--initial-words-per-token", type=float, default=0.75)
    bench.add_argument("--calibration-steps", type=int, default=2,
                       help="extra max_tokens=1 requests per context to fit the prompt length")
    bench.add_argument("--request-timeout", type=float, default=1800)
    bench.add_argument("--arm", default="plain", help="label for A/B receipts, e.g. plain or speculative")
    bench.add_argument("--extra-body", help="JSON object merged into every request (A/B passthrough)")
    bench.add_argument("--source", action="append", default=[], help="NAME=PATH git checkout (repeatable)")
    bench.add_argument("--model-dir", help="checkpoint directory for revision facts")
    bench.set_defaults(handler=run)
    diff = commands.add_parser("compare")
    diff.add_argument("a")
    diff.add_argument("b")
    diff.set_defaults(handler=compare)
    args = parser.parse_args()
    client.exit_on_sigterm()
    return args.handler(args)


if __name__ == "__main__":
    sys.exit(main())
