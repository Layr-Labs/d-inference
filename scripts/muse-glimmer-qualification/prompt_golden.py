"""Golden prompt corpus for the Muse Glimmer 30B chat template the provider serves.

The reference is Transformers' ``apply_chat_template`` over the served
``chat_template.jinja`` (an ImmutableSandboxedEnvironment with trim/lstrip
blocks, ``loopcontrols`` and Transformers' ``tojson``), followed by the pinned
``tokenizer.json`` through the ``tokenizers`` library. Reference files are read
as data and never imported or executed.

The served template is the publisher's newer template with one change: its
date block, which tests ``strftime_now is defined``, is replaced by the direct
call ``strftime_now('%Y-%m-%d')`` that the provider's request-owned date binds.
``--published`` names the publisher's file; the script then checks that the
served file is exactly that derivation and that both render every case alike.

Each case is an OpenAI request body. The reference renders it after the
request normalization the provider applies, restated here so that a change to
either side fails the Swift test (``MuseGlimmerPromptGoldenTests``):

  * assistant tool-call arguments are decoded from their JSON string; text
    that is not a JSON object becomes an empty mapping (as vLLM renders it);
  * every mapping's keys are sorted, the order the provider's Jinja bridge
    gives a template (tool schemas and call arguments therefore render with
    sorted keys, whatever order the client sent);
  * ``reasoning_effort`` / ``reasoning.effort`` become the template's
    ``reasoning_strength`` (none, minimal, low -> low; medium -> medium;
    high -> high; xhigh, max -> xhigh); a thinking switch set to off selects
    low; with neither the template keeps its default (high);
  * a replayed assistant answer or reasoning loses protocol framing (a case
    that needs it carries the expected history as ``reference_messages``);
  * the date is the request's ``_darkbloom_prompt_date``.

Tool schemas in the corpus are ones the fleet's ingress schema normalization
leaves unchanged (every node has a string ``type``), so the corpus pins the
template, not that normalizer.

Run with the isolated interpreter of an environment holding the pinned
requirements (see README.md in this directory):

    python3 -I scripts/muse-glimmer-qualification/prompt_golden.py \
        --model-dir /path/to/nvidia-snapshot --output <fixture.json>
    python3 -I scripts/muse-glimmer-qualification/prompt_golden.py \
        --model-dir /path/to/nvidia-snapshot --check <fixture.json>
"""
import argparse
import copy
import hashlib
import json
import sys
from importlib import metadata
from pathlib import Path

import jinja2
import jinja2.ext
from jinja2.sandbox import ImmutableSandboxedEnvironment
from tokenizers import Tokenizer

MODEL = "muse-glimmer-30b"
TOKENIZER_REPOSITORY = "nvidia/Muse-Glimmer-30B-NVFP4"
TOKENIZER_REVISION = "47818374517751c48c55cde2621594926b1888b6"
TEMPLATE_REPOSITORY = "meta-models/Muse-Glimmer-30B"
TEMPLATE_REVISION = "cec94fcfd6512f2cfe708138c32533b346ea4f69"
PINNED = {
    "tokenizer.json": "c9dbee66967b58f31a7c27f723c3760da3526ccd0427578e8905b0abb0031c4d",
    "tokenizer_config.json": "ee60d284ed7857ba89155f437cc915951e16056453ca7ae2491c5ae87a395c39",
}
PUBLISHED_TEMPLATE_SHA256 = "cfc67e5f349f37690dfd31ed1f18bc4442a9dd32fe39a648f993cb4eb3cae678"
SERVED_TEMPLATE_SHA256 = "6e0a14fabecc8c547bd3cbb3937128f1a97f1c95a0c645ea228b457898f926a9"
REQUIREMENTS = {"jinja2": "3.1.6", "markupsafe": "3.0.3", "tokenizers": "0.22.2"}
DATE = "2026-11-13"
SPECIAL_TOKENS = {"bos_token": "<|begin_of_text|>", "eos_token": "<|end_of_text|>",
                  "pad_token": "<|end_of_text|>"}
EFFORTS = ["none", "minimal", "low", "medium", "high", "xhigh", "max"]
STRENGTHS = ["low", "medium", "high", "xhigh"]

# The publisher's date block, and the served template's replacement for it.
PUBLISHED_DATE_BLOCK = [
    "{%- if current_date is defined and current_date -%}",
    "{{- '\\nCurrent date: ' + current_date + '.' -}}",
    "{%- elif strftime_now is defined -%}",
    "{{- '\\nCurrent date: ' + strftime_now('%Y-%m-%d') + '.' -}}",
    "{%- endif -%}",
]
SERVED_DATE_LINE = "{{- '\\nCurrent date: ' + strftime_now('%Y-%m-%d') + '.' -}}"

WEATHER = {"type": "function", "function": {
    "name": "get_weather",
    "description": "Get the current weather for a city.",
    "parameters": {
        "type": "object",
        # Deliberately not alphabetical: the bridge sorts keys.
        "properties": {
            "unit": {"type": "string", "enum": ["celsius", "fahrenheit"],
                     "description": "Temperature unit"},
            "city": {"type": "string", "description": "City name, e.g. Zürich"},
        },
        "required": ["city"],
    },
}}
SEARCH = {"type": "function", "function": {
    "name": "docs_search",
    "description": "Search internal documents (see https://example.com/docs/a/b). 検索",
    "parameters": {
        "type": "object",
        "properties": {
            "query": {"type": "string", "minLength": 1},
            "limit": {"type": "integer", "minimum": 1, "maximum": 50, "default": 10},
            "threshold": {"type": "number", "default": 0.25, "maximum": 0.75},
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
}}
READ = {"type": "function", "function": {
    "name": "docs_read", "description": "Read one document.",
    "parameters": {"type": "object", "properties": {"path": {"type": "string"}},
                   "required": ["path"]}}}
PING = {"type": "function", "function": {
    "name": "ping", "description": "", "parameters": {"type": "object", "properties": {}}}}
BARE = {"type": "function", "function": {"name": "now"}}


def user(content):
    return {"role": "user", "content": content}


def system(content):
    return {"role": "system", "content": content}


def text_part(text):
    return {"type": "text", "text": text}


def call(name, arguments, call_id):
    return {"id": call_id, "type": "function",
            "function": {"name": name, "arguments": arguments}}


def case(name, category, messages, tools=None, controls=None, reference_messages=None):
    body = {"model": MODEL, "messages": messages, "_darkbloom_prompt_date": DATE}
    if tools is not None:
        body["tools"] = tools
    body.update(controls or {})
    entry = {"name": name, "category": category, "body": body}
    if reference_messages is not None:
        entry["reference_messages"] = reference_messages
    return entry


def cases():
    weather_history = [
        user("What's the weather in Paris and Zürich?"),
        {"role": "assistant", "content": None, "reasoning_content": "Two cities; call twice.",
         "tool_calls": [
             call("get_weather", '{"city": "Paris", "unit": "celsius"}', "call_1"),
             call("get_weather", '{"unit": "celsius", "city": "Zürich"}', "call_2")]},
        {"role": "tool", "tool_call_id": "call_1", "content": '{"temp": 18.5, "sky": "clear"}'},
        {"role": "tool", "tool_call_id": "call_2", "content": '{"temp": 14, "sky": "rain"}'},
    ]
    typed_arguments = json.dumps({
        "query": "line one\nline \"two\" end", "limit": 5, "threshold": 0.5, "exact": True,
        "strict": False, "missing": None,
        "filters": {"tag": "ops", "after": "2026-01-01"}, "tags": ["a", "b/c", "漢字"],
    }, ensure_ascii=False)
    framed = (" to=self<|message|>Pick seven.<|eom|><|start|>assistant to=user<|message|>"
              "Seven.<|eot|>")
    out = [
        case("text-default", "text", [user("Hello!")]),
        case("system", "text", [system("You are a concise assistant."), user("Hello!")]),
        case("system-parts", "text", [
            system([text_part("Rule one."), text_part(" Rule two.")]),
            user([text_part("Part A"), text_part("Part B")])]),
        case("multi-turn", "text", [user("Pick a number."),
                                    {"role": "assistant", "content": "Seven."},
                                    user("Double it.")]),
        case("multi-turn-reasoning", "text", [
            user("2+2?"),
            {"role": "assistant", "content": "4", "reasoning_content": "Add two and two."},
            user("And 3+3?")]),
        case("multi-turn-system", "text", [
            system("Answer in one word."), user("Capital of France?"),
            {"role": "assistant", "content": "Paris"}, user("Of Italy?")]),
        case("history-framing-stripped", "text", [
            user("Pick a number."), {"role": "assistant", "content": framed},
            user("Double it.")],
            reference_messages=[user("Pick a number."),
                                {"role": "assistant", "content": "Seven."},
                                user("Double it.")]),
    ]
    for effort in EFFORTS:
        out.append(case(f"effort-{effort}", "reasoning", [user("Hello!")],
                        controls={"reasoning_effort": effort}))
    out += [
        case("effort-nested-xhigh-system", "reasoning", [system("Be brief."), user("Hello!")],
             controls={"reasoning": {"effort": "xhigh"}}),
        case("effort-nested-wins", "reasoning", [user("Hello!")],
             controls={"reasoning_effort": "low", "reasoning": {"effort": "medium"}}),
        case("thinking-off-nested", "reasoning", [user("Hello!")],
             controls={"reasoning": {"enabled": False}}),
        case("thinking-off-flag", "reasoning", [user("Hello!")],
             controls={"enable_thinking": False}),
        case("thinking-off-wins-over-effort", "reasoning", [user("Hello!")],
             controls={"reasoning": {"enabled": False, "effort": "high"}}),
        case("thinking-on-keeps-default", "reasoning", [user("Hello!")],
             controls={"reasoning": {"enabled": True}}),
        case("system-names-effort", "reasoning",
             [system("You are helpful.\nReasoning effort: low."), user("Hello!")],
             controls={"reasoning_effort": "xhigh"}),
        case("tools-auto", "tools", [user("Weather in Paris?")], tools=[WEATHER]),
        case("tools-system", "tools", [system("Use tools when needed."),
                                       user("Find the runbook.")],
             tools=[SEARCH, READ, WEATHER, PING]),
        case("tools-effort", "tools", [user("Weather in Paris?")], tools=[WEATHER],
             controls={"reasoning_effort": "minimal"}),
        case("tools-without-description", "tools", [user("What time is it?")], tools=[BARE]),
        case("tool-call-and-results", "tools", weather_history, tools=[WEATHER]),
        case("tool-call-follow-up", "tools", weather_history + [
            {"role": "assistant",
             "content": "Paris is 18.5°C and clear; Zürich is 14°C with rain."},
            user("Thanks. Search the docs for umbrellas.")], tools=[SEARCH, WEATHER]),
        case("tool-call-typed-arguments", "tools", [
            user("Search for the incident."),
            {"role": "assistant", "content": "Searching now.",
             "tool_calls": [call("docs_search", typed_arguments, "call_9")]},
            {"role": "tool", "tool_call_id": "call_9", "content": "No results."}],
            tools=[SEARCH]),
        case("tool-call-empty-arguments", "tools", [
            user("Ping twice."),
            {"role": "assistant", "content": None,
             "tool_calls": [call("ping", "", "call_p"), call("ping", "{}", "call_q")]},
            {"role": "tool", "tool_call_id": "call_p", "name": "ping", "content": "pong"},
            {"role": "tool", "tool_call_id": "call_q", "name": "ping", "content": "pong"}],
            tools=[PING]),
        case("tool-call-damaged-arguments", "tools", [
            user("Read a.txt"),
            {"role": "assistant", "content": None,
             "tool_calls": [call("docs_read", '{"path": "a.t', "call_r")]},
            {"role": "tool", "tool_call_id": "call_r", "content": "alpha"}], tools=[READ]),
        case("tool-result-unmatched-id", "tools", [
            user("Read a.txt"),
            {"role": "assistant", "content": None,
             "tool_calls": [call("docs_read", '{"path": "a.txt"}', "call_r")]},
            {"role": "tool", "tool_call_id": "call_other", "content": "alpha"}], tools=[READ]),
        case("edge-unicode-whitespace", "edge", [user(
            "Emoji 👩🏽‍💻 CJK 漢字 combining é́ RTL שלום\n\n\ttabs\r\nCRLF  trailing   nbsp")]),
        case("edge-literal-markers", "edge", [user(
            "Text with <|eom|>, <|eot|>, <|start|>assistant to=self<|message|> and "
            "<atem:function_calls> literals.")]),
        case("edge-json-and-escapes", "edge", [user(
            'Quote "a" \\ backslash {"k": [1, 2.5, null]} {{ x }} {% y %}')]),
        case("edge-whitespace-only", "edge", [user("   \n  "),
                                              {"role": "assistant", "content": "  "},
                                              user("\n")]),
        case("edge-empty-user", "edge", [user("")]),
    ]
    return out


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def require_pinned_packages():
    for name, version in REQUIREMENTS.items():
        installed = metadata.version(name)
        if installed != version:
            raise RuntimeError(f"{name} {installed} installed; the corpus pins {version}")


def load_tokenizer(directory):
    hashes = {}
    for name, expected in PINNED.items():
        actual = sha256(directory / name)
        if actual != expected:
            raise ValueError(f"{name} differs from {TOKENIZER_REPOSITORY}@{TOKENIZER_REVISION}: {actual}")
        hashes[name] = actual
    return Tokenizer.from_file(str(directory / "tokenizer.json")), hashes


def served_from(published):
    """The served template derived from the publisher's: only the date block."""
    lines = published.split("\n")
    start = next(i for i, line in enumerate(lines) if line.strip() == PUBLISHED_DATE_BLOCK[0])
    block = [line.strip() for line in lines[start:start + len(PUBLISHED_DATE_BLOCK)]]
    if block != PUBLISHED_DATE_BLOCK:
        raise ValueError("the publisher's date block is not the pinned one")
    indent = lines[start][: len(lines[start]) - len(lines[start].lstrip())]
    return "\n".join(lines[:start] + [indent + SERVED_DATE_LINE]
                     + lines[start + len(PUBLISHED_DATE_BLOCK):])


def compile_template(source, date):
    """Mirror transformers.utils.chat_template_utils._compile_jinja_template."""
    def raise_exception(message):
        raise jinja2.exceptions.TemplateError(message)

    def tojson(value, ensure_ascii=False, indent=None, separators=None, sort_keys=False):
        return json.dumps(value, ensure_ascii=ensure_ascii, indent=indent,
                          separators=separators, sort_keys=sort_keys)

    def strftime_now(format):
        if format != "%Y-%m-%d":
            raise jinja2.exceptions.TemplateError("the template reads one date format")
        return date

    environment = ImmutableSandboxedEnvironment(
        trim_blocks=True, lstrip_blocks=True, extensions=[jinja2.ext.loopcontrols])
    environment.filters["tojson"] = tojson
    environment.globals["raise_exception"] = raise_exception
    environment.globals["strftime_now"] = strftime_now
    return environment.from_string(source)


def sort_keys(value):
    if isinstance(value, dict):
        return {key: sort_keys(value[key]) for key in sorted(value)}
    if isinstance(value, list):
        return [sort_keys(item) for item in value]
    return value


def template_messages(messages):
    """History as a reference server hands it to the template."""
    messages = copy.deepcopy(messages)
    for message in messages:
        content = message.get("content")
        if isinstance(content, list):
            # The provider's text route joins text parts, as the template does.
            message["content"] = "".join(part["text"] for part in content if part["type"] == "text")
        elif content is None:
            message["content"] = ""
        for item in message.get("tool_calls") or []:
            arguments = item["function"].get("arguments")
            if not isinstance(arguments, dict):
                try:
                    arguments = json.loads(arguments) if arguments and arguments.strip() else {}
                except json.JSONDecodeError:
                    arguments = {}
                item["function"]["arguments"] = arguments if isinstance(arguments, dict) else {}
    return messages


def template_tools(tools):
    if tools is None:
        return None
    tools = copy.deepcopy(tools)
    for tool in tools:
        # A reference server passes an absent description or schema as null.
        tool["function"].setdefault("description", None)
        tool["function"].setdefault("parameters", None)
    return tools


def reasoning_strength(body):
    """The provider's rule (MuseGlimmerRequestPolicy.templateContext)."""
    reasoning = body.get("reasoning") or {}
    enabled = reasoning["enabled"] if "enabled" in reasoning else body.get("enable_thinking")
    if enabled is False:
        return "low"
    effort = reasoning.get("effort", body.get("reasoning_effort"))
    if effort is None:
        return None
    name = effort.strip().lower()
    name = "none" if name in ("off", "0") else name
    rank = EFFORTS.index(name)
    return next((each for each in STRENGTHS if EFFORTS.index(each) >= rank), STRENGTHS[-1])


def render(source, entry):
    body = entry["body"]
    kwargs = dict(SPECIAL_TOKENS)
    strength = reasoning_strength(body)
    if strength is not None:
        kwargs["reasoning_strength"] = strength
    messages = template_messages(entry.get("reference_messages", body["messages"]))
    return compile_template(source, body["_darkbloom_prompt_date"]).render(
        messages=sort_keys(messages), tools=sort_keys(template_tools(body.get("tools"))),
        documents=None, add_generation_prompt=True, **kwargs)


def build(model_dir, template_path, published_path):
    require_pinned_packages()
    tokenizer, hashes = load_tokenizer(model_dir)
    source_bytes = template_path.read_bytes()
    served_hash = hashlib.sha256(source_bytes).hexdigest()
    if served_hash != SERVED_TEMPLATE_SHA256:
        raise ValueError(f"served template differs from the pinned one: {served_hash}")
    source = source_bytes.decode("utf-8")
    published = None
    if published_path is not None:
        published_bytes = published_path.read_bytes()
        if hashlib.sha256(published_bytes).hexdigest() != PUBLISHED_TEMPLATE_SHA256:
            raise ValueError("the publisher's template differs from the pinned one")
        published = published_bytes.decode("utf-8")
        if served_from(published) != source:
            raise ValueError("the served template is not the pinned derivation")
    corpus = []
    for entry in cases():
        prompt = render(source, entry)
        if published is not None and render(published, entry) != prompt:
            raise ValueError(f"{entry['name']}: served and published templates differ")
        entry = dict(entry)
        entry["reasoning_strength"] = reasoning_strength(entry["body"])
        entry["prompt"] = prompt
        entry["token_ids"] = tokenizer.encode(prompt, add_special_tokens=False).ids
        corpus.append(entry)
    names = [entry["name"] for entry in corpus]
    if len(set(names)) != len(names):
        raise ValueError("case names are not unique")
    return {
        "schema": "darkbloom-muse-glimmer-prompt-golden-v1",
        "reference": {
            "tokenizer": {"repository": TOKENIZER_REPOSITORY, "revision": TOKENIZER_REVISION},
            "published_template": {"repository": TEMPLATE_REPOSITORY, "revision": TEMPLATE_REVISION,
                                   "sha256": PUBLISHED_TEMPLATE_SHA256},
            "sha256": {**hashes, "chat_template.jinja": served_hash},
            "packages": {name: metadata.version(name) for name in REQUIREMENTS},
            "special_tokens": SPECIAL_TOKENS,
        },
        "cases": corpus,
    }


def dump(document):
    lines = ["{", f' "schema": {json.dumps(document["schema"])},',
             ' "reference": ' + json.dumps(document["reference"], ensure_ascii=False) + ",",
             ' "cases": [']
    lines.append(",\n".join("  " + json.dumps(entry, ensure_ascii=False)
                            for entry in document["cases"]))
    lines += [" ]", "}"]
    return "\n".join(lines) + "\n"


def main():
    here = Path(__file__).resolve().parent
    fixtures = here.parent.parent / "provider-swift/Tests/ProviderCoreTests/Fixtures/MuseGlimmer"
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--model-dir", type=Path, required=True,
                        help="directory holding the pinned tokenizer.json and tokenizer_config.json")
    parser.add_argument("--template", type=Path, default=fixtures / "chat_template.jinja")
    parser.add_argument("--published", type=Path,
                        help="the publisher's chat_template.jinja, to check the derivation")
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--output", type=Path)
    group.add_argument("--check", type=Path)
    arguments = parser.parse_args()
    text = dump(build(arguments.model_dir, arguments.template, arguments.published))
    if arguments.output is not None:
        arguments.output.write_text(text, encoding="utf-8")
        print(f"{arguments.output}: {text.count(chr(10)) - 6} cases")
        return 0
    if arguments.check.read_text(encoding="utf-8") != text:
        print(f"{arguments.check} is not what this script writes", file=sys.stderr)
        return 1
    print(f"{arguments.check}: current")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
