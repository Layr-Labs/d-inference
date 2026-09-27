"""Four independent tool calls on the real Next model; never executes tools."""
import argparse
import json
from pathlib import Path
from api_matrix import MODEL, call
from reasoning_on_matrix import strict_chat, VISIBLE_MARKERS

EXPECTED = {"add": {"a": 7, "b": 5}, "multiply": {"a": 3, "b": 4},
            "subtract": {"a": 20, "b": 8}, "divide": {"a": 36, "b": 3}}

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    tools = [{"type": "function", "function": {"name": name,
        "description": "Perform " + name + " on a and b.", "parameters": {
        "type": "object", "properties": {"a": {"type": "integer"}, "b": {"type": "integer"}},
        "required": ["a", "b"], "additionalProperties": False}}} for name in EXPECTED]
    prompt = ("In this single response, call all four independent functions exactly once: "
              "add(a=7,b=5), multiply(a=3,b=4), subtract(a=20,b=8), divide(a=36,b=3). "
              "Do not substitute one call for another, calculate the results yourself, or wait "
              "between these independent calls. Return all four calls before any results arrive. "
              "Do not write an answer or preamble.")
    rows = []
    for thinking in (False, True):
        for stream in (False, True):
            name = f"four-tools-thinking-{str(thinking).lower()}-stream-{str(stream).lower()}"
            reasoning = {"enabled": thinking}
            if thinking: reasoning["effort"] = "low"
            request = {"model": MODEL, "messages": [{"role": "user", "content": prompt}],
                "tools": tools, "tool_choice": "required", "parallel_tool_calls": True,
                "reasoning": reasoning, "temperature": 0, "seed": 424242,
                "max_tokens": 512, "stream": stream, "stream_options": {"include_usage": True}}
            record = {"case": name, "request": request}
            try:
                status, raw = call("/v1/chat/completions", request)
                record.update(http=status, raw=raw)
                assert status == 200, f"HTTP {status}"
                view = strict_chat(raw, stream)
                record["view"] = view
                assert view["finish"] == "tool_calls"
                assert len(view["calls"]) == 4, f"expected four calls, got {len(view['calls'])}"
                assert len({item["id"] for item in view["calls"]}) == 4, "duplicate call identity"
                actual = {item["function"]["name"]: json.loads(item["function"]["arguments"])
                          for item in view["calls"]}
                assert actual == EXPECTED, "wrong function names or arguments"
                assert not any(marker in view["content"] for marker in VISIBLE_MARKERS)
                if not thinking: assert not view["reasoning"], "reasoning leaked while OFF"
                record["passed"] = True
            except Exception as error:
                record.update(passed=False, failure=f"{type(error).__name__}: {error}")
            with (args.output / (name + ".json")).open("x") as output:
                json.dump(record, output, indent=2)
            row = {key: record[key] for key in ("case", "http", "passed", "failure") if key in record}
            rows.append(row)
            print(json.dumps(row), flush=True)
    with (args.output / "summary.json").open("x") as output:
        json.dump({"model": MODEL, "scope": "four-call instruction and parser composition; no hosted routing",
                   "passed": all(row["passed"] for row in rows), "cases": rows}, output, indent=2)
    raise SystemExit(0 if all(row["passed"] for row in rows) else 1)

if __name__ == "__main__":
    main()
