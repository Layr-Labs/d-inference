#!/usr/bin/env python3
"""Bounded local HTTP cache benchmark; Python standard library only.

Run against an already-loaded, isolated provider. Replay the baseline's requests
for a candidate so multi-turn messages remain byte-identical across versions.
Raw SSE events, complete requests/output, usage and metrics are retained. HTTP
text/count equality is deliberately not presented as generated-token equality.
"""

import argparse
import hashlib
import json
from pathlib import Path
import time
import urllib.request


PARAGRAPH = (
    "The committee reviewed regional water infrastructure. Reservoir levels "
    "recovered after spring rain while agricultural demand rose. Engineers "
    "proposed staged pumping station upgrades, canal maintenance, and acoustic "
    "leak detection. The council requested costs, schedules, and a review of "
    "risks to downstream users during construction. "
)


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True).encode()).hexdigest()


def events(lines):
    """Parse SSE frames, including multiline data and CRLF, without losing errors."""
    data = []
    for raw in lines:
        line = raw.decode("utf-8").rstrip("\r\n")
        if not line:
            if data:
                yield "\n".join(data)
                data = []
        elif line.startswith("data:"):
            data.append(line[5:].removeprefix(" "))
    if data:
        yield "\n".join(data)


def collect(payloads, started, clock=time.perf_counter, cancel_after=None):
    result = {"events": [], "text": "", "reasoning": "", "usage": None,
              "finish_reasons": [], "done": False, "cancelled": False}
    first = last = None
    chunks = 0
    for payload in payloads:
        elapsed = clock() - started
        result["events"].append({"elapsed_s": elapsed, "data": payload})
        if payload == "[DONE]":
            result["done"] = True
            break
        event = json.loads(payload)
        if event.get("error"):
            raise RuntimeError(f"SSE error: {event['error']}")
        if event.get("usage") is not None:
            result["usage"] = event["usage"]
        emitted = False
        for choice in event.get("choices", []):
            if choice.get("index", 0) != 0:
                raise RuntimeError("benchmark expects a single completion")
            delta = choice.get("delta", {})
            content = delta.get("content") or ""
            reasoning = delta.get("reasoning_content", delta.get("reasoning")) or ""
            result["text"] += content
            result["reasoning"] += reasoning
            emitted |= bool(content or reasoning or delta.get("tool_calls"))
            if choice.get("finish_reason") is not None:
                result["finish_reasons"].append(choice["finish_reason"])
        if emitted:
            first = elapsed if first is None else first
            last = elapsed
            chunks += 1
            if cancel_after and chunks >= cancel_after:
                result["cancelled"] = True
                break
    result.update(ttft_s=first, last_content_s=last, elapsed_s=clock() - started,
                  content_chunks=chunks)
    if not result["cancelled"]:
        if not result["done"] or result["usage"] is None or not result["finish_reasons"]:
            raise RuntimeError("incomplete stream: DONE, terminal reason and usage required")
        if first is None:
            raise RuntimeError("completion emitted no content or reasoning")
        for key in ("prompt_tokens", "completion_tokens"):
            if not isinstance(result["usage"].get(key), int) or result["usage"][key] < 1:
                raise RuntimeError(f"missing or invalid usage.{key}")
    count = (result["usage"] or {}).get("completion_tokens", 0)
    duration = last - first if last is not None and first is not None else 0
    # One SSE chunk can contain several tokens; this is a client estimate,
    # never a substitute for the engine's per-token decode measurement.
    result["client_decode_tps_estimate"] = (count - 1) / duration if count > 1 and duration > 0 else None
    return result


def request(base, body, cancel_after=None):
    encoded = json.dumps(body).encode()
    req = urllib.request.Request(base.rstrip("/") + "/v1/chat/completions", data=encoded,
                                 headers={"Content-Type": "application/json"})
    started = time.perf_counter()
    with urllib.request.urlopen(req, timeout=300) as response:
        return collect(events(response), started, cancel_after=cancel_after)


def metrics(base):
    with urllib.request.urlopen(base.rstrip("/") + "/metrics", timeout=10) as response:
        return response.read().decode()


def body(model, messages, max_tokens):
    return {"model": model, "messages": messages, "max_tokens": max_tokens,
            "temperature": 0, "top_p": 1, "stream": True,
            "stream_options": {"include_usage": True},
            "chat_template_kwargs": {"enable_thinking": False}}


def cases(lengths, repeats):
    """Each repetition has an early unique prefix; branches share its long body."""
    for length in lengths:
        filler = (PARAGRAPH * (int(length * 4.3) // len(PARAGRAPH) + 1))[:int(length * 4.3)]
        for repetition in range(repeats):
            group = f"p{length}-r{repetition}"
            messages = [
                {"role": "system", "content": f"Benchmark conversation {group}. Answer clearly."},
                {"role": "user", "content": filler + "\nSummarize the proposed work in three sentences."},
            ]
            yield {"id": group + "-first", "kind": "first", "target_length": length,
                   "messages": messages, "max_tokens": 64}
            yield {"id": group + "-repeat", "kind": "repeat", "target_length": length,
                   "messages": messages, "max_tokens": 64, "equal_to": group + "-first"}
            branch = [messages[0], {"role": "user", "content": filler + "\nList the risks in three sentences."}]
            yield {"id": group + "-branch", "kind": "branch", "target_length": length,
                   "messages": branch, "max_tokens": 64}
            yield {"id": group + "-branch-repeat", "kind": "branch-repeat", "target_length": length,
                   "messages": branch, "max_tokens": 64, "equal_to": group + "-branch"}
            for suffix in ("turn2", "turn2-repeat"):
                yield {"id": group + "-" + suffix, "kind": suffix, "target_length": length,
                       "parent": group + "-first", "max_tokens": 64,
                       **({"equal_to": group + "-turn2"} if suffix.endswith("repeat") else {})}
    for repetition in range(repeats):
        yield {"id": f"decode-{repetition}", "kind": "decode", "target_length": None,
               "messages": [{"role": "user", "content": f"Review {repetition}: Explain how a city can detect and repair water leaks. Give detailed practical steps."}],
               "max_tokens": 256}


def assistant_message(response):
    message = {"role": "assistant", "content": response["text"]}
    if response["reasoning"]:
        message["reasoning_content"] = response["reasoning"]
    return message


def equality(left, right):
    fields = ("text", "reasoning", "finish_reasons")
    differences = [key for key in fields if left[key] != right[key]]
    for key in ("prompt_tokens", "completion_tokens"):
        if (left.get("usage") or {}).get(key) != (right.get("usage") or {}).get(key):
            differences.append(key)
    return {"text_and_counts_equal": not differences, "differences": differences,
            "generated_token_ids_compared": False}


def run(args):
    out = Path(args.output)
    out.mkdir(parents=True, exist_ok=False)
    reference = {}
    if args.replay:
        reference = {row["case"]["id"]: row for row in json.loads(Path(args.replay).read_text())["rows"]}
    rows = []
    by_id = {}
    # Model loading and kernel warmup are explicit, retained and excluded.
    warmup = request(args.base, body(args.model, [{"role": "user", "content": "Say hello."}], 8))
    (out / "warmup.json").write_text(json.dumps(warmup, indent=2))
    (out / "metrics-before.txt").write_text(metrics(args.base))
    plan = [row["case"] for row in reference.values()] if reference else cases(args.lengths, args.repeats)
    for case in plan:
        if reference:
            req_body = reference[case["id"]]["request"]
            if req_body["model"] != args.model:
                raise ValueError("replay model must match baseline")
        else:
            messages = case.get("messages")
            if messages is None:
                parent = by_id[case["parent"]]
                messages = parent["request"]["messages"] + [assistant_message(parent["response"]),
                    {"role": "user", "content": "Which proposed task should happen first, and why?"}]
            req_body = body(args.model, messages, case["max_tokens"])
        response = request(args.base, req_body)
        row = {"case": case, "request": req_body, "request_sha256": digest(req_body), "response": response}
        if case.get("equal_to"):
            row["repeat_equality"] = equality(by_id[case["equal_to"]]["response"], response)
        if reference:
            row["baseline_equality"] = equality(reference[case["id"]]["response"], response)
        by_id[case["id"]] = row
        rows.append(row)
        (out / (case["id"] + ".json")).write_text(json.dumps(row, indent=2))
        print(json.dumps({"id": case["id"], "ttft_s": response["ttft_s"], "usage": response["usage"],
                          "baseline_equality": row.get("baseline_equality")}), flush=True)
    # Disconnect mid-decode, then verify the same long-lived server serves again.
    cancellation = request(args.base, body(args.model, [{"role": "user", "content": "Explain water infrastructure in great detail."}], 1024), cancel_after=3)
    recovery = request(args.base, body(args.model, [{"role": "user", "content": "What is two plus two?"}], 32))
    (out / "cancellation.json").write_text(json.dumps({"cancel": cancellation, "recovery": recovery}, indent=2))
    (out / "metrics-after.txt").write_text(metrics(args.base))
    report = {"schema": 1, "label": args.label, "base": args.base,
              "harness_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
              "replay": args.replay, "rows": rows,
              "limitations": ["HTTP does not expose generated token IDs or prefix cache usage at e928d395f.",
                              "Target lengths are approximate; usage.prompt_tokens is authoritative.",
                              "Client decode rate is an estimate because SSE chunks can contain multiple tokens.",
                              "Cache-off controls and engine evidence are required to attribute a repeat speedup."]}
    (out / "report.json").write_text(json.dumps(report, indent=2))
    if any(not row[key]["text_and_counts_equal"] for row in rows for key in ("repeat_equality", "baseline_equality") if key in row):
        raise SystemExit("Output/count mismatch: see retained per-request evidence")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", default="http://127.0.0.1:18120")
    parser.add_argument("--model", default="EigenLabs/Qwen3.8-27B-4bit-mtp")
    parser.add_argument("--output", required=True)
    parser.add_argument("--label", required=True)
    parser.add_argument("--replay", help="baseline report.json: reuse its exact requests")
    parser.add_argument("--lengths", type=lambda raw: [int(x) for x in raw.split(",")], default=[512, 2048, 8192])
    parser.add_argument("--repeats", type=int, default=3)
    args = parser.parse_args()
    if not 1 <= args.repeats <= 5 or any(n < 1 or n > 32768 for n in args.lengths):
        parser.error("bounded run requires repeats 1..5 and target lengths 1..32768")
    run(args)


if __name__ == "__main__":
    main()
