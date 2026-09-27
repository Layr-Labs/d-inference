"""Bounded reasoning-ON contracts on the existing loopback Flash-Next server.

Run once per externally recorded MTP mode/binary. Never starts a server, executes
tools, uses hosted OpenRouter, or mutates model/runtime configuration. The owned
template accepts low/medium/xhigh; high is a compatibility observation followed
by a required recovery request, not a supported-positive case.
"""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import time

from api_matrix import MODEL, TOOL, MARKERS, call, chat_view
from responses_matrix import decode as responses_decode

assert MODEL == "DarkBloom/Qwen3.8-Flash-Next-Q4-mtp"
CHAT = "/v1/chat/completions"
RESPONSES = "/v1/responses"
TOOL_PROMPT = "Use the add function exactly once with a=7 and b=5. After its result arrives, reply with only the resulting integer."
TEXT_PROMPT = "There are four boxes with seven screws each. Sixteen screws are used. Work out the remainder, then give only the final integer."
VISIBLE_MARKERS = MARKERS + ("</function>", "</parameter>", "<|im_start|>", "<|im_end|>")
LIMITS = [
    "Local provider controls and protocol only; no hosted OpenRouter auth/routing/billing or adapter qualification.",
    "No claims about hosted exclude, reasoning.max_tokens, reasoning_details, or other adapter-dependent fields.",
    "MTP mode, binary, native architecture and artifact identities must be recorded by the invoking run.",
    "Explicit reasoning ON does not require a thought for every simple tool call; dedicated text probes require a nonempty reasoning channel.",
    "The native unsupported high-effort result is reported separately and cannot qualify supported high effort.",
    "Transport failures retain request/error receipts; api_matrix.call cannot recover partially read response bytes after a read exception.",
]


def chat_payload(messages=None, reasoning=None, stream=False):
    # Fresh construction deliberately contains no inherited reasoning-OFF alias.
    return {"model": MODEL, "temperature": 0, "seed": 424242, "max_tokens": 512,
            "messages": messages or [{"role": "user", "content": TOOL_PROMPT}],
            "reasoning": copy.deepcopy(reasoning if reasoning is not None else {"enabled": True, "effort": "low"}),
            "stream": stream, "stream_options": {"include_usage": True}, "parallel_tool_calls": False}


def validate_usage(usage, responses=False):
    assert isinstance(usage, dict), "missing usage"
    a, b = ("input_tokens", "output_tokens") if responses else ("prompt_tokens", "completion_tokens")
    assert all(type(usage.get(key)) is int and usage[key] > 0 for key in (a, b)), "missing/invalid input or output usage"
    assert type(usage.get("total_tokens")) is int and usage["total_tokens"] == usage[a] + usage[b], "invalid total usage"


def strict_chat(raw, streaming):
    view = chat_view(raw, streaming)
    assert view["done"], "missing one final DONE"
    if not streaming:
        data = json.loads(raw)
        assert len(data["choices"]) == 1 and data["choices"][0].get("index", 0) == 0
        assert data.get("model") == MODEL, "wrong served model"
        assert not data.get("error"), "error object on success"
        view["terminal_count"] = 1
    else:
        frames = [line[6:] for line in raw.splitlines() if line.startswith("data: ")]
        assert frames and frames[-1] == "[DONE]" and frames.count("[DONE]") == 1
        finish_count, calls, response_ids = 0, {}, set()
        for frame in frames[:-1]:
            event = json.loads(frame)
            assert not event.get("error"), "streamed error"
            assert event.get("model") == MODEL, "wrong served model"
            assert event.get("object") == "chat.completion.chunk", "wrong Chat event shape"
            response_ids.add(event.get("id"))
            for choice in event.get("choices", []):
                assert choice.get("index", 0) == 0, "unexpected completion index"
                finish_count += choice.get("finish_reason") is not None
                for fragment in choice.get("delta", {}).get("tool_calls", []) or []:
                    index = fragment.get("index")
                    assert type(index) is int and index >= 0, "missing tool index"
                    target = calls.setdefault(index, {})
                    for key in ("id", "type"):
                        if fragment.get(key):
                            assert not target.get(key) or target[key] == fragment[key], "tool identity changed mid-stream"
                            target[key] = fragment[key]
        assert finish_count == 1, "expected one logical finish reason"
        assert len(response_ids) == 1 and None not in response_ids, "unstable response identity"
        assert len(calls) == len(view["calls"])
        for value, index in zip(view["calls"], sorted(calls)):
            value.update(calls[index])
        view["terminal_count"] = finish_count
    validate_usage(view["usage"])
    return view


def strict_responses(raw, streaming):
    response, events = responses_decode(raw, streaming)
    assert response["status"] == "completed", "Responses did not complete"
    assert response.get("model") == MODEL, "wrong served model"
    assert not response.get("error")
    output = response.get("output", [])
    text = "".join(part.get("text", "") for item in output if item.get("type") == "message"
                   for part in item.get("content", []) or [])
    thought = "".join(part.get("text", "") for item in output if item.get("type") == "reasoning"
                      for part in (item.get("summary") or item.get("content") or []))
    calls = [{"id": item.get("call_id"), "type": "function", "function": {
        "name": item.get("name"), "arguments": item.get("arguments")}}
        for item in output if item.get("type") == "function_call"]
    if streaming:
        terminals = [e for e in events if e["type"] in ("response.completed", "response.failed", "response.incomplete", "response.cancelled")]
        assert len(terminals) == 1 and terminals[0]["type"] == "response.completed"
        assert sum(e["type"] == "response.created" for e in events) == 1
        assert sum(e["type"] == "response.in_progress" for e in events) == 1
        assert not any(e.get("error") for e in events), "Responses error event"
        assert "".join(e.get("delta", "") for e in events if e["type"] == "response.output_text.delta") == text
        assert "".join(e.get("delta", "") for e in events if e["type"] == "response.reasoning_summary_text.delta") == thought
        for item in (i for i in output if i.get("type") == "function_call"):
            fragments = [e for e in events if e.get("item_id") == item["id"]]
            assert "".join(e.get("delta", "") for e in fragments if e["type"] == "response.function_call_arguments.delta") == item["arguments"]
            assert sum(e["type"] == "response.function_call_arguments.done" for e in fragments) == 1
        assert len([e for e in events if e["type"] == "response.output_item.done"]) == len(output)
    validate_usage(response.get("usage"), responses=True)
    return {"content": text, "reasoning": thought, "calls": calls,
            "finish": "tool_calls" if calls else "stop", "usage": response["usage"],
            "done": True, "terminal_count": 1, "output_types": [i["type"] for i in output]}


def verify(endpoint, payload, status, raw, kind, require_reasoning=False):
    assert status == 200, f"HTTP {status}"
    view = strict_chat(raw, payload["stream"]) if endpoint == CHAT else strict_responses(raw, payload["stream"])
    # Only visible answer text is a framing boundary. Thoughts and argument
    # strings can legitimately contain literal marker examples and stay opaque.
    assert not any(marker in view["content"] for marker in VISIBLE_MARKERS), "framing leaked into visible answer"
    if require_reasoning:
        assert view["reasoning"].strip(), "reasoning ON did not produce a distinct reasoning channel"
    if kind == "tool":
        assert view["finish"] == "tool_calls" and len(view["calls"]) == 1, "missing/duplicate tool call"
        assert not view["content"].strip(), "tool-only request produced visible prose"
        tool = view["calls"][0]
        assert isinstance(tool.get("id"), str) and tool["id"], "missing real tool call ID"
        assert tool.get("type") == "function"
        function = tool["function"]
        assert function["name"] == "add" and json.loads(function["arguments"]) == {"a": 7, "b": 5}, "wrong tool arguments"
    else:
        assert not view["calls"], "direct answer produced tool calls"
        assert view["finish"] == "stop" and view["content"].strip() == "12", "wrong/missing final answer"
    return view


def save(path, value):
    with path.open("x", encoding="utf-8") as stream:
        json.dump(value, stream, ensure_ascii=False, indent=2)
        stream.write("\n")


class Matrix:
    def __init__(self, output):
        self.output, self.rows = output, []

    def run(self, name, endpoint, payload, kind, require_reasoning=False, dependency_failure=None):
        record = {"case": name, "endpoint": endpoint, "request": copy.deepcopy(payload),
                  "required": kind != "unsupported-high-probe", "started_unix": time.time()}
        started = time.monotonic()
        try:
            assert not dependency_failure, dependency_failure
            assert payload["model"] == MODEL
            assert "enable_thinking" not in payload and "chat_template_kwargs" not in payload
            status, raw = call(endpoint, payload)
            record.update(http=status, raw=raw)
            if kind == "unsupported-high-probe":
                # Record both rejection and unexpected acceptance. Neither is a
                # supported-high pass, and recovery is verified separately.
                record["native_effort_supported"] = False
                record["observation"] = "rejected" if status >= 400 else "accepted_or_streamed"
                record["passed"] = None
                if status == 200:
                    try:
                        record["view"] = strict_chat(raw, payload["stream"])
                    except Exception as error:
                        record["parse_observation"] = f"{type(error).__name__}: {error}"
            else:
                record["view"] = verify(endpoint, payload, status, raw, kind, require_reasoning)
                record["passed"] = True
        except Exception as error:
            record.update(passed=False, failure=f"{type(error).__name__}: {error}")
        record["elapsed_seconds"] = time.monotonic() - started
        save(self.output / (name + ".json"), record)
        row = {key: record[key] for key in ("case", "required", "http", "passed", "observation", "failure") if key in record}
        self.rows.append(row)
        print(json.dumps(row), flush=True)
        return record


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    from endpoint_config import base_url
    save(args.output / "run.json", {"model": MODEL, "base": base_url(),
        "harness_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(), "limits": LIMITS,
        "planned_requests": 20, "supported_positive_cases": 19, "native_high_compatibility_probes": 1})
    matrix, actual_auto = Matrix(args.output), None
    for mode in ("auto", "required", "named", "none"):
        for stream in (False, True):
            payload = chat_payload(stream=stream)
            payload["tools"] = [copy.deepcopy(TOOL)]
            payload["tool_choice"] = {"type": "function", "function": {"name": "add"}} if mode == "named" else mode
            if mode == "none":
                payload["messages"] = [{"role": "user", "content": "Do not use a function. Work out 7+5, then reply with only the final integer."}]
            result = matrix.run("chat-low-" + mode + ("-stream" if stream else "-plain"), CHAT, payload,
                                "text" if mode == "none" else "tool")
            if mode == "auto" and not stream and result.get("passed"):
                actual_auto = result["view"]

    matrix.run("chat-low-reasoning-text", CHAT,
        chat_payload(messages=[{"role": "user", "content": TEXT_PROMPT}]), "text", require_reasoning=True)

    for stream in (False, True):
        payload = chat_payload(stream=stream)
        dependency = None
        if actual_auto:
            tool_call = copy.deepcopy(actual_auto["calls"][0])
            payload["messages"] = [{"role": "user", "content": TOOL_PROMPT},
                {"role": "assistant", "content": actual_auto["content"], "reasoning_content": actual_auto["reasoning"],
                 "tool_calls": [tool_call]},
                {"role": "tool", "tool_call_id": tool_call["id"], "content": "12"}]
        else:
            dependency = "actual auto tool call failed; no synthetic history substituted"
        payload.update(tools=[copy.deepcopy(TOOL)], tool_choice="auto")
        matrix.run("chat-low-real-history-" + ("stream" if stream else "plain"), CHAT, payload, "text", dependency_failure=dependency)

    for kind in ("text", "tool"):
        for stream in (False, True):
            payload = {"model": MODEL, "input": TEXT_PROMPT if kind == "text" else TOOL_PROMPT,
                "reasoning": {"effort": "low"}, "temperature": 0, "max_output_tokens": 512, "stream": stream,
                "parallel_tool_calls": False}
            if kind == "tool":
                payload.update(tools=[{"type": "function", **copy.deepcopy(TOOL["function"])}], tool_choice="required")
            matrix.run("responses-low-" + kind + ("-stream" if stream else "-plain"), RESPONSES,
                       payload, kind, require_reasoning=kind == "text")

    for effort in (None, "medium", "xhigh"):
        reasoning = {"enabled": True}
        if effort is not None: reasoning["effort"] = effort
        matrix.run("chat-effort-" + (effort or "default-enabled"), CHAT,
            chat_payload(messages=[{"role": "user", "content": TEXT_PROMPT}], reasoning=reasoning),
            "text", require_reasoning=True)

    matrix.run("chat-high-native-compatibility-probe", CHAT,
        chat_payload(messages=[{"role": "user", "content": TEXT_PROMPT}], reasoning={"enabled": True, "effort": "high"}),
        "unsupported-high-probe")
    matrix.run("chat-low-recovery-after-high", CHAT,
        chat_payload(messages=[{"role": "user", "content": TEXT_PROMPT}]), "text", require_reasoning=True)

    required = [row for row in matrix.rows if row["required"]]
    summary = {"schema": 1, "model": MODEL, "scope": "local native reasoning-ON API/tool matrix",
               "passed": len(matrix.rows) == 20 and len(required) == 19 and all(row["passed"] for row in required),
               "cases": matrix.rows, "limits": LIMITS}
    save(args.output / "summary.json", summary)
    raise SystemExit(0 if summary["passed"] else 1)


if __name__ == "__main__":
    main()
