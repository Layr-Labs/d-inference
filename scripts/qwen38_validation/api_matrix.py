"""Bounded real-server Chat/Responses contract checks; never execute tool calls."""
import argparse
import json
from pathlib import Path
import urllib.error
import urllib.request
from endpoint_config import base_url, headers, open_request

MODEL = "DarkBloom/Qwen3.8-Flash-Next-Q4-mtp"
TOOL = {"type": "function", "function": {"name": "add", "description": "Add two integers.",
        "parameters": {"type": "object", "properties": {"a": {"type": "integer"},
        "b": {"type": "integer"}}, "required": ["a", "b"], "additionalProperties": False}}}
PROMPT = "Call add with a=7 and b=5 exactly once."
MARKERS = ("<think>", "</think>", "<tool_call>", "</tool_call>", "<function=", "<parameter=")

def call(endpoint, payload):
    request = urllib.request.Request(base_url() + endpoint,
        data=json.dumps(payload).encode(), headers=headers())
    try:
        with open_request(request, timeout=300) as response:
            return response.status, response.read().decode()
    except urllib.error.HTTPError as error:
        return error.code, error.read().decode()

def chat_view(raw, streaming):
    if not streaming:
        data = json.loads(raw)
        choice = data["choices"][0]
        message = choice["message"]
        return {"content": message.get("content") or "", "reasoning": message.get("reasoning_content") or "",
                "calls": message.get("tool_calls", []), "finish": choice["finish_reason"],
                "usage": data.get("usage"), "done": True}
    frames = [line[6:] for line in raw.splitlines() if line.startswith("data: ")]
    out = {"content": "", "reasoning": "", "calls": [], "finish": None, "usage": None,
           "done": frames.count("[DONE]") == 1 and frames[-1] == "[DONE]"}
    calls = {}
    for frame in frames:
        if frame == "[DONE]": continue
        data = json.loads(frame)
        if data.get("usage"): out["usage"] = data["usage"]
        for choice in data.get("choices", []):
            if choice.get("finish_reason"): out["finish"] = choice["finish_reason"]
            delta = choice.get("delta", {})
            out["content"] += delta.get("content") or ""
            out["reasoning"] += delta.get("reasoning_content") or ""
            for item in delta.get("tool_calls", []):
                target = calls.setdefault(item["index"], {"function": {"name": "", "arguments": ""}})
                for key in ("name", "arguments"):
                    target["function"][key] += item.get("function", {}).get(key) or ""
    out["calls"] = [calls[key] for key in sorted(calls)]
    return out

def cases():
    base = {"model": MODEL, "temperature": 0, "seed": 424242, "max_tokens": 192,
            "messages": [{"role": "user", "content": PROMPT}], "tools": [TOOL], "parallel_tool_calls": False}
    controls = [("boolean", {"enable_thinking": False}),
                ("typed", {"reasoning": {"enabled": False}}),
                ("nested", {"chat_template_kwargs": {"enable_thinking": False}})]
    for mode in ("auto", "required", "named", "none"):
        for stream in (False, True):
            choice = {"type": "function", "function": {"name": "add"}} if mode == "named" else mode
            yield "chat-" + mode + ("-stream" if stream else "-plain"), "/v1/chat/completions", {
                **base, "enable_thinking": False, "tool_choice": choice, "stream": stream,
                "stream_options": {"include_usage": True}}, "none" if mode == "none" else "tool"
    for label, control in controls[1:]:
        yield "chat-required-" + label, "/v1/chat/completions", {**base, **control, "tool_choice": "required"}, "tool"
    history = [{"role": "user", "content": PROMPT}, {"role": "assistant", "content": None,
        "tool_calls": [{"id": "synthetic_add", "type": "function", "function": {"name": "add", "arguments": '{"a":7,"b":5}'}}]},
        {"role": "tool", "tool_call_id": "synthetic_add", "content": "12"},
        {"role": "user", "content": "Reply with only the tool result: 12"}]
    yield "chat-tool-history", "/v1/chat/completions", {**base, "messages": history, "enable_thinking": False, "tool_choice": "none"}, "history"
    yield "responses-none-plain", "/v1/responses", {"model": MODEL,
        "input": "Reply exactly: ready", "reasoning": {"effort": "none"}, "max_output_tokens": 64,
        "temperature": 0}, "responses"

def verify(kind, payload, status, raw):
    assert status == 200, f"HTTP {status}"
    if kind == "responses":
        data = json.loads(raw)
        assert data["status"] == "completed"
        assert not any(item["type"] == "reasoning" for item in data["output"])
        text = "".join(part.get("text", "") for item in data["output"] for part in item.get("content", []))
        assert text.strip() == "ready", "unexpected Responses text"
        return {"output_types": [x["type"] for x in data["output"]], "usage": data["usage"]}
    view = chat_view(raw, payload.get("stream", False))
    assert view["done"] and view["usage"], "missing terminal or usage"
    assert not view["reasoning"], "reasoning leaked while disabled"
    assert not any(marker in view["content"] for marker in MARKERS), "internal framing leaked"
    if kind == "tool":
        assert view["finish"] == "tool_calls" and len(view["calls"]) == 1, "missing/duplicate tool call"
        function = view["calls"][0]["function"]
        assert function["name"] == "add" and json.loads(function["arguments"]) == {"a": 7, "b": 5}, "wrong arguments"
    else:
        assert not view["calls"], "tool_choice none produced a call"
        if kind == "history": assert view["content"].strip() == "12", "lost tool history"
    return view

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--only", default="")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    results = []
    for name, endpoint, payload, kind in cases():
        if args.only and args.only not in name: continue
        status, raw = call(endpoint, payload)
        record = {"case": name, "endpoint": endpoint, "request": payload, "http": status, "raw": raw}
        try:
            record["view"] = verify(kind, payload, status, raw)
            record["passed"] = True
        except Exception as error:
            record["passed"] = False
            record["failure"] = str(error)
        (args.output / (name + ".json")).write_text(json.dumps(record, indent=2))
        results.append({key: value for key, value in record.items() if key in ("case", "http", "passed", "failure")})
        print(json.dumps(results[-1]), flush=True)
    (args.output / "summary.json").write_text(json.dumps(results, indent=2))
    assert results and all(row["passed"] for row in results), "one or more cases failed; preserve receipts"
