"""Live capability probes for Muse Glimmer 30B behind an OpenAI-compatible endpoint.

Sends the OpenRouter-style requests a listing is checked with and reports, for
each listed parameter, whether the endpoint honours it: penalties, stop
strings, seed, ``n``, streaming usage, finish reasons, logprobs and the error
shapes of rejected requests. It needs a live Muse Mac; it loads nothing
locally and sends only the requests below. Each probe is recorded as pass,
fail or skip, separately, with the evidence it saw.

Several parameters switch the request's drafter off (the target model then
decodes every token itself, so throughput falls, never output quality): see
``DRAFTER_OFF`` and the README in this directory. The probes measure no
speed.

The key is read from the environment variable ``--api-key-env`` names; it is
never printed or written to the report.

    python3 -I scripts/muse-glimmer-qualification/live_probe.py \
        --base-url http://127.0.0.1:<port>/v1 --model muse-glimmer-30b \
        [--api-key-env DARKBLOOM_API_KEY] [--report probe.json] [--only stop,seed]
"""
import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request

# Request fields that keep a whole Muse request target-only, as the engine
# decides it (`mtpHistoryEligible`, EngineLoopV2+MTPPlanning.swift in
# mlx-swift-lm). Temperature, top_p, top_k and seed keep the drafter: its
# DFlash drafter verifies sampled drafts by target-prefix acceptance.
DRAFTER_OFF = {
    "frequency_penalty / presence_penalty": "any value but 0",
    "repetition_penalty": "any value but 1",
    "stop": "any client stop string",
    "logprobs": "true (the engine then captures top logprobs)",
    "logit_bias": "any entry",
}
# No Muse request compiles a token constraint today: a forced or required tool
# choice is prompt-forced and validated after the call, and a JSON
# response_format is prompt-only. A future Muse JSON grammar would switch the
# drafter off unless grammar drafting is turned on for it.

WEATHER = {"type": "function", "function": {
    "name": "get_weather", "description": "Current weather for a city.",
    "parameters": {"type": "object", "properties": {"city": {"type": "string"}},
                   "required": ["city"]}}}


class Client:
    def __init__(self, base_url, model, key, timeout):
        self.base_url, self.model, self.key, self.timeout = base_url.rstrip("/"), model, key, timeout

    def post(self, body, stream=False):
        body = dict(body, model=self.model)
        if stream:
            body["stream"] = True
        request = urllib.request.Request(
            self.base_url + "/chat/completions", data=json.dumps(body).encode(), method="POST",
            headers={"Content-Type": "application/json",
                     **({"Authorization": "Bearer " + self.key} if self.key else {})})
        started = time.monotonic()
        try:
            with urllib.request.urlopen(request, timeout=self.timeout) as response:
                if not stream:
                    return response.status, json.loads(response.read()), time.monotonic() - started
                return response.status, self._events(response), time.monotonic() - started
        except urllib.error.HTTPError as error:
            raw = error.read()
            try:
                payload = json.loads(raw)
            except ValueError:
                payload = {"unparsed": raw[:400].decode(errors="replace")}
            return error.code, payload, time.monotonic() - started

    @staticmethod
    def _events(response):
        events = []
        for line in response:
            line = line.decode().strip()
            if not line.startswith("data:"):
                continue
            data = line[5:].strip()
            if data == "[DONE]":
                break
            events.append(json.loads(data))
        return events


def user(text):
    return [{"role": "user", "content": text}]


def choice(payload, index=0):
    choices = payload.get("choices") or []
    return choices[index] if len(choices) > index else {}


def content(payload, index=0):
    return (choice(payload, index).get("message") or {}).get("content") or ""


def result(status, evidence, **extra):
    return dict(status=status, evidence=evidence, **extra)


def error_shape(payload):
    """OpenAI's error object: {"error": {"message": str, "type": str, ...}}."""
    error = payload.get("error") if isinstance(payload, dict) else None
    return isinstance(error, dict) and isinstance(error.get("message"), str) and "type" in error


def probe_penalties(client):
    rows = {}
    for field, value in [("frequency_penalty", 0.5), ("presence_penalty", 0.5), ("repetition_penalty", 1.1)]:
        status, payload, seconds = client.post({
            "messages": user("List ten fruits, one per line."), "max_tokens": 256, field: value})
        rows[field] = {"http": status, "finish": choice(payload).get("finish_reason"),
                       "chars": len(content(payload)), "seconds": round(seconds, 2)}
    ok = all(row["http"] == 200 and row["chars"] > 0 for row in rows.values())
    return result("pass" if ok else "fail", rows, drafter="off for each request")


def probe_stop(client):
    status, payload, _ = client.post({
        "messages": user("Count from 1 to 10 separated by commas, nothing else."),
        "max_tokens": 256, "temperature": 0, "stop": ["5"]})
    text = content(payload)
    finish = choice(payload).get("finish_reason")
    reasoning = (choice(payload).get("message") or {}).get("reasoning_content") \
        or (choice(payload).get("message") or {}).get("reasoning") or ""
    ok = status == 200 and "5" not in text and finish == "stop" and text.strip() != ""
    # A stop string matches the answer only, never the reasoning.
    return result("pass" if ok else "fail", {"http": status, "content": text[-120:], "finish": finish,
                                             "reasoning_has_stop": "5" in reasoning},
                  drafter="off")


def probe_seed(client):
    body = {"messages": user("Invent a one-line name for a coffee shop."), "max_tokens": 64,
            "temperature": 1.0, "seed": 1234}
    runs = [client.post(body) for _ in range(3)]
    texts = [content(payload) for _, payload, _ in runs]
    if any(status != 200 for status, _, _ in runs):
        return result("fail", {"http": [status for status, _, _ in runs]})
    # Batching with other requests may break bit identity; report what was seen.
    return result("pass" if len(set(texts)) == 1 else "fail",
                  {"identical": len(set(texts)) == 1, "distinct": len(set(texts)), "texts": texts},
                  drafter="on")


def probe_n(client):
    status, payload, _ = client.post({"messages": user("Say hi."), "max_tokens": 16, "n": 2})
    choices = len(payload.get("choices") or []) if status == 200 else 0
    if status == 200:
        return result("pass" if choices == 2 else "fail", {"http": status, "choices": choices})
    return result("pass" if 400 <= status < 500 and error_shape(payload) else "fail",
                  {"http": status, "error": payload.get("error")}, note="n > 1 refused; leave n unlisted")


def probe_stream_usage(client):
    status, events, _ = client.post({
        "messages": user("What is 17 * 23? Answer with the number."), "max_tokens": 512,
        "stream_options": {"include_usage": True}}, stream=True)
    if status != 200:
        return result("fail", {"http": status, "body": events})
    usage = next((event.get("usage") for event in reversed(events) if event.get("usage")), None)
    finishes = [c.get("finish_reason") for event in events for c in event.get("choices") or []
                if c.get("finish_reason")]
    text = "".join((c.get("delta") or {}).get("content") or ""
                   for event in events for c in event.get("choices") or [])
    ok = bool(usage) and usage.get("prompt_tokens", 0) > 0 and usage.get("completion_tokens", 0) > 0 \
        and finishes == ["stop"] and "<|" not in text
    return result("pass" if ok else "fail", {"usage": usage, "finishes": finishes, "content": text[-120:]})


def probe_finish_reasons(client):
    rows = {}
    status, payload, _ = client.post({"messages": user("Write a long story about the sea."), "max_tokens": 8})
    rows["length"] = {"http": status, "finish": choice(payload).get("finish_reason")}
    status, payload, _ = client.post({"messages": user("Say OK."), "max_tokens": 512})
    rows["stop"] = {"http": status, "finish": choice(payload).get("finish_reason")}
    status, payload, _ = client.post({"messages": user("What's the weather in Paris?"), "tools": [WEATHER],
                                      "tool_choice": "required", "max_tokens": 1024})
    message = choice(payload).get("message") or {}
    rows["tool_calls"] = {"http": status, "finish": choice(payload).get("finish_reason"),
                          "calls": [c.get("function", {}).get("name") for c in message.get("tool_calls") or []]}
    ok = rows["length"]["finish"] == "length" and rows["stop"]["finish"] == "stop" \
        and rows["tool_calls"]["finish"] == "tool_calls" and rows["tool_calls"]["calls"] == ["get_weather"]
    return result("pass" if ok else "fail", rows)


def probe_logprobs(client):
    status, payload, _ = client.post({"messages": user("Say yes."), "max_tokens": 32,
                                      "logprobs": True, "top_logprobs": 3})
    rows = ((choice(payload).get("logprobs") or {}).get("content") or []) if status == 200 else []
    ok = status == 200 and rows and all(len(row.get("top_logprobs") or []) == 3 for row in rows)
    return result("pass" if ok else "fail", {"http": status, "rows": len(rows),
                                             "error": payload.get("error") if status != 200 else None},
                  drafter="off", note="list logprobs only after this passes")


def probe_error_shapes(client):
    cases = {
        "undeclared_named_choice": {"messages": user("Hi"), "tools": [WEATHER],
                                    "tool_choice": {"type": "function", "function": {"name": "nope"}}},
        "required_without_tools": {"messages": user("Hi"), "tool_choice": "required"},
        "negative_max_tokens": {"messages": user("Hi"), "max_tokens": -1},
        "unsupported_part": {"messages": [{"role": "user", "content": [
            {"type": "input_audio", "input_audio": {"data": "AAAA", "format": "wav"}}]}]},
        "image_part": {"messages": [{"role": "user", "content": [
            {"type": "image_url", "image_url": {"url": "data:image/png;base64,iVBORw0KGgo="}}]}]},
    }
    rows = {}
    for name, body in cases.items():
        status, payload, _ = client.post(dict(body, max_tokens=body.get("max_tokens", 16)))
        rows[name] = {"http": status, "openai_shape": error_shape(payload),
                      "type": (payload.get("error") or {}).get("type") if isinstance(payload, dict) else None}
    # Every refusal is a typed 4xx with OpenAI's error object, never a 500.
    ok = all(400 <= row["http"] < 500 and row["openai_shape"] for row in rows.values())
    return result("pass" if ok else "fail", rows)


PROBES = {
    "penalties": probe_penalties, "stop": probe_stop, "seed": probe_seed, "n": probe_n,
    "stream_usage": probe_stream_usage, "finish_reasons": probe_finish_reasons,
    "logprobs": probe_logprobs, "error_shapes": probe_error_shapes,
}


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--base-url", required=True, help="OpenAI-compatible base URL ending in /v1")
    parser.add_argument("--model", default="muse-glimmer-30b")
    parser.add_argument("--api-key-env", help="environment variable holding the bearer key")
    parser.add_argument("--timeout", type=float, default=300)
    parser.add_argument("--only", help="comma-separated probe names: " + ", ".join(PROBES))
    parser.add_argument("--report", help="write the JSON report here")
    arguments = parser.parse_args()
    key = os.environ.get(arguments.api_key_env) if arguments.api_key_env else None
    client = Client(arguments.base_url, arguments.model, key, arguments.timeout)
    selected = arguments.only.split(",") if arguments.only else list(PROBES)
    report = {"model": arguments.model, "base_url": arguments.base_url, "drafter_off": DRAFTER_OFF,
              "probes": {}}
    for name in PROBES:
        if name not in selected:
            report["probes"][name] = result("skip", "not selected")
            continue
        try:
            report["probes"][name] = PROBES[name](client)
        except Exception as error:  # A transport failure is a failed probe, recorded as such.
            report["probes"][name] = result("fail", {"exception": f"{type(error).__name__}: {error}"})
        print(f"{name}: {report['probes'][name]['status']}", file=sys.stderr)
    counts = {state: sum(1 for p in report["probes"].values() if p["status"] == state)
              for state in ("pass", "fail", "skip")}
    report["counts"] = counts
    text = json.dumps(report, indent=1, ensure_ascii=False)
    if arguments.report:
        with open(arguments.report, "w", encoding="utf-8") as handle:
            handle.write(text + "\n")
    print(text)
    print(f"pass {counts['pass']} fail {counts['fail']} skip {counts['skip']}", file=sys.stderr)
    return 1 if counts["fail"] else 0


if __name__ == "__main__":
    sys.exit(main())
