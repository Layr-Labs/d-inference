#!/usr/bin/env python3
"""Build reproducible chat-template token contexts for the native scoring CLI.

These authored probes are smoke/diagnostic data, not a general quality benchmark.
Tokenization and the rendered template are retained beside each input.
"""

import argparse
import hashlib
import json
from pathlib import Path

from jinja2 import Environment, StrictUndefined
from tokenizers import Tokenizer


PASSAGE = (
    "A cache stores previously computed results so later work can reuse them. "
    "Its usefulness depends on both the cost of recomputing a result and how often that result is reused. "
    "A smaller representation can hold more entries, but reconstructing an entry also takes time. "
    "An experiment should therefore measure memory, latency, and completed work separately. "
    "The inputs must remain identical between the reference and candidate runs. "
    "Each run should record the exact model, software version, and hardware used. "
    "If a result cannot be reproduced, the discrepancy should be investigated rather than discarded. "
    "A successful unit test establishes the behavior it exercises; broader conclusions need broader evidence."
)


def reject(message):
    raise ValueError(message)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model-directory", type=Path, required=True)
    parser.add_argument("--model-id", required=True)
    parser.add_argument("--aggregate", required=True)
    parser.add_argument("--output-directory", type=Path, required=True)
    parser.add_argument("--lengths", default="512,4096,16384")
    args = parser.parse_args()
    tokenizer_path = args.model_directory / "tokenizer.json"
    tokenizer = Tokenizer.from_file(str(tokenizer_path))
    template_path = args.model_directory / "chat_template.jinja"
    template = template_path.read_text()
    environment = Environment(undefined=StrictUndefined)
    environment.globals["raise_exception"] = reject
    renderer = environment.from_string(template)
    continuation = tokenizer.encode(PASSAGE, add_special_tokens=False).ids
    if not 1 <= len(continuation) <= 256:
        raise ValueError("Continuation exceeds native diagnostic bounds")
    args.output_directory.mkdir(parents=True, exist_ok=True)
    for desired in map(int, args.lengths.split(",")):
        if not 1 <= desired <= 32768:
            raise ValueError("Requested context exceeds diagnostic bounds")
        prefix = ""
        rendered = ""
        # Keep whole sentences and the complete template rather than slicing
        # through special tokens to hit an artificial exact prompt length.
        for index in range(10000):
            messages = [{"role": "system", "content": "Follow the user's instructions carefully."},
                        {"role": "user", "content": prefix + "\nCopy the following passage exactly:\n" + PASSAGE}]
            rendered = renderer.render(messages=messages, tools=None,
                                       add_generation_prompt=True, enable_thinking=False)
            tokens = tokenizer.encode(rendered, add_special_tokens=False).ids
            if len(tokens) >= desired:
                break
            prefix += f"Reference note {index}: {PASSAGE}\n"
        if len(tokens) > 32768:
            raise ValueError("Rendered context exceeds diagnostic bounds")
        stem = args.output_directory / f"copy-{desired}"
        payload = {"modelID": args.model_id, "expectedModelAggregateSHA256": args.aggregate,
                   "promptTokens": tokens, "continuation": continuation}
        stem.with_suffix(".json").write_text(json.dumps(payload) + "\n")
        stem.with_suffix(".txt").write_text(rendered)
        metadata = {"scope": "authored copy diagnostic; not general quality qualification",
                    "requested_minimum_tokens": desired, "actual_prompt_tokens": len(tokens),
                    "continuation_tokens": len(continuation),
                    "template_sha256": hashlib.sha256(template.encode()).hexdigest(),
                    "tokenizer_sha256": hashlib.sha256(tokenizer_path.read_bytes()).hexdigest(),
                    "continuation": PASSAGE}
        stem.with_suffix(".meta.json").write_text(json.dumps(metadata, indent=2) + "\n")
        print(f"{stem.name}: {len(tokens)} prompt + {len(continuation)} forced tokens")


if __name__ == "__main__":
    main()
