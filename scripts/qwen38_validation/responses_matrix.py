"""Live Responses event/tool-history coverage. Synthetic requests only."""
import argparse
import json
from pathlib import Path
from api_matrix import MODEL, PROMPT, TOOL, call

def requests():
    function = {"type": "function", **TOOL["function"]}
    base = {"model": MODEL, "input": PROMPT, "reasoning": {"effort": "none"},
            "tools": [function], "temperature": 0, "max_output_tokens": 192, "parallel_tool_calls": False}
    for mode in ("auto", "required", "named", "none"):
        for stream in (False, True):
            choice = {"type": "function", "name": "add"} if mode == "named" else mode
            yield mode + ("-stream" if stream else "-plain"), {**base, "tool_choice": choice, "stream": stream}, "none" if mode == "none" else "tool"
    history = [{"type": "message", "role": "user", "content": PROMPT},
        {"type": "function_call", "id": "fc_synthetic", "call_id": "call_synthetic", "name": "add", "arguments": '{"a":7,"b":5}'},
        {"type": "function_call_output", "call_id": "call_synthetic", "output": "12"},
        {"type": "message", "role": "user", "content": "Reply with only the tool result: 12"}]
    for stream in (False, True):
        yield "history" + ("-stream" if stream else "-plain"), {**base, "input": history, "tool_choice": "none", "stream": stream}, "history"

def decode(raw, streaming):
    if not streaming: return json.loads(raw), []
    events = [json.loads(line[6:]) for line in raw.splitlines() if line.startswith("data: ")]
    assert events, "no Responses SSE events"
    assert all(event.get("object") != "chat.completion.chunk" for event in events), "Chat SSE on Responses endpoint"
    assert events[0]["type"] == "response.created", "missing response.created"
    assert events[-1]["type"] == "response.completed", "missing successful terminal"
    assert sum(event["type"] == "response.completed" for event in events) == 1
    sequence = [event["sequence_number"] for event in events]
    assert sequence == list(range(sequence[0], sequence[0] + len(sequence))), "nonconsecutive sequence numbers"
    return events[-1]["response"], events

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    results = []
    for name, payload, kind in requests():
        status, raw = call("/v1/responses", payload)
        record = {"case": name, "request": payload, "http": status, "raw": raw}
        try:
            assert status == 200, f"HTTP {status}"
            response, events = decode(raw, payload["stream"])
            assert response["status"] == "completed"
            assert not any(item["type"] == "reasoning" for item in response["output"]), "unexpected reasoning item"
            assert not any("reasoning" in event["type"] for event in events), "unexpected reasoning event"
            tools = [item for item in response["output"] if item["type"] == "function_call"]
            if kind == "tool":
                assert len(tools) == 1 and tools[0]["name"] == "add", "wrong tool count/name"
                assert json.loads(tools[0]["arguments"]) == {"a": 7, "b": 5}, "wrong arguments"
                if events:
                    delta = "".join(event["delta"] for event in events if event["type"] == "response.function_call_arguments.delta")
                    assert delta == tools[0]["arguments"], "streamed arguments differ from final output"
                    assert any(event["type"] == "response.function_call_arguments.done" for event in events)
            else:
                assert not tools, "tool_choice none returned call"
                if kind == "history":
                    text = "".join(part.get("text", "") for item in response["output"] for part in item.get("content", []))
                    assert text.strip() == "12", "tool history not preserved"
            assert response["usage"]["output_tokens"] > 0, "missing usage"
            record["passed"] = True
        except Exception as error:
            record["passed"] = False
            record["failure"] = str(error)
        (args.output / (name + ".json")).write_text(json.dumps(record, indent=2))
        result = {key: record[key] for key in ("case", "http", "passed", "failure") if key in record}
        results.append(result)
        print(json.dumps(result), flush=True)
    (args.output / "summary.json").write_text(json.dumps(results, indent=2))
    assert all(result["passed"] for result in results)
