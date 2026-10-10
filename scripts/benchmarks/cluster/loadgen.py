#!/usr/bin/env python3
"""Fixed-shape load generator for a local OpenAI-compatible endpoint.

Python standard library only. It drives an already-running server (for example
``darkbloom start --local`` bound to loopback) with streamed chat completions
whose prompts are built from one fixed text and sized by the server's own token
count, at a chosen concurrency, and keeps one record per request.

What it measures, and on which clock
------------------------------------
Every time is on this client's monotonic clock, measured from just before the
request bytes are written:

* ``first_token_s``   first streamed delta that carries content, reasoning or a
                      tool call (the role-only frame does not count);
* ``first_content_s`` first delta with non-empty ``content`` ("time to first
                      content");
* ``last_token_s``    last such delta;
* ``total_s``         the ``[DONE]`` frame (or the end of the stream).

Token counts are the server's: ``usage.prompt_tokens`` and
``usage.completion_tokens`` from the final usage frame. Two client-clock rates
are derived from them:

* ``client_prefill_tps = prompt_tokens / first_token_s``. This includes HTTP,
  templating, tokenization, queueing and the first sampled token, so it is a
  lower bound on the engine's own prefill rate.
* ``client_decode_tps = (completion_tokens - 1) / (last_token_s - first_token_s)``.
  One frame can carry several tokens, so this is an estimate.

Any other numeric field the server puts in ``usage`` (or in a ``timings``
object beside it) is kept per request and aggregated under ``server.*``; those
are the server's clock, not this one.

Shapes
------
``--cell PROMPT:OUTPUT:CONCURRENCY:REQUESTS`` runs a closed loop: CONCURRENCY
workers send REQUESTS measured requests in total, each waiting for its answer
before sending the next. ``--warmup N`` (default 1) sends N discarded requests
of the same shape first; ``--warmup 0`` keeps the very first request, which is
how a cold figure (first request after load) is taken. ``--soak-seconds``
runs a timed closed loop over ``--soak-mix`` prompt sizes and reports
per-minute buckets.

Every prompt starts with a per-request number so that a server-side prefix
cache cannot answer a repeated prompt from its cache; ``--nonce fixed`` turns
that off to measure the cached case on purpose. The numbers of one run start
at a base derived from the run's label, so two runs against one server do not
repeat each other's prompts either (the first real run here did, and one
"uncached" request per cell came back with 4,096 cached tokens). Sampling is greedy
(``temperature`` 0, ``top_p`` 1) and thinking is disabled through
``chat_template_kwargs``.

Limits: one completion per request; no tool calls; the prompt size is matched
to the target by whole words, so it can differ from the target by a few tokens
(the record carries the real count); percentiles are nearest-rank and are not
meaningful for fewer than about twenty samples (min and max are also given).
"""

from __future__ import annotations

import argparse
import hashlib
import http.client
import json
import math
import subprocess
import sys
import threading
import time
import zlib
from pathlib import Path
from urllib.parse import urlsplit

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from radix_prefix_cache import events  # noqa: E402  (the repository's SSE frame reader)

SCHEMA = "darkbloom_cluster_loadgen_v1"
DEFAULT_TEXT = (Path(__file__).resolve().parents[3]
                / "libs/darkbloom-cluster-worker/Tests/QualificationPrompts/long-passage.txt")
INSTRUCTION = "Write a very long, detailed essay that expands on the notes above."
STANDARD_USAGE_KEYS = {"prompt_tokens", "completion_tokens", "total_tokens"}
LIMITATIONS = [
    "Times are on the client's monotonic clock unless a field is under server.*.",
    "client_prefill_tps divides prompt tokens by time to first token, so it includes HTTP, "
    "templating, tokenization, queueing and the first sampled token.",
    "client_decode_tps is an estimate: one streamed frame can carry more than one token.",
    "Percentiles are nearest-rank; with few samples read min and max as well.",
    "Prompt sizes are matched by whole words; the per-request record has the server's count.",
]


# ---------------------------------------------------------------- arithmetic

def percentile(values, quantile):
    """Nearest-rank percentile; tails are never interpolated downward."""
    ordered = sorted(values)
    if not ordered:
        return None
    return ordered[max(0, math.ceil(len(ordered) * quantile) - 1)]


def distribution(values):
    values = [value for value in values if value is not None]
    if not values:
        return None
    return {"n": len(values), "min": min(values), "p50": percentile(values, 0.50),
            "p95": percentile(values, 0.95), "max": max(values),
            "mean": sum(values) / len(values)}


def flatten_numeric(prefix, value, into):
    """Collect numeric leaves of a nested object under dotted names."""
    if isinstance(value, bool):
        return
    if isinstance(value, (int, float)):
        into[prefix] = value
    elif isinstance(value, dict):
        for key, item in value.items():
            flatten_numeric(f"{prefix}.{key}" if prefix else key, item, into)


def derive(record):
    """Add the client-clock rates to one finished request record."""
    prompt = record.get("prompt_tokens")
    output = record.get("completion_tokens")
    first = record.get("first_token_s")
    last = record.get("last_token_s")
    record["client_prefill_tps"] = prompt / first if prompt and first and first > 0 else None
    span = last - first if first is not None and last is not None else None
    record["client_decode_tps"] = ((output - 1) / span
                                   if output and output > 1 and span and span > 0 else None)
    return record


def summarize(records, wall_seconds):
    """Aggregate measured (non-warm-up) records of one cell."""
    measured = [record for record in records if not record.get("warmup")]
    good = [record for record in measured if record.get("ok")]
    failed = [record for record in measured if not record.get("ok")]
    summary = {
        "requests": len(measured),
        "ok": len(good),
        "failed": len(failed),
        "failures": sorted({str(record.get("error") or record.get("http_status")) for record in failed}),
        "http_statuses": sorted({record.get("http_status") for record in measured
                                 if record.get("http_status") is not None}),
        "finish_reasons": {reason: sum(1 for record in good if record.get("finish_reason") == reason)
                           for reason in sorted({record.get("finish_reason") for record in good}, key=str)},
        "wall_seconds": wall_seconds,
        "prompt_tokens": distribution([record.get("prompt_tokens") for record in good]),
        "completion_tokens": distribution([record.get("completion_tokens") for record in good]),
    }
    for field in ("first_token_s", "first_content_s", "total_s", "client_prefill_tps", "client_decode_tps"):
        summary[field] = distribution([record.get(field) for record in good])
    server = {}
    for record in good:
        for key, value in (record.get("server") or {}).items():
            server.setdefault(key, []).append(value)
    summary["server"] = {key: distribution(values) for key, values in sorted(server.items())}
    if wall_seconds and wall_seconds > 0:
        summary["aggregate_output_tokens_per_second"] = (
            sum(record.get("completion_tokens") or 0 for record in good) / wall_seconds)
        summary["aggregate_prompt_tokens_per_second"] = (
            sum(record.get("prompt_tokens") or 0 for record in good) / wall_seconds)
        summary["requests_per_second"] = len(good) / wall_seconds
    return summary


def minute_buckets(records, bucket_seconds=60.0):
    """Per-bucket view of a soak, keyed by the time each request finished."""
    buckets = {}
    for record in records:
        if record.get("warmup") or record.get("finished_at_s") is None:
            continue
        buckets.setdefault(int(record["finished_at_s"] // bucket_seconds), []).append(record)
    rows = []
    for index in sorted(buckets):
        good = [record for record in buckets[index] if record.get("ok")]
        rows.append({
            "bucket": index,
            "requests": len(buckets[index]),
            "failed": len(buckets[index]) - len(good),
            "output_tokens": sum(record.get("completion_tokens") or 0 for record in good),
            "prompt_tokens": sum(record.get("prompt_tokens") or 0 for record in good),
            "client_decode_tps_p50": percentile(
                [record["client_decode_tps"] for record in good if record.get("client_decode_tps")], 0.5),
            "client_prefill_tps_p50": percentile(
                [record["client_prefill_tps"] for record in good if record.get("client_prefill_tps")], 0.5),
            "first_token_s_p50": percentile(
                [record["first_token_s"] for record in good if record.get("first_token_s") is not None], 0.5),
        })
    return rows


# ------------------------------------------------------------------- prompts

class Prompts:
    """Deterministic prompts: the fixed text's words repeated to a word count."""

    def __init__(self, text, instruction=INSTRUCTION):
        self.words = text.split()
        if not self.words:
            raise ValueError("the prompt text has no words")
        self.instruction = instruction
        self.text_sha256 = hashlib.sha256(text.encode()).hexdigest()

    def body_words(self, count):
        repeats = count // len(self.words) + 1
        return " ".join((self.words * repeats)[:count])

    def messages(self, word_count, nonce):
        head = f"Run {nonce:06d}." if nonce is not None else "Run 000000."
        body = self.body_words(word_count)
        content = f"{head} {body}\n\n{self.instruction}" if word_count > 0 else f"{head} {self.instruction}"
        return [{"role": "user", "content": content}]


def request_body(model, messages, max_tokens, extra=None):
    body = {"model": model, "messages": messages, "max_tokens": max_tokens,
            "temperature": 0, "top_p": 1, "stream": True,
            "stream_options": {"include_usage": True},
            "chat_template_kwargs": {"enable_thinking": False}}
    if extra:
        body.update(extra)
    return body


# ------------------------------------------------------------------ requests

class Endpoint:
    def __init__(self, base_url, api_key=None, timeout=900.0):
        parts = urlsplit(base_url)
        if parts.scheme != "http" or not parts.hostname:
            raise ValueError("base URL must be http://host:port")
        self.host, self.port = parts.hostname, parts.port or 80
        self.prefix = parts.path.rstrip("/")
        self.api_key, self.timeout = api_key, timeout

    def headers(self):
        headers = {"Content-Type": "application/json", "Accept": "text/event-stream"}
        if self.api_key:
            headers["Authorization"] = f"Bearer {self.api_key}"
        return headers

    def get(self, path, timeout=10.0):
        connection = http.client.HTTPConnection(self.host, self.port, timeout=timeout)
        try:
            connection.request("GET", self.prefix + path, headers=self.headers())
            response = connection.getresponse()
            return response.status, response.read().decode("utf-8", "replace")
        finally:
            connection.close()


def run_request(endpoint, body, clock=time.perf_counter):
    """Send one streamed completion; never raises for a server or stream failure."""
    record = {"ok": False, "http_status": None, "error": None, "finish_reason": None,
              "prompt_tokens": None, "completion_tokens": None, "usage": None, "server": {},
              "headers_s": None, "first_event_s": None, "first_token_s": None,
              "first_content_s": None, "last_token_s": None, "total_s": None,
              "content_frames": 0, "done": False, "text_sha256": None, "text_head": None}
    encoded = json.dumps(body).encode()
    text_parts = []
    connection = http.client.HTTPConnection(endpoint.host, endpoint.port, timeout=endpoint.timeout)
    started = clock()
    try:
        connection.request("POST", endpoint.prefix + "/v1/chat/completions", body=encoded,
                           headers=endpoint.headers())
        response = connection.getresponse()
        record["headers_s"] = clock() - started
        record["http_status"] = response.status
        if response.status != 200:
            record["error"] = "http " + str(response.status) + ": " + response.read(2000).decode("utf-8", "replace")
            return record
        for payload in events(response):
            elapsed = clock() - started
            if record["first_event_s"] is None:
                record["first_event_s"] = elapsed
            if payload == "[DONE]":
                record["done"] = True
                break
            event = json.loads(payload)
            if event.get("error"):
                record["error"] = "sse error: " + json.dumps(event["error"])[:2000]
                break
            if event.get("usage") is not None:
                record["usage"] = event["usage"]
            if isinstance(event.get("timings"), dict):
                flatten_numeric("timings", event["timings"], record["server"])
            emitted = False
            for choice in event.get("choices", []):
                delta = choice.get("delta") or {}
                content = delta.get("content") or ""
                reasoning = delta.get("reasoning_content", delta.get("reasoning")) or ""
                if content:
                    text_parts.append(content)
                    if record["first_content_s"] is None:
                        record["first_content_s"] = elapsed
                emitted |= bool(content or reasoning or delta.get("tool_calls"))
                if choice.get("finish_reason") is not None:
                    record["finish_reason"] = choice["finish_reason"]
            if emitted:
                if record["first_token_s"] is None:
                    record["first_token_s"] = elapsed
                record["last_token_s"] = elapsed
                record["content_frames"] += 1
    except (OSError, http.client.HTTPException, ValueError) as error:
        record["error"] = f"{type(error).__name__}: {error}"[:2000]
    finally:
        record["total_s"] = clock() - started
        connection.close()
    usage = record["usage"] or {}
    record["prompt_tokens"] = usage.get("prompt_tokens") if isinstance(usage.get("prompt_tokens"), int) else None
    record["completion_tokens"] = (usage.get("completion_tokens")
                                   if isinstance(usage.get("completion_tokens"), int) else None)
    for key, value in usage.items():
        if key not in STANDARD_USAGE_KEYS:
            flatten_numeric(f"usage.{key}", value, record["server"])
    text = "".join(text_parts)
    record["text_sha256"] = hashlib.sha256(text.encode()).hexdigest()
    record["text_head"] = text[:80]
    if record["error"] is None:
        if not record["done"]:
            record["error"] = "incomplete stream: no [DONE]"
        elif record["finish_reason"] is None:
            record["error"] = "no finish reason"
        elif record["prompt_tokens"] is None or record["completion_tokens"] is None:
            record["error"] = "no usage"
        elif record["first_token_s"] is None:
            record["error"] = "no content"
    record["ok"] = record["error"] is None
    return derive(record)


# --------------------------------------------------------------- calibration

def calibrate(endpoint, model, prompts, target, extra=None, tolerance=None, max_probes=8, log=None):
    """Find the word count whose prompt the server counts as ``target`` tokens."""
    tolerance = max(2, int(target * 0.002)) if tolerance is None else tolerance
    tried = {}

    def probe(words):
        words = max(0, int(words))
        if words not in tried:
            record = run_request(endpoint, request_body(model, prompts.messages(words, 0), 1, extra))
            if not record["ok"] and record["prompt_tokens"] is None:
                raise RuntimeError(f"calibration probe failed: {record['error']}")
            tried[words] = record["prompt_tokens"]
            if log:
                log(f"calibrate target={target} words={words} prompt_tokens={tried[words]}")
        return tried[words]

    words = max(0, round((target - 30) / 1.3))
    tokens = probe(words)
    slope = 1.3
    for _ in range(max_probes - 1):
        if abs(tokens - target) <= tolerance:
            break
        step = round((target - tokens) / slope)
        if step == 0:
            step = 1 if target > tokens else -1
        next_words = max(0, words + step)
        if next_words in tried:
            break
        next_tokens = probe(next_words)
        if next_tokens != tokens:
            slope = max(0.2, (next_tokens - tokens) / (next_words - words))
        words, tokens = next_words, next_tokens
    best = min(tried, key=lambda count: (abs(tried[count] - target), count))
    return {"target": target, "words": best, "prompt_tokens": tried[best],
            "probes": len(tried), "within_tolerance": abs(tried[best] - target) <= tolerance}


# ------------------------------------------------------------------- running

class Sampler(threading.Thread):
    """Runs a command at an interval and keeps its output with a timestamp."""

    def __init__(self, command, every, path, origin):
        super().__init__(daemon=True)
        self.command, self.every, self.path, self.origin = command, every, path, origin
        self.stop_event = threading.Event()

    def sample(self, tag):
        try:
            output = subprocess.run(self.command, shell=True, capture_output=True, text=True, timeout=60).stdout
        except (OSError, subprocess.SubprocessError) as error:
            output = f"sample failed: {error}"
        with open(self.path, "a", encoding="utf-8") as handle:
            handle.write(json.dumps({"at_s": time.perf_counter() - self.origin, "utc": utc_now(),
                                     "tag": tag, "output": output}) + "\n")

    def run(self):
        while not self.stop_event.wait(self.every):
            self.sample("during")

    def stop(self):
        self.stop_event.set()


def utc_now():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


class Runner:
    def __init__(self, endpoint, model, prompts, calibration, extra, nonce_mode, records_path, log,
                 nonce_base=0):
        self.endpoint, self.model, self.prompts = endpoint, model, prompts
        self.calibration, self.extra, self.nonce_mode = calibration, extra, nonce_mode
        self.records_path, self.log = records_path, log
        self.lock = threading.Lock()
        self.nonce_base = nonce_base
        self.nonce = 0
        self.origin = time.perf_counter()

    def words_for(self, target):
        entry = self.calibration.get(str(target))
        if entry is None:
            entry = calibrate(self.endpoint, self.model, self.prompts, target, self.extra, log=self.log)
            self.calibration[str(target)] = entry
        return entry["words"]

    def one(self, cell, target, output, warmup, worker):
        with self.lock:
            self.nonce += 1
            nonce = self.nonce_base + (self.nonce if self.nonce_mode == "per-request" else 0)
        body = request_body(self.model, self.prompts.messages(self.words_for(target), nonce), output, self.extra)
        sent = time.perf_counter() - self.origin
        record = run_request(self.endpoint, body)
        record.update(cell=cell, target_prompt_tokens=target, max_tokens=output, warmup=warmup,
                      worker=worker, nonce=nonce, sent_at_s=sent,
                      finished_at_s=time.perf_counter() - self.origin, utc=utc_now())
        with self.lock:
            with open(self.records_path, "a", encoding="utf-8") as handle:
                handle.write(json.dumps(record, sort_keys=True) + "\n")
        return record

    def closed_loop(self, cell, concurrency, next_shape, warmup=False):
        """Workers call next_shape() for (target, output) until it returns None."""
        records, guard = [], threading.Lock()

        def work(worker):
            while True:
                with guard:
                    shape = next_shape()
                if shape is None:
                    return
                record = self.one(cell, shape[0], shape[1], warmup, worker)
                with guard:
                    records.append(record)

        threads = [threading.Thread(target=work, args=(index,), daemon=True) for index in range(concurrency)]
        started = time.perf_counter()
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join()
        return records, time.perf_counter() - started


def counted(shape, count):
    remaining = [count]

    def next_shape():
        if remaining[0] <= 0:
            return None
        remaining[0] -= 1
        return shape
    return next_shape


def timed(mix, output, seconds):
    deadline = time.perf_counter() + seconds
    index = [0]

    def next_shape():
        if time.perf_counter() >= deadline:
            return None
        index[0] += 1
        return (mix[(index[0] - 1) % len(mix)], output)
    return next_shape


def parse_cell(text):
    parts = text.split(":")
    if len(parts) != 4:
        raise argparse.ArgumentTypeError("cell is PROMPT:OUTPUT:CONCURRENCY:REQUESTS")
    prompt, output, concurrency, requests = (int(part) for part in parts)
    if min(prompt, output, concurrency, requests) < 1:
        raise argparse.ArgumentTypeError("cell values must be positive")
    return {"prompt": prompt, "output": output, "concurrency": concurrency, "requests": requests}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--base-url", required=True, help="for example http://127.0.0.1:18200")
    parser.add_argument("--model", required=True)
    parser.add_argument("--output", required=True, type=Path, help="directory for this run's files")
    parser.add_argument("--label", required=True, help="file name stem; an existing report is never overwritten")
    parser.add_argument("--cell", action="append", default=[], type=parse_cell,
                        metavar="PROMPT:OUTPUT:CONCURRENCY:REQUESTS")
    parser.add_argument("--warmup", type=int, default=1, help="discarded requests before each cell")
    parser.add_argument("--soak-seconds", type=float, default=0)
    parser.add_argument("--soak-mix", default="64,1024,4096,8192")
    parser.add_argument("--soak-output", type=int, default=128)
    parser.add_argument("--soak-concurrency", type=int, default=1)
    parser.add_argument("--nonce", choices=["per-request", "fixed"], default="per-request")
    parser.add_argument("--nonce-base", type=int,
                        help="first prompt number of this run; by default derived from the label so that two "
                             "runs against one server never send the same prompt (below 1,000 requests each)")
    parser.add_argument("--text-file", type=Path, default=DEFAULT_TEXT)
    parser.add_argument("--calibration", type=Path,
                        help="JSON file of word counts per target; read if present, written back after the run")
    parser.add_argument("--calibrate-only", default="", help="comma-separated targets to calibrate, then exit")
    parser.add_argument("--api-key-file", type=Path, help="file holding a bearer token (never on the command line)")
    parser.add_argument("--extra-body", default="", help="JSON object merged into every request body")
    parser.add_argument("--metrics-path", default="/metrics", help="fetched before and after each cell; '' to skip")
    parser.add_argument("--sample-command", default="", help="shell command sampled during the run")
    parser.add_argument("--sample-every", type=float, default=30.0)
    parser.add_argument("--timeout", type=float, default=900.0)
    arguments = parser.parse_args(argv)

    arguments.output.mkdir(parents=True, exist_ok=True)
    stem = arguments.output / arguments.label
    records_path = Path(str(stem) + ".requests.jsonl")
    summary_path = Path(str(stem) + ".summary.json")
    for path in (records_path, summary_path):
        if path.exists():
            parser.error(f"{path} exists; reports are never overwritten")

    def log(message):
        print(f"[{utc_now()}] {message}", file=sys.stderr, flush=True)

    api_key = arguments.api_key_file.read_text().strip() if arguments.api_key_file else None
    endpoint = Endpoint(arguments.base_url, api_key, arguments.timeout)
    prompts = Prompts(arguments.text_file.read_text())
    extra = json.loads(arguments.extra_body) if arguments.extra_body else None
    calibration = {}
    if arguments.calibration and arguments.calibration.exists():
        stored = json.loads(arguments.calibration.read_text())
        if (stored.get("text_sha256"), stored.get("instruction"), stored.get("model")) == (
                prompts.text_sha256, prompts.instruction, arguments.model):
            calibration = stored.get("targets", {})
        else:
            log("calibration file is for another text, instruction or model; recalibrating")
    nonce_base = (arguments.nonce_base if arguments.nonce_base is not None
                  else (zlib.crc32(arguments.label.encode()) % 900 + 100) * 1000)
    runner = Runner(endpoint, arguments.model, prompts, calibration, extra, arguments.nonce, records_path, log,
                    nonce_base)

    def save_calibration():
        if arguments.calibration:
            arguments.calibration.write_text(json.dumps(
                {"model": arguments.model, "text_sha256": prompts.text_sha256,
                 "instruction": prompts.instruction, "targets": calibration}, indent=1, sort_keys=True) + "\n")

    def metrics(tag):
        if not arguments.metrics_path:
            return
        try:
            status, text = endpoint.get(arguments.metrics_path)
        except (OSError, http.client.HTTPException) as error:
            status, text = None, f"{type(error).__name__}: {error}"
        with open(str(stem) + ".metrics.jsonl", "a", encoding="utf-8") as handle:
            handle.write(json.dumps({"tag": tag, "utc": utc_now(), "status": status, "text": text}) + "\n")

    if arguments.calibrate_only:
        for target in (int(item) for item in arguments.calibrate_only.split(",") if item):
            runner.words_for(target)
        save_calibration()
        print(json.dumps(calibration, indent=1, sort_keys=True))
        return 0

    sampler = None
    if arguments.sample_command:
        sampler = Sampler(arguments.sample_command, arguments.sample_every,
                          str(stem) + ".samples.jsonl", runner.origin)
        sampler.sample("before")
        sampler.start()

    report = {"schema": SCHEMA, "harness_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
              "started_utc": utc_now(), "model": arguments.model, "label": arguments.label,
              "nonce": arguments.nonce, "nonce_base": nonce_base,
              "text_sha256": prompts.text_sha256, "instruction": prompts.instruction,
              "sampling": {"temperature": 0, "top_p": 1, "thinking": "disabled"},
              "extra_body": extra, "limitations": LIMITATIONS, "cells": [], "soak": None}
    failed = 0
    try:
        for cell in arguments.cell:
            name = f"p{cell['prompt']}-o{cell['output']}-c{cell['concurrency']}"
            shape = (cell["prompt"], cell["output"])
            runner.words_for(cell["prompt"])  # calibrate before timing anything
            warm_records = []
            if arguments.warmup:
                warm_records, _ = runner.closed_loop(name, 1, counted(shape, arguments.warmup), warmup=True)
            metrics(name + ":before")
            records, wall = runner.closed_loop(name, cell["concurrency"], counted(shape, cell["requests"]))
            metrics(name + ":after")
            summary = summarize(records, wall)
            summary.update(cell=name, target_prompt_tokens=cell["prompt"], max_tokens=cell["output"],
                           concurrency=cell["concurrency"], warmup_requests=len(warm_records),
                           warmup_failed=sum(1 for record in warm_records if not record["ok"]))
            report["cells"].append(summary)
            failed += summary["failed"]
            first = summary["first_token_s"] or {}
            decode = summary["client_decode_tps"] or {}
            log(f"{name}: ok {summary['ok']}/{summary['requests']} first_token p50 {first.get('p50')} "
                f"decode p50 {decode.get('p50')} aggregate out tok/s "
                f"{summary.get('aggregate_output_tokens_per_second')}")
        if arguments.soak_seconds > 0:
            mix = [int(item) for item in arguments.soak_mix.split(",") if item]
            for target in mix:
                runner.words_for(target)
            metrics("soak:before")
            soak_origin = time.perf_counter() - runner.origin
            records, wall = runner.closed_loop("soak", arguments.soak_concurrency,
                                               timed(mix, arguments.soak_output, arguments.soak_seconds))
            metrics("soak:after")
            for record in records:
                record["finished_at_s"] -= soak_origin
            summary = summarize(records, wall)
            summary.update(cell="soak", mix=mix, max_tokens=arguments.soak_output,
                           concurrency=arguments.soak_concurrency, seconds=arguments.soak_seconds,
                           buckets=minute_buckets(records),
                           by_size={str(target): summarize([record for record in records
                                                            if record["target_prompt_tokens"] == target], wall)
                                    for target in mix})
            report["soak"] = summary
            failed += summary["failed"]
            log(f"soak: ok {summary['ok']}/{summary['requests']} in {wall:.0f}s")
    finally:
        if sampler:
            sampler.stop()
            sampler.join(timeout=70)
            sampler.sample("after")
        save_calibration()
        report["finished_utc"] = utc_now()
        report["calibration"] = calibration
        summary_path.write_text(json.dumps(report, indent=1, sort_keys=True) + "\n")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
