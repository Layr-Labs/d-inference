"""Golden prompt corpus for the pinned Nemotron 3.5 Super VL chat template.

The reference is Transformers' ``apply_chat_template`` over the pinned
``chat_template.jinja`` (an ImmutableSandboxedEnvironment with trim/lstrip
blocks, ``loopcontrols`` and Transformers' ``tojson``), followed by
``processing_nemotron_h_omni.py`` image placeholder expansion and the pinned
``tokenizer.json`` through the ``tokenizers`` library. Assistant tool-call
arguments are decoded from JSON strings exactly as vLLM does before rendering.

Reference files are read as data and never imported or executed. The image
token count is a line-for-line port of ``_compute_target_patches`` and the
image-path budget in ``image_processing_nemotron_h_omni.py``; the pinned
SHA-256 of that file is checked before use.

Run with the isolated interpreter of a virtual environment that contains only
the pinned requirements (see README.md in this directory):

    venv/bin/python -I scripts/nemotron-qualification/prompt_golden.py \
        --model-dir /path/to/reference --output <fixture.json>
    venv/bin/python -I scripts/nemotron-qualification/prompt_golden.py \
        --model-dir /path/to/reference --check <fixture.json>
"""
import argparse
import copy
import hashlib
import json
import math
from importlib import metadata
from pathlib import Path
import platform
import sys

import jinja2
import jinja2.ext
from jinja2.sandbox import ImmutableSandboxedEnvironment
from tokenizers import Tokenizer

MODEL = "nvidia/NVIDIA-Nemotron-3.5-Super-VL-120B-A12B-NVFP4"
REVISION = "7d4bc747b6bdc2cff64c58d65da0d08dd9caa25c"
PINNED = {
    "chat_template.jinja": "1369e90b19976f99ce2070eb21ade8fcb4af640f008e14e82af5c5e89a9cc816",
    "tokenizer.json": "d0432ad8b1c2984a2e2dca82e1933e3fd5628df6e95c51fba4c3ee9950dce299",
    "tokenizer_config.json": "89fa70d31734c0c75ffdcee4114449f8cf8abd64bc233d420b58e25763f91aba",
    "processing_nemotron_h_omni.py": "406bc7689161d19e2a01e34f0ac8a7cc1bbc927f664d03bae3d23d00ea27f11a",
    "image_processing_nemotron_h_omni.py": "0344e8432097e0718672d6529c68fd6095c36bea176500f131d203d1c7d497e0",
    "preprocessor_config.json": "0b80e5c895052ff2d8e528eca719a6b6e39b7b1b60afb0b94553ffae948e22bc",
}
REQUIREMENTS = {"jinja2": "3.1.6", "markupsafe": "3.0.3", "tokenizers": "0.22.2"}
IMAGE, IMAGE_START, IMAGE_END = "<image>", "<img>", "</img>"
# Opaque URL; the template never fetches or decodes it.
PNG = "data:image/png;base64,iVBORw0KGgo="

WEATHER = {"type": "function", "function": {
    "name": "get_weather",
    "description": "Get the current weather for a city.  ",
    "parameters": {
        "type": "object",
        # Deliberately not alphabetical: the template preserves request order.
        "properties": {
            "unit": {"type": "string", "enum": ["celsius", "fahrenheit"],
                     "description": "Temperature unit"},
            "city": {"type": "string", "description": "City name, e.g. Zürich"},
        },
        "required": ["city"],
    },
}}
SEARCH = {"type": "function", "function": {
    "name": "search_docs",
    "description": "Search internal documents.",
    "parameters": {
        "type": "object",
        "properties": {
            "query": {"type": "string", "minLength": 1},
            "limit": {"type": "integer", "minimum": 1, "maximum": 50, "default": 10},
            "threshold": {"type": ["number", "null"], "default": 0.25, "maximum": 1.0},
            "filters": {"type": "object",
                        "properties": {"tag": {"type": "string"},
                                       "after": {"type": "string", "format": "date"}},
                        "additionalProperties": False},
            "exact": {"type": "boolean", "default": False},
            "tags": {"type": "array", "items": {"type": "string"}},
        },
        "required": ["query", "limit"],
        "additionalProperties": False,
    },
    "strict": True,
}}
NO_DESCRIPTION = {"type": "function", "function": {
    "name": "ping", "parameters": {"type": "object", "properties": {}}}}


def user(content):
    return {"role": "user", "content": content}


def image_part():
    return {"type": "image_url", "image_url": {"url": PNG}}


def text_part(text):
    return {"type": "text", "text": text}


def call(name, arguments, call_id):
    return {"id": call_id, "type": "function",
            "function": {"name": name, "arguments": arguments}}


def case(name, category, messages, kwargs=None, tools=None, images=(), generation=True):
    body = {"model": MODEL, "messages": messages}
    if tools is not None:
        body["tools"] = tools
    if kwargs is not None:
        body["chat_template_kwargs"] = kwargs
    return {"name": name, "category": category, "body": body,
            "add_generation_prompt": generation, "images": list(images)}


def cases():
    tool_history = [
        user("What's the weather in Paris and Zürich?"),
        {"role": "assistant", "content": None, "reasoning_content": "Two cities; call twice.",
         "tool_calls": [
             call("get_weather", '{"city": "Paris", "unit": "celsius"}', "call_1"),
             call("get_weather", '{"unit": "celsius", "city": "Zürich"}', "call_2")]},
        {"role": "tool", "tool_call_id": "call_1", "content": '{"temp": 18.5, "sky": "clear"}'},
        {"role": "tool", "tool_call_id": "call_2", "content": '{"temp": 14, "sky": "rain"}'},
    ]
    nested_arguments = json.dumps({
        "query": "line one\nline \"two\"", "limit": 5, "threshold": 0.5, "exact": True,
        "filters": {"tag": "ops", "after": "2026-01-01"}, "tags": ["a", "b"], "missing": None,
    }, ensure_ascii=False)
    return [
        case("text-default-thinking", "text", [user("Hello!")]),
        case("text-thinking-on", "text", [user("Hello!")], {"enable_thinking": True}),
        case("text-thinking-off", "text", [user("Hello!")], {"enable_thinking": False}),
        case("system-default", "text", [
            {"role": "system", "content": "You are a concise assistant."},
            user("Summarize Mamba in one sentence.")]),
        case("system-thinking-off", "text", [
            {"role": "system", "content": "You are a concise assistant."},
            user("Summarize Mamba in one sentence.")], {"enable_thinking": False}),
        case("system-parts", "text", [
            {"role": "system", "content": [text_part("Rule one."), text_part(" Rule two.")]},
            user([text_part("Part A"), text_part("Part B")])]),
        case("multi-turn", "text", [
            user("Pick a number."), {"role": "assistant", "content": "Seven."},
            user("Double it.")]),
        case("multi-turn-reasoning-truncated", "text", [
            user("2+2?"),
            {"role": "assistant", "content": "4", "reasoning_content": "Add two and two."},
            user("And 3+3?")]),
        case("multi-turn-reasoning-kept", "text", [
            user("2+2?"),
            {"role": "assistant", "content": "4", "reasoning_content": "Add two and two."},
            user("And 3+3?")], {"truncate_history_thinking": False}),
        case("multi-turn-inline-think", "text", [
            user("Hi"), {"role": "assistant", "content": "<think>\ngreet</think>Hello there."},
            user("Bye"), {"role": "assistant", "content": "Goodbye."}], generation=False),
        case("final-assistant-reasoning", "text", [
            user("Hi"), {"role": "assistant", "content": "Hello.", "reasoning_content": "Be brief."}],
            generation=False),
        case("medium-effort", "text", [
            {"role": "system", "content": "Be careful."}, user("Prove 1+1=2.")],
            {"enable_thinking": True, "medium_effort": True}),
        case("no-generation-prompt", "text", [user("Hello!")], {"enable_thinking": False},
             generation=False),
        case("empty-user", "text", [user("")]),
        case("tools-auto", "tools", [user("Weather in Paris?")], tools=[WEATHER]),
        case("tools-system-extra-keys", "tools", [
            {"role": "system", "content": "Use tools when needed."},
            user("Find the runbook.")], tools=[SEARCH, WEATHER, NO_DESCRIPTION]),
        case("tools-thinking-off", "tools", [user("Weather in Paris?")], {"enable_thinking": False},
             tools=[WEATHER]),
        case("tool-call-and-results", "tools", tool_history, tools=[WEATHER]),
        case("tool-call-history-truncated", "tools", tool_history + [
            {"role": "assistant", "content": "Paris is 18.5°C and clear; Zürich is 14°C with rain."},
            user("Thanks. Search the docs for umbrellas.")], tools=[SEARCH, WEATHER]),
        case("tool-call-content-and-nested-args", "tools", [
            user("Search for the incident."),
            {"role": "assistant", "content": "Searching now.",
             "tool_calls": [call("search_docs", nested_arguments, "call_9")]},
            {"role": "tool", "tool_call_id": "call_9", "content": "No results."}],
            {"truncate_history_thinking": False}, tools=[SEARCH]),
        case("image-single", "images", [user([image_part(), text_part("Describe this.")])],
             images=[(512, 512)]),
        case("image-text-order", "images", [
            user([text_part("Before."), image_part(), text_part("After.")])],
             {"enable_thinking": False}, images=[(1920, 1080)]),
        case("image-two", "images", [
            user([text_part("Compare:"), image_part(), image_part(), text_part("Which is wider?")])],
             images=[(4000, 3000), (2000, 100)]),
        case("image-tiny-upscaled", "images", [
            {"role": "system", "content": "Describe images."}, user([image_part()])],
             images=[(1, 1)]),
        case("image-history", "images", [
            user([image_part(), text_part("What is it?")]),
            {"role": "assistant", "content": "A square."},
            user([text_part("And this one?"), image_part()])], images=[(16, 16), (640, 480)]),
        case("edge-unicode-whitespace", "edge", [user(
            "Emoji 👩🏽‍💻 CJK 漢字 combining é́ RTL שלום\n\n\ttabs\r\nCRLF  trailing   nbsp")]),
        case("edge-literal-markers", "edge", [user(
            "Text with <think>x</think>, <tool_call>, <|im_end|> and </tool_response> literals.")]),
        # The template drops the image part when text already names <image>; the
        # processor then expands the literal tag. Text-only use has no image.
        case("edge-literal-image-tag", "edge", [user([image_part(), text_part("A <image> tag.")])],
             images=[(512, 512)]),
        case("edge-json-and-escapes", "edge", [user(
            'Quote "a" \\ backslash {"k": [1, 2.5, null]} </s> <s>')]),
        case("edge-whitespace-only", "edge", [user("   \n  "), {"role": "assistant", "content": "  "},
                                              user("\n")]),
    ]


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load_reference(directory):
    hashes = {}
    for name, expected in PINNED.items():
        actual = sha256(directory / name)
        if actual != expected:
            raise ValueError(f"{name} differs from revision {REVISION}: {actual}")
        hashes[name] = actual
    return hashes


def require_pinned_packages():
    for name, version in REQUIREMENTS.items():
        installed = metadata.version(name)
        if installed != version:
            raise RuntimeError(f"{name} {installed} installed; the corpus pins {version}")


def compile_template(source):
    """Mirror transformers.utils.chat_template_utils._compile_jinja_template."""
    def raise_exception(message):
        raise jinja2.exceptions.TemplateError(message)

    def tojson(value, ensure_ascii=False, indent=None, separators=None, sort_keys=False):
        return json.dumps(value, ensure_ascii=ensure_ascii, indent=indent,
                          separators=separators, sort_keys=sort_keys)

    def strftime_now(_format):
        raise jinja2.exceptions.TemplateError("the pinned template must not read the clock")

    environment = ImmutableSandboxedEnvironment(
        trim_blocks=True, lstrip_blocks=True, extensions=[jinja2.ext.loopcontrols])
    environment.filters["tojson"] = tojson
    environment.globals["raise_exception"] = raise_exception
    environment.globals["strftime_now"] = strftime_now
    return environment.from_string(source)


def template_messages(messages):
    """vLLM's _postprocess_messages: tool-call arguments become mappings."""
    messages = copy.deepcopy(messages)
    for message in messages:
        if message.get("role") == "assistant" and isinstance(message.get("tool_calls"), list):
            for item in message["tool_calls"]:
                arguments = item["function"].get("arguments")
                if arguments:
                    if not isinstance(arguments, (dict, list)):
                        item["function"]["arguments"] = json.loads(arguments)
                else:
                    item["function"]["arguments"] = {}
    return messages


def target_patches(width, height, tokens_available, config):
    """Port of _compute_target_patches (image path) from the pinned processor."""
    patch = config["patch_size"]
    minimum = config["min_num_patches"]
    divisor = int(round(1.0 / config["downsample_ratio"]))
    closest_patch_h = round(height / patch + 0.5)
    closest_patch_w = round(width / patch + 0.5)
    patches = closest_patch_h * closest_patch_w
    factor = min(math.sqrt(tokens_available / patches), 1.0)
    target_h = math.floor(factor * closest_patch_h)
    target_w = math.floor(factor * closest_patch_w)
    if tokens_available > minimum and target_h * target_w < minimum:
        up = math.sqrt(minimum / (target_h * target_w))
        target_h = math.ceil(up * target_h)
        target_w = math.ceil(up * target_w)
    rem_h = target_h % divisor
    if rem_h:
        inc_h = divisor - rem_h
        if (target_h + inc_h) * target_w <= tokens_available:
            target_h += inc_h
        else:
            target_h = max(divisor, target_h - rem_h)
    rem_w = target_w % divisor
    if rem_w:
        inc_w = divisor - rem_w
        if target_h * (target_w + inc_w) <= tokens_available:
            target_w += inc_w
        else:
            target_w = max(divisor, target_w - rem_w)
    return target_w, target_h


def image_grids(sizes, config):
    """Image-path per-image budget from _preprocess, then the token count."""
    divisor = int(round(1.0 / config["downsample_ratio"]))
    budget = (config["max_model_len"] - 4) * divisor ** 2
    budget = max(budget, config["min_num_patches"] * len(sizes))
    maximum = config["max_num_patches"] if config["max_num_patches"] and config["max_num_patches"] > 0 \
        else float("inf")
    available = max(min(budget, maximum), config["min_num_patches"])
    grids = []
    for width, height in sizes:
        wp, hp = target_patches(width, height, available, config)
        grids.append({"width": width, "height": height, "width_patches": wp,
                      "height_patches": hp, "tokens": (wp * hp) // divisor ** 2})
    return grids


def expand_images(text, counts):
    """processing_nemotron_h_omni.py: one <img>…</img> span per <image>."""
    index = 0
    while IMAGE in text:
        if index >= len(counts):
            raise ValueError("more <image> placeholders than images")
        text = text.replace(IMAGE, IMAGE_START + "<|placeholder|>" * counts[index] + IMAGE_END, 1)
        index += 1
    if index != len(counts):
        raise ValueError("fewer <image> placeholders than images")
    return text.replace("<|placeholder|>", IMAGE)


def render_case(spec, template, tokenizer, special, image_config, image_ids):
    body = spec["body"]
    kwargs = dict(body.get("chat_template_kwargs") or {})
    prompt = template.render(
        messages=template_messages(body["messages"]), tools=body.get("tools"), documents=None,
        add_generation_prompt=spec["add_generation_prompt"], **special, **kwargs)
    encoded = tokenizer.encode(prompt, add_special_tokens=False).ids
    if tokenizer.encode(prompt, add_special_tokens=True).ids != encoded:
        raise ValueError("tokenizer post-processor unexpectedly adds special tokens")
    result = {key: spec[key] for key in ("name", "category", "body", "add_generation_prompt")}
    result.update({"template_kwargs": kwargs, "prompt": prompt, "token_ids": encoded})
    if spec["images"] or spec["category"] == "images":
        grids = image_grids(spec["images"], image_config)
        counts = [grid["tokens"] for grid in grids]
        expanded = tokenizer.encode(expand_images(prompt, counts), add_special_tokens=False).ids
        if expanded != splice_images(encoded, counts, image_ids):
            raise ValueError(f"{spec['name']}: text expansion is not a token splice")
        result["images"] = grids
        result["expanded_token_runs"] = runs(expanded)
    return result


def splice_images(ids, counts, image_ids):
    spliced, index = [], 0
    for token in ids:
        if token != image_ids[IMAGE]:
            spliced.append(token)
            continue
        spliced += [image_ids[IMAGE_START]] + [token] * counts[index] + [image_ids[IMAGE_END]]
        index += 1
    return spliced


def runs(ids):
    """Run-length form: a bare id, or [id, count] for count >= 2 repeats."""
    result = []
    for token in ids:
        if result and isinstance(result[-1], list) and result[-1][0] == token:
            result[-1][1] += 1
        elif result and result[-1] == token:
            result[-1] = [token, 2]
        else:
            result.append(token)
    return result


def build(directory):
    hashes = load_reference(directory)
    require_pinned_packages()
    template = compile_template((directory / "chat_template.jinja").read_text(encoding="utf-8"))
    tokenizer = Tokenizer.from_file(str(directory / "tokenizer.json"))
    config = json.loads((directory / "tokenizer_config.json").read_text(encoding="utf-8"))
    special = {key: config[key] for key in ("bos_token", "eos_token", "unk_token", "pad_token")}
    image_config = json.loads((directory / "preprocessor_config.json").read_text(encoding="utf-8"))
    ids = {token: tokenizer.token_to_id(token) for token in (IMAGE, IMAGE_START, IMAGE_END)}
    corpus = {
        "schema_version": 1,
        "model": MODEL,
        "reference": {"revision": REVISION, "sha256": hashes,
                      "image_token_ids": ids},
        "generator": {"script": "scripts/nemotron-qualification/prompt_golden.py",
                      "python": platform.python_version(), **REQUIREMENTS},
        "cases": [render_case(spec, template, tokenizer, special, image_config, ids)
                  for spec in cases()],
    }
    return corpus


def serialize(corpus):
    """Small diffs: one case per line, stable key order."""
    head = {key: value for key, value in corpus.items() if key != "cases"}
    lines = [json.dumps(case, ensure_ascii=False, separators=(",", ":")) for case in corpus["cases"]]
    header = json.dumps(head, ensure_ascii=False, indent=1)[:-2]
    return header + ',\n "cases": [\n' + ",\n".join(lines) + "\n ]\n}\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--model-dir", type=Path, required=True,
                        help="directory holding the pinned reference files")
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--output", type=Path, help="write a new corpus")
    group.add_argument("--check", type=Path, help="regenerate and compare with this corpus")
    arguments = parser.parse_args()
    text = serialize(build(arguments.model_dir))
    json.loads(text)
    if arguments.check:
        if arguments.check.read_text(encoding="utf-8") != text:
            print(f"{arguments.check} differs from the regenerated corpus", file=sys.stderr)
            return 1
        print(f"{arguments.check}: {text.count(chr(10) + '{')} cases match")
        return 0
    arguments.output.write_text(text, encoding="utf-8")
    print(f"wrote {arguments.output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
