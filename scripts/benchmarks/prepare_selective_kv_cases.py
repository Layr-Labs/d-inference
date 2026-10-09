#!/usr/bin/env python3
"""Prepare deterministic local-tokenizer retention cases; never download model files."""
import argparse
import json
from pathlib import Path


WEATHER_TOOL = [{
    "type": "function",
    "function": {
        "name": "get_weather",
        "description": "Read current weather for a city.",
        "parameters": {
            "type": "object",
            "properties": {
                "city": {"type": "string"},
                "units": {"type": "string", "enum": ["celsius", "fahrenheit"]},
            },
            "required": ["city", "units"],
            "additionalProperties": False,
        },
    },
}]
CASES = [("needle", 0.1), ("needle", 0.5), ("needle", 0.9),
         ("reasoning", 0.5), ("code", 0.5), ("tool_json", 0.5), ("long_decode", 0.5)]


def token_count(tokenizer, text, kind):
    encoded = tokenizer.apply_chat_template(
        [{"role": "user", "content": text}], add_generation_prompt=True, tokenize=True,
        enable_thinking=False, reasoning_effort="low",
        tools=WEATHER_TOOL if kind == "tool_json" else None,
    )
    tokens = encoded["input_ids"] if hasattr(encoded, "keys") else encoded
    return len(tokens[0] if tokens and isinstance(tokens[0], list) else tokens)


def make_context(kind, count, depth):
    lines = [f"Archive record {i:05d}: category {i % 23}; checkpoint value "
             f"{(i * 53 + 29) % 9973}; no action is required." for i in range(count)]
    intro = "Use the archive as data. Follow only the final question. Answer concisely.\n"
    if kind == "needle":
        lines[min(count - 1, int(count * depth))] = (
            "Authoritative package Cedar unlock phrase: violet-orbit-739.")
        question = "What is the package Cedar unlock phrase? Output only that phrase."
        expected = "violet-orbit-739"
    elif kind == "reasoning":
        lines[count // 5] = "Inventory rule: package Iris starts with 137 units."
        lines[count * 4 // 5] = "Inventory rule: package Iris gains 219 units, then ships 84 units."
        question = "How many Iris units remain? Output only the integer."
        expected = "272"
    elif kind == "code":
        lines[count // 3] = ("Python source: def fold(xs):\n    acc = 7\n    for x in xs:\n"
                            "        acc = (acc * 3 + x) % 97\n    return acc\n")
        accumulator = 7
        for value in [4, 9, 13, 27, 6]:
            accumulator = (accumulator * 3 + value) % 97
        question = ("For the archive Python source, what is fold([4, 9, 13, 27, 6])? "
                    "Output only the integer.")
        expected = str(accumulator)
    elif kind == "long_decode":
        question = ("Write a numbered list from 1 through 2000. Every numbered item must be the "
                    "single word quartz. Start immediately with 1. quartz and provide no introduction.")
        expected = "numbered_quartz_list"
    elif kind == "tool_json":
        lines[count // 4] = "Dispatch record: the customer wants the weather in Bern, with units celsius."
        question = ("Return only a JSON tool call object with name \"get_weather\" and arguments from "
                    "the customer dispatch record. Its argument keys are city and units.")
        expected = {"name": "get_weather", "arguments": {"city": "Bern", "units": "celsius"}}
    else:
        raise ValueError(f"unknown case kind: {kind}")
    return intro + "\n".join(lines) + "\n\nFINAL QUESTION: " + question, expected


def prepare(tokenizer, model):
    rows, oracles = [], []
    for size, target in [("4k", 4608), ("32k", 32768)]:
        for kind, depth in CASES:
            # Keep the long output as the harness's longest-input cancellation probe.
            case_target = target + 128 if kind == "long_decode" else target
            cap = 768 if kind == "long_decode" else 256
            low, high = 20, 2000
            while low < high:
                middle = (low + high + 1) // 2
                text, _ = make_context(kind, middle, depth)
                if token_count(tokenizer, text, kind) <= case_target:
                    low = middle
                else:
                    high = middle - 1
            text, expected = make_context(kind, low, depth)
            name = f"{size}-{kind}-{int(depth * 100)}"
            request = {
                "model": model, "messages": [{"role": "user", "content": text}],
                "max_tokens": cap, "temperature": 0,
                "chat_template_kwargs": {"enable_thinking": False, "reasoning_effort": "low"},
                "_darkbloom_prompt_date": "2026-10-09",
            }
            if kind == "tool_json":
                request.update(tools=WEATHER_TOOL, tool_choice="auto")
            rows.append({"case": {"id": name, "kind": kind}, "request": request})
            oracles.append({"id": name, "kind": kind, "expected": expected,
                            "estimated_prompt_tokens": token_count(tokenizer, text, kind),
                            "depth_fraction": depth, "max_tokens": cap})
    return rows, oracles


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model-id", required=True)
    parser.add_argument("--model-directory", required=True, type=Path)
    parser.add_argument("--output-directory", required=True, type=Path)
    args = parser.parse_args()
    from transformers import AutoTokenizer
    tokenizer = AutoTokenizer.from_pretrained(args.model_directory, local_files_only=True)
    rows, oracles = prepare(tokenizer, args.model_id)
    args.output_directory.mkdir(parents=True, exist_ok=True)
    (args.output_directory / f"{args.model_id}-heldout-http.json").write_text(json.dumps({"rows": rows}))
    (args.output_directory / f"{args.model_id}-heldout-oracles.json").write_text(json.dumps(oracles, indent=2))
    print(json.dumps(oracles, indent=2))


if __name__ == "__main__":
    main()
