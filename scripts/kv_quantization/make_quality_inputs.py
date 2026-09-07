#!/usr/bin/env python3
"""Build authored generation probes with pinned templates and visible answers.

These cases exercise arithmetic, state tracking, code, and long-context retrieval.
They are regression probes, not a substitute for a broad public evaluation suite.
"""

import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path

from jinja2 import Environment, StrictUndefined
from tokenizers import Tokenizer


SYSTEM = "Follow the user's output format exactly. Do not include an explanation unless requested."


def reject(message):
    raise ValueError(message)


def authored_cases():
    return [
        ("inventory-arithmetic", "A warehouse receives 36 boxes with 48 bolts each. It discards 125 damaged bolts, then ships 217 bolts to each of three customers. How many bolts remain? Return only the integer.", "952", 96),
        ("ordering-constraints", "Four jobs are amber, birch, cobalt, and dahlia. Dahlia is last. Birch is immediately after amber. Cobalt is after birch. List the unique order using lowercase names separated by commas with no spaces.", "amber,birch,cobalt,dahlia", 96),
        ("set-state", "Start with an empty set. Apply these operations in order: add 8; add 3; add 8; remove 3; add 11; add 3; remove 8; add 2; remove 11; add 7. Return the final set as an ascending JSON array without spaces.", "[2,3,7]", 96),
        ("code-trace", "What is printed by this Python code? Return only the printed list, using Python's usual comma-space formatting.\nvalues = [3, 1, 4, 1, 5]\nresult = []\ns = 0\nfor i, x in enumerate(values):\n    s += x if i % 2 == 0 else -x\n    result.append(s)\nprint(result)", "[3, 2, 6, 5, 10]", 96),
        ("scope-negation", "Policy: archive every record that is closed and not starred. Records: A is closed and starred; B is open and unstarred; C is closed and unstarred; D is open and starred; E is closed and unstarred. Which records are archived? Return only their uppercase IDs sorted alphabetically, separated by a comma with no spaces.", "C,E", 96),
        ("write-python", "Write a Python function stable_unique(values) returning a list with duplicate hashable items removed while preserving first occurrence order. Do not mutate the input. Return only Python source without Markdown. Include no example calls.", None, 160),
    ]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model-directory", type=Path, required=True)
    parser.add_argument("--model-id", required=True)
    parser.add_argument("--aggregate", required=True)
    parser.add_argument("--output-directory", type=Path, required=True)
    parser.add_argument("--max-tokens", type=int, help="Override generation budgets for models that emit reasoning")
    args = parser.parse_args()
    if args.max_tokens is not None and not 1 <= args.max_tokens <= 512:
        parser.error("--max-tokens must be within the native harness limit of 1..512")
    tokenizer_path = args.model_directory / "tokenizer.json"
    tokenizer = Tokenizer.from_file(str(tokenizer_path))
    template_path = args.model_directory / "chat_template.jinja"
    template = template_path.read_text()
    config = json.loads((args.model_directory / "tokenizer_config.json").read_text())
    environment = Environment(undefined=StrictUndefined)
    environment.globals["raise_exception"] = reject
    fixed_date = datetime(2026, 9, 7, tzinfo=timezone.utc)
    environment.globals["strftime_now"] = lambda fmt: fixed_date.strftime(fmt)
    renderer = environment.from_string(template)
    settings = dict(tools=None, builtin_tools=[], add_generation_prompt=True,
                    enable_thinking=False, reasoning_effort="low")
    for name in ("bos_token", "eos_token", "unk_token", "pad_token"):
        value = config.get(name) or ""
        settings[name] = value.get("content", "") if isinstance(value, dict) else value

    def render(prompt):
        text = renderer.render(messages=[{"role": "system", "content": SYSTEM, "tool_calls": []},
                                         {"role": "user", "content": prompt, "tool_calls": []}], **settings)
        return text, tokenizer.encode(text, add_special_tokens=False).ids

    cases = authored_cases()
    for target, fraction, suffix in [(4096, 0.1, "early"), (16384, 0.5, "middle")]:
        lines = []
        # Fixed, nonrandom distractors make both the task and its answer auditable.
        for i in range(2000):
            lines.append(f"Record R{i:04d}: depot=harbor-{i % 31}; parcel={100000 + i * 137}; status=stored.\n")
            if len(tokenizer.encode("".join(lines), add_special_tokens=False).ids) >= target:
                break
        lines.insert(int(len(lines) * fraction), "Record TARGET-ORCHID: depot=cedar; parcel=742915; status=reserved.\n")
        prompt = "Read this registry. Only the record named TARGET-ORCHID is relevant.\n" + "".join(lines)
        prompt += "\nWhat parcel number belongs to TARGET-ORCHID? Return only the six digits."
        cases.append((f"retrieve-{target}-{suffix}", prompt, "742915", 96))

    lines = [f"Revision {i}: unrelated key plum-{i} has value {1000 + i * 7}.\n" for i in range(230)]
    lines.insert(12, "Revision 12A: key quartz has value 1842.\n")
    lines.insert(148, "Revision 148A: key quartz has value 9073.\n")
    lines.insert(205, "Revision 205A: key quartz has value 6218.\n")
    prompt = "This is an ordered journal; each later assignment replaces the earlier value for the same key.\n"
    prompt += "".join(lines) + "\nWhat is the final value of quartz? Return only the four digits."
    cases.append(("retrieve-updated-value", prompt, "6218", 96))

    args.output_directory.mkdir(parents=True, exist_ok=True)
    encoded = []
    descriptions = []
    for name, prompt, expected, max_tokens in cases:
        max_tokens = args.max_tokens or max_tokens
        rendered, tokens = render(prompt)
        if not 1 <= len(tokens) <= 32768:
            raise ValueError(f"{name}: rendered token count outside native harness bounds")
        record = {"name": name, "promptTokens": tokens, "maxTokens": max_tokens}
        if expected is not None:
            record["expectedText"] = expected
        encoded.append(record)
        (args.output_directory / f"{name}.txt").write_text(rendered)
        descriptions.append({"name": name, "prompt_tokens": len(tokens), "expected_text": expected,
                             "max_tokens": max_tokens, "rendered_sha256": hashlib.sha256(rendered.encode()).hexdigest()})

    for concurrency in (1, 4):
        payload = {"modelID": args.model_id, "expectedModelAggregateSHA256": args.aggregate,
                   "concurrency": concurrency, "cases": encoded}
        (args.output_directory / f"quality-c{concurrency}.json").write_text(json.dumps(payload) + "\n")
    metadata = {"scope": "authored regression probes; not broad model quality qualification",
                "model_id": args.model_id, "aggregate": args.aggregate,
                "template_sha256": hashlib.sha256(template.encode()).hexdigest(),
                "tokenizer_sha256": hashlib.sha256(tokenizer_path.read_bytes()).hexdigest(),
                "render_settings": settings, "fixed_template_date": "2026-09-07", "cases": descriptions}
    (args.output_directory / "quality.meta.json").write_text(json.dumps(metadata, indent=2) + "\n")
    print(json.dumps({"model": args.model_id, "cases": descriptions}, indent=2))


if __name__ == "__main__":
    main()
