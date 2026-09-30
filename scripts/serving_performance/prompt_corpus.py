"""Deterministic synthetic prompt corpus for exact rendered-count validation.

This is a declared workload distribution, not a claim about arbitrary traffic.
Partition-specific seeds vary all content, schemas, and history. Text stays in
temporary inputs; exported observations retain numeric shapes and hashes only.
"""
import base64
import hashlib
import json
import random

FAMILIES = ("prose", "code", "json", "multilingual", "identifiers", "markdown")
WORDS = ("amber", "river", "matrix", "copper", "forest", "window", "signal", "orbit",
         "harbor", "thread", "integer", "velocity", "season", "quiet", "violet", "packet",
         "sample", "stable", "kernel", "branch", "cursor", "memory", "review", "balance")


def text_block(rng, family):
    words = [rng.choice(WORDS) for _ in range(12)]
    values = [rng.randrange(100_000_000) for _ in range(4)]
    if family == "code":
        return f"def {words[0]}_{values[0]}({words[1]}):\n    return {words[1]} * {values[1]} + {values[2]}\n"
    if family == "json":
        return json.dumps(dict(zip(words[:4], values)), separators=(",", ":")) + "\n"
    if family == "multilingual":
        return f"資料{values[0]}。この文章を検証してください。مرحبا بالعالم. Здравствуйте. café {words[0]} 🌿\n"
    if family == "identifiers":
        return " ".join(hashlib.sha256(f"{word}-{value}".encode()).hexdigest() for word, value in zip(words, values)) + "\n"
    if family == "markdown":
        return f"### {words[0]} {values[0]}\n| {words[1]} | {words[2]} |\n| --- | --- |\n| {values[1]} | {values[2]} |\n"
    return " ".join(words) + f". Evaluate example {values[0]} and explain the outcome.\n"


def request(rng, model_id, family, tools, target_bytes):
    blocks, size = [], 0
    while size < target_bytes:
        block = text_block(rng, family).encode()
        blocks.append(block)
        size += len(block)
    # Truncate only synthetic text, on a valid UTF-8 boundary. The real provider
    # then renders the entire request without any token/template truncation.
    content = b"".join(blocks)[:target_bytes].decode("utf-8", errors="ignore")
    body = {"model": model_id, "messages": [
        {"role": "system", "content": f"Review task {rng.randrange(1 << 40)} carefully."},
        {"role": "user", "content": content}], "max_tokens": 128, "temperature": 0,
        "reasoning": {"enabled": False}}
    if tools:
        schema_count = rng.randrange(1, 9)
        properties = {f"field_{index}": {"type": "string", "description": text_block(rng, "prose")}
                      for index in range(schema_count)}
        body["tools"] = [{"type": "function", "function": {
            "name": "lookup_reference", "description": text_block(rng, "prose"),
            "parameters": {"type": "object", "properties": properties,
                           "required": list(properties)[:rng.randrange(1, schema_count + 1)]}}}]
        body["tool_choice"] = "auto"
        call_id = f"call_{rng.randrange(1 << 40)}"
        body["messages"].extend([
            {"role": "assistant", "content": None, "tool_calls": [{"id": call_id, "type": "function",
                "function": {"name": "lookup_reference", "arguments": json.dumps({"field_0": rng.choice(WORDS)})}}]},
            {"role": "tool", "tool_call_id": call_id,
             "content": json.dumps({"reference": text_block(rng, family), "value": rng.randrange(1000)})},
            {"role": "user", "content": "Continue using the retrieved reference."}])
    else:
        body["messages"].extend([
            {"role": "assistant", "content": text_block(rng, family)},
            {"role": "user", "content": "Explain the reasoning and check the result."}])
    return body


def generate(model_id, calibration_count=24, validation_count=60, seed=20260928):
    result = []
    for partition, count in (("calibration", calibration_count), ("validation", validation_count)):
        for tools in (False, True):
            for band, center in enumerate((4096, 16384, 32768)):
                for index in range(count):
                    identity = f"{partition}-tools{int(tools)}-band{band}-{index}"
                    rng = random.Random(f"{seed}-{identity}")
                    family = FAMILIES[index % len(FAMILIES)]
                    # Four-byte heuristic centers are varied within the band.
                    size = max(128, int(center * 4 * rng.uniform(.8, 1.0)))
                    body = request(rng, model_id, family, tools, size)
                    encoded = json.dumps(body, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()
                    result.append({"id": identity, "partition": partition, "family": family,
                                   "request": base64.b64encode(encoded).decode()})
    return result
