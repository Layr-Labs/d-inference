#!/usr/bin/env python3
"""Replay frozen GPT-OSS HTTP cohorts after exclusive resource allocation.

Does not start/stop servers or change caches. Run each arm against an isolated
fresh cache namespace; misses/hits are asserted from actual response usage.
Supplied launch identity is retained, not represented as remote attestation.
"""
import argparse
import concurrent.futures
import hashlib
import json
from pathlib import Path
import re
import threading
import time
import urllib.parse
import urllib.request

MODEL = "gpt-oss-20b"
MAX_STREAM_BYTES = 16 * 1024 * 1024
MAX_LINE_BYTES = 1024 * 1024


def strict_json(raw):
    def unique_object(pairs):
        result = dict(pairs)
        if len(result) != len(pairs):
            raise ValueError("Duplicate JSON key")
        return result
    def invalid_constant(value):
        raise ValueError(f"Nonfinite JSON number: {value}")
    return json.loads(raw, object_pairs_hook=unique_object, parse_constant=invalid_constant)


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise ValueError("Benchmark endpoints must not redirect")


def runtime_guard(metrics, require_idle=True):
    def value(name, labels):
        matches = []
        for line in metrics.splitlines():
            if not line.startswith(name + "{"):
                continue
            raw, number = line.rsplit(" ", 1)
            if all(re.search(r'(?:\{|,)' + re.escape(key + '="' + val + '"') + r'(?=,|\})', raw)
                   for key, val in labels.items()):
                matches.append(float(number))
        return matches

    if value("kv_backend_info", {"model": MODEL, "backend": "paged"}) != [1]:
        raise ValueError("Expected live GPT-OSS paged backend")
    if value("prefix_cache_status", {"model": MODEL, "state": "ready"}) != [1]:
        raise ValueError("Prefix cache is not ready")
    if value("mtp_active", {"model": MODEL}) != [0]:
        raise ValueError("GPT-OSS target-only control requires MTP inactive")
    idle = all(value(name, {"model": MODEL}) == [0]
               for name in ("kv_active_requests", "kv_waiting_requests"))
    if require_idle and not idle:
        raise ValueError("Runtime still has active/waiting requests")
    return idle


def consume(lines, started, clock=time.perf_counter):
    content, reasoning, events = [], [], []
    usage, finish, first, last, done = {}, None, None, None, False
    for raw in lines:
        if not raw.startswith(b"data:"):
            continue
        if done:
            raise ValueError("SSE data after DONE")
        body = raw[5:].strip()
        if body == b"[DONE]":
            done = True
            continue
        chunk = strict_json(body)
        elapsed = clock() - started
        events.append({"seconds": elapsed, "data": chunk})
        if chunk.get("error"):
            raise ValueError(f"SSE error: {chunk['error']}")
        if chunk.get("usage"):
            usage = chunk["usage"]
        for choice in chunk.get("choices", []):
            if len(chunk["choices"]) != 1 or choice.get("index", 0) != 0:
                raise ValueError("Expected exactly one completion choice")
            delta = choice.get("delta") or {}
            text, thought = delta.get("content") or "", delta.get("reasoning_content") or ""
            if not isinstance(text, str) or not isinstance(thought, str):
                raise ValueError("Invalid SSE text delta")
            content.append(text)
            reasoning.append(thought)
            if text or thought or delta.get("tool_calls"):
                if finish is not None:
                    raise ValueError("Generated data after finish event")
                first = elapsed if first is None else first
                last = elapsed
            if choice.get("finish_reason"):
                if finish is not None:
                    raise ValueError("Duplicate finish event")
                finish = choice["finish_reason"]
    if not done or finish not in ("stop", "length", "tool_calls") or not usage or first is None:
        raise ValueError("Incomplete SSE terminal, generation or usage")
    return {"content": "".join(content), "reasoning": "".join(reasoning), "events": events,
            "usage": usage, "finish_reason": finish, "ttft_seconds": first,
            "last_generated_seconds": last}


def check_case(case, result):
    usage = result["usage"]
    cached = usage.get("prompt_tokens_details", {}).get("cached_tokens")
    prompt, completion = usage.get("prompt_tokens"), usage.get("completion_tokens")
    if any(type(n) is not int or n < 0 for n in (cached, prompt, completion)) or completion == 0:
        raise ValueError("Missing/invalid token usage; expected integer counts")
    if cached > prompt or completion > case["payload"]["max_tokens"]:
        raise ValueError("Token usage exceeds prompt or requested output bounds")
    rule = case.get("cache", "any")
    if rule not in ("miss", "hit", "any"):
        raise ValueError("Unknown cache expectation")
    if rule == "hit" and (type(case.get("minimum_cached_tokens")) is not int or case["minimum_cached_tokens"] <= 0):
        raise ValueError("Hit cases require a positive cached-token minimum")
    if rule == "miss" and cached != 0:
        raise ValueError(f"Expected cold miss, observed {cached} cached tokens")
    if rule == "hit" and cached < case["minimum_cached_tokens"]:
        raise ValueError(f"Ineffective cache hit: {cached} tokens")
    if case.get("fixed_tokens") and (result["usage"]["completion_tokens"] != case["payload"]["max_tokens"]
                                    or result["finish_reason"] != "length"):
        raise ValueError("Early stop is not a fixed-token performance sample")
    if "answer_letter" in case:
        answers = re.findall(r"(?i)\bAnswer\s*:\s*\**\s*\$?([ABCD])\b", result["content"])
        result["answer"] = answers[-1].upper() if answers else None
        result["correct"] = result["answer"] == case["answer_letter"]
        result["truncated"] = result["finish_reason"] == "length"


def validate_suite(suite):
    cohorts = suite.get("cohorts")
    if not isinstance(cohorts, list) or not cohorts:
        raise ValueError("Suite requires nonempty cohorts")
    cases = []
    for cohort in cohorts:
        if not isinstance(cohort.get("cases"), list) or not 1 <= len(cohort["cases"]) <= 32:
            raise ValueError("Each cohort requires 1..32 cases")
        if type(cohort.get("measured", True)) is not bool:
            raise ValueError("Cohort measured flag must be boolean")
        cases.extend(cohort["cases"])
    for ids in ([c.get("id") for c in cases], [c.get("id") for c in cohorts]):
        if any(not isinstance(n, str) or not re.fullmatch(r"[a-zA-Z0-9_-]+", n) for n in ids) or len(set(ids)) != len(ids):
            raise ValueError("Case/cohort IDs must be unique safe filenames")
    if not any(c.get("cache") == "hit" for c in cases):
        raise ValueError("Suite must demonstrate an effective prefix-cache hit")
    for case in cases:
        payload = case["payload"]
        if payload.get("model") != MODEL or payload.get("stream") is not True or payload.get("n", 1) != 1:
            raise ValueError("Only single-choice streaming GPT-OSS requests are accepted")
        if type(payload.get("max_tokens")) is not int or payload["max_tokens"] <= 0:
            raise ValueError("Requests require a positive max_tokens bound")
        if payload.get("stream_options", {}).get("include_usage") is not True:
            raise ValueError("Requests must include stream usage")
        if type(case.get("fixed_tokens", False)) is not bool:
            raise ValueError("fixed_tokens must be boolean")
        if case.get("cache", "any") not in ("miss", "hit", "any"):
            raise ValueError("Unknown cache expectation")
        if case.get("cache") == "hit" and (type(case.get("minimum_cached_tokens")) is not int or case["minimum_cached_tokens"] <= 0):
            raise ValueError("Hit cases require a positive cached-token minimum")
        if "answer_letter" in case and case["answer_letter"] not in ("A", "B", "C", "D"):
            raise ValueError("Invalid answer letter")
    return cases


def run(args):
    parsed = urllib.parse.urlparse(args.base_url)
    if (parsed.scheme != "http" or parsed.hostname not in ("127.0.0.1", "localhost", "::1")
            or parsed.username or parsed.password or parsed.path not in ("", "/") or parsed.query or parsed.fragment):
        raise ValueError("Use a local, explicitly allocated benchmark endpoint")
    base_url = args.base_url.rstrip("/")
    suite_bytes = args.suite.read_bytes()
    suite = strict_json(suite_bytes)
    cases = validate_suite(suite)
    identity = strict_json(args.identity.read_bytes())
    for key in ("model_artifact_sha256", "binary_sha256", "metallib_sha256", "config_sha256", "prompt_contract_sha256"):
        if not re.fullmatch(r"[a-f0-9]{64}", identity.get(key, "")):
            raise ValueError(f"Missing launch identity: {key}")
    args.output.mkdir(mode=0o700)
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    def save(name, value):
        (args.output / name).write_text(json.dumps(value, indent=2, allow_nan=False) + "\n")
    def metrics(timeout=30):
        with opener.open(base_url + "/metrics", timeout=timeout) as response:
            return response.read().decode()
    save("identity.json", {"supplied_launch_identity": identity, "resource_window": args.resource_window,
                           "suite_sha256": hashlib.sha256(suite_bytes).hexdigest(),
                           "harness_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest()})
    initial = metrics()
    (args.output / "metrics-before.txt").write_text(initial)
    runtime_guard(initial)

    def request(case, barrier):
        payload = json.dumps(case["payload"]).encode()
        started = time.perf_counter()
        result = {"id": case["id"], "request_sha256": hashlib.sha256(payload).hexdigest()}
        try:
            # All request files are written before any cohort thread starts.
            # A failed worker cannot leave its peers stuck at an unbounded wait.
            barrier.wait(timeout=30)
            started = time.perf_counter()
            req = urllib.request.Request(base_url + "/v1/chat/completions", payload,
                                         {"Content-Type": "application/json"})
            with (args.output / (case["id"] + ".sse")).open("xb") as log, opener.open(req, timeout=1800) as response:
                def recorded_lines():
                    total = 0
                    while raw := response.readline(MAX_LINE_BYTES + 1):
                        total += len(raw)
                        if len(raw) > MAX_LINE_BYTES or total > MAX_STREAM_BYTES:
                            raise ValueError("SSE stream exceeded bounded capture limits")
                        log.write(raw)
                        yield raw
                result.update(consume(recorded_lines(), started))
            result["wall_seconds"] = time.perf_counter() - started
            check_case(case, result)
        except Exception as exc:
            barrier.abort()
            result.update(error=repr(exc), wall_seconds=time.perf_counter() - started)
        save(case["id"] + "-result.json", result)
        return result

    def wait_for_drain(index):
        deadline = time.monotonic() + 30
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise ValueError("Runtime failed to drain within 30 seconds; no further requests sent")
            observed = metrics(timeout=remaining)
            (args.output / f"metrics-cohort-{index}.txt").write_text(observed)
            if runtime_guard(observed, require_idle=False) and time.monotonic() < deadline:
                return
            if time.monotonic() >= deadline:
                raise ValueError("Runtime failed to drain within 30 seconds; no further requests sent")
            time.sleep(.25)

    summaries = []
    for index, cohort in enumerate(suite["cohorts"]):
        runtime_guard(metrics())
        for case in cohort["cases"]:
            save(case["id"] + "-request.json", case["payload"])
        barrier = threading.Barrier(len(cohort["cases"]))
        started = time.perf_counter()
        with concurrent.futures.ThreadPoolExecutor(max_workers=len(cohort["cases"])) as pool:
            results = list(pool.map(lambda c: request(c, barrier), cohort["cases"]))
        wall = time.perf_counter() - started
        response_valid = not any(r.get("error") for r in results)
        summary = {"cohort": cohort["id"], "measured": cohort.get("measured", True), "seconds": wall, "width": len(results),
                   "valid": False, "status": "awaiting_drain", "response_valid": response_valid,
                   "aggregate_end_to_end_tokens_per_second": None,
                   "cases": [{k: v for k, v in r.items() if k not in ("content", "reasoning", "events")} for r in results]}
        summaries.append(summary)
        save("cohorts.json", summaries)
        # Preserve result first, then enforce bounded drain and cache health.
        try:
            wait_for_drain(index)
        except Exception as exc:
            summary.update(status="runtime_failed", error=repr(exc))
            save("cohorts.json", summaries)
            raise
        summary["status"] = "valid" if response_valid else "invalid_response"
        summary["valid"] = response_valid
        if response_valid:
            summary["aggregate_end_to_end_tokens_per_second"] = sum(r["usage"]["completion_tokens"] for r in results) / wall
        save("cohorts.json", summaries)
        if not response_valid:
            raise ValueError("Invalid cohort; raw results retained; no further requests sent")
        # Separate cache staging from the timed interval, equally in every arm.
        time.sleep(1)
    final = metrics()
    (args.output / "metrics-after.txt").write_text(final)
    runtime_guard(final)
    save("complete.json", {"cohorts": len(summaries), "cases": len(cases), "qualified": False})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-url", required=True)
    parser.add_argument("--suite", type=Path, required=True)
    parser.add_argument("--identity", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--resource-window", required=True)
    run(parser.parse_args())


if __name__ == "__main__":
    main()
