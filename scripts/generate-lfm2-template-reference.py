#!/usr/bin/env python3
"""Render local-only LFM2.5 reference prompts with Transformers (dev only).

Reads the committed request bodies, mirrors the provider's template-input
normalization, renders the pinned snapshot's chat_template.jinja with
`apply_chat_template`, and tokenizes with its tokenizer.json. Writes
`<case>.txt` and `<case>.ids.json` into the output directory for
LFM2TemplateParityLiveTests (LFM2_TEMPLATE_REFERENCE_DIR). The template and the
rendered prompts stay local: they are not redistributed with the repository.

Provider normalization mirrored here:
- OpenAIChatMessage.templateMessageDict(): role, text content ("" for null),
  name, tool_call_id, tool_calls[{id,type,function{name,arguments}}],
  reasoning_content; arguments decode to an object when the JSON string is an
  object (decodeToolCallArguments), otherwise stay the raw string.
- sanitizeForJinja drops JSON nulls; OpenAITool.toolSpec() keeps
  name/description/parameters and ChatTemplateFixes drops `strict`.
- The Jinja bridge orders dictionary keys and reads integral numbers as Int.
- preserve_thinking comes only from the top-level body field.
"""
import argparse
import hashlib
import json
from pathlib import Path
import transformers

TEMPLATE_SHA256 = "aadd425edb1d42fe9288e5de3624c21c1c03099129b9cfea5978f1bc67222c0a"
TOKENIZER_SHA256 = "695be7802a0e4b8a81048f0ff5ebb7fc811a0ba5a6be63dbb24deb5a81096f41"

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("model_directory", type=Path)
parser.add_argument("output_directory", type=Path)
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
fixture = root / "provider-swift/Tests/ProviderCoreTests/Fixtures/lfm2-template-request-bodies.json"
template = (args.model_directory / "chat_template.jinja").read_bytes()
assert hashlib.sha256(template).hexdigest() == TEMPLATE_SHA256
tokenizer_bytes = (args.model_directory / "tokenizer.json").read_bytes()
assert hashlib.sha256(tokenizer_bytes).hexdigest() == TOKENIZER_SHA256
tokenizer = transformers.AutoTokenizer.from_pretrained(args.model_directory, local_files_only=True)


def typed(value):
    if value is None:
        return None
    if isinstance(value, float) and value.is_integer() and -(2**63) <= value < 2**63:
        return int(value)
    if isinstance(value, list):
        return [typed(item) for item in value if item is not None]
    if isinstance(value, dict):
        return {key: typed(value[key]) for key in sorted(value) if value[key] is not None}
    return value


def decode_arguments(raw):
    try:
        decoded = json.loads(raw)
    except ValueError:
        return raw
    return decoded if isinstance(decoded, dict) else raw


def message_view(message):
    content = message.get("content")
    if isinstance(content, list):
        content = "".join(part.get("text", "") for part in content if part.get("type") == "text")
    view = {"role": message["role"], "content": content if isinstance(content, str) else ""}
    for key in ("name", "tool_call_id", "reasoning_content"):
        if message.get(key) is not None:
            view[key] = message[key]
    if message.get("tool_calls"):
        view["tool_calls"] = [{
            "id": call["id"],
            "type": call.get("type", "function"),
            "function": {
                "name": call["function"]["name"],
                "arguments": decode_arguments(call["function"]["arguments"]),
            },
        } for call in message["tool_calls"]]
    return view


def tool_view(tool):
    function = tool["function"]
    spec = {key: function[key] for key in ("name", "description", "parameters") if key in function}
    return {"type": tool.get("type", "function"), "function": spec}


args.output_directory.mkdir(parents=True, exist_ok=True)
summary = {}
for name, body in json.loads(fixture.read_text()).items():
    messages = typed([message_view(message) for message in body["messages"]])
    tools = typed([tool_view(tool) for tool in body["tools"]]) if body.get("tools") else None
    extra = {"preserve_thinking": body["preserve_thinking"]} if "preserve_thinking" in body else {}
    prompt = tokenizer.apply_chat_template(
        messages, tools=tools, chat_template=template.decode(), add_generation_prompt=True,
        tokenize=False, **extra)
    token_ids = tokenizer.encode(prompt, add_special_tokens=False)
    (args.output_directory / f"{name}.txt").write_text(prompt)
    (args.output_directory / f"{name}.ids.json").write_text(json.dumps(token_ids))
    summary[name] = {"tokens": len(token_ids), "bos": token_ids.count(tokenizer.bos_token_id)}
print(json.dumps({"transformers": transformers.__version__, "cases": summary}, indent=1))
