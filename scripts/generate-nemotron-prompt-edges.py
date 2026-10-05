#!/usr/bin/env python3
"""Regenerate local-only reference prompts with Transformers and the pinned tokenizer."""
import argparse
import copy
import hashlib
import json
import platform
from pathlib import Path
import transformers

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("model_directory", type=Path)
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
fixtures = root / "provider-swift/Tests/ProviderCoreTests/Fixtures"
original = json.loads((fixtures / "nemotron-reference-corpus.json").read_text())
template = (args.model_directory / "chat_template.jinja").read_bytes()
assert hashlib.sha256(template).hexdigest() == original["generator"]["template_sha256"]
tokenizer = transformers.AutoTokenizer.from_pretrained(args.model_directory, local_files_only=True)


def typed(value):
    # OpenAI JSONValue tries Int before Double; the Jinja bridge sorts keys.
    if isinstance(value, float) and value.is_integer() and -(2**63) <= value < 2**63:
        return int(value)
    if isinstance(value, list):
        return [typed(item) for item in value]
    if isinstance(value, dict):
        return {key: typed(value[key]) for key in sorted(value)}
    return value


cases = []
for name, schema in [
    ("numeric-enum", {"type": "number", "enum": [1e-7, 1e-6, 0.125]}),
    ("numeric-minimum", {"type": "number", "minimum": 1e-7}),
    ("numeric-default", {"type": "number", "default": 1e-6}),
    ("integral-enum", {"type": "number", "enum": [1.0, 2.0]}),
    ("negative-numbers", {"type": "number", "enum": [-1e-7, -0.125, -1.0]}),
    ("nested-numerics", {"type": "object", "properties": {"limit": {"type": "number", "default": 1e-7}}}),
    ("number-boundaries", {"type": "number", "enum": [5e-324, 0.0001, 0.00001, 1e15]}),
]:
    body = copy.deepcopy(original["cases"][0]["body"])
    body["tools"][0]["function"]["parameters"]["properties"]["unit"] = schema
    normalized = typed(body)
    prompt = tokenizer.apply_chat_template(normalized["messages"], tools=normalized["tools"],
        enable_thinking=False, add_generation_prompt=True, tokenize=False)
    token_ids = tokenizer.encode(prompt, add_special_tokens=False)
    cases.append({"name": name, "body": body, "prompt": prompt, "token_ids": token_ids})
print(json.dumps({"schema_version": 1, "generator": {
    "transformers": transformers.__version__, "python": platform.python_version(),
    "template_sha256": hashlib.sha256(template).hexdigest(),
    "normalization": "SDK Int-before-Double tool values and sorted object keys before reference rendering"
}, "cases": cases}, indent=2, ensure_ascii=False))
