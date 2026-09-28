"""Native unsupported-control error boundary; not an OpenRouter hosted route.

Fourteen requests against the existing loopback large Flash-Next server. Chat
supports reasoning.enabled; Responses OFF uses reasoning.effort=none because
the local Responses type does not model an enabled field. Never start a server,
change model configuration, or execute a tool. Parent records binary/MTP mode.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import time

from api_matrix import MODEL, call
from lifecycle_matrix import DRAIN_FIELDS, metric, metrics
from reasoning_on_matrix import VISIBLE_MARKERS, strict_chat, strict_responses

CHAT = "/v1/chat/completions"
RESPONSES = "/v1/responses"
assert MODEL == "DarkBloom/Qwen3.8-Flash-Next-Q4-mtp"


def payload(endpoint, reasoning, stream, text):
    value = {"model": MODEL, "temperature": 0, "stream": stream, "reasoning": reasoning}
    if endpoint == CHAT:
        value.update(messages=[{"role": "user", "content": text}], max_tokens=512,
                     seed=424242, stream_options={"include_usage": True})
    else:
        value.update(input=text, max_output_tokens=512, store=False)
    return value


def cases():
    for endpoint, label in ((CHAT, "chat"), (RESPONSES, "responses")):
        for effort in ("high", "minimal"):
            for streaming in (False, True):
                name = f"{label}-{effort}-{'stream' if streaming else 'plain'}"
                marker = "PRIVATE_SYNTHETIC_PROMPT_" + name.replace("-", "_") + "_DO_NOT_ECHO"
                reasoning = {"effort": effort}
                if endpoint == CHAT:
                    reasoning["enabled"] = True
                yield name, endpoint, payload(endpoint, reasoning, streaming,
                    marker + ". Reply with exactly: ready"), "invalid", marker
    for endpoint, label in ((CHAT, "chat-false-high-precedence"), (RESPONSES, "responses-off-effort-none")):
        for streaming in (False, True):
            reasoning = {"enabled": False, "effort": "high"} if endpoint == CHAT else {"effort": "none"}
            yield (label + ("-stream" if streaming else "-plain"), endpoint,
                   payload(endpoint, reasoning, streaming, "Reply with exactly: ready"), "off", None)
    for endpoint, label in ((CHAT, "chat"), (RESPONSES, "responses")):
        reasoning = {"effort": "low"}
        if endpoint == CHAT:
            reasoning["enabled"] = True
        yield (label + "-low-recovery", endpoint,
               payload(endpoint, reasoning, False, "Reply with exactly: ready"), "recovery", None)


def verify(endpoint, request, kind, marker, status, raw):
    if kind == "invalid":
        assert status == 400, f"unsupported control returned HTTP {status}, expected 400"
        assert not any(line.startswith(("data:", "event:")) for line in raw.splitlines()), "error began SSE"
        document = json.loads(raw)
        assert isinstance(document, dict) and isinstance(document.get("error"), dict), "missing structured error"
        error = document["error"]
        assert error.get("type") == "invalid_request_error", "wrong error type"
        assert isinstance(error.get("message"), str) and error["message"], "empty error message"
        assert marker not in raw, "synthetic private prompt echoed into error"
        effort = request["reasoning"]["effort"]
        # Distinguish an echoed untrusted token 'high' from the fixed supported
        # option 'xhigh'. No caller value or prompt should enter this envelope.
        assert not re.search(r"(?<![A-Za-z0-9_])" + re.escape(effort) + r"(?![A-Za-z0-9_])", error["message"]), "caller effort echoed into error"
        assert not any(key in document for key in ("choices", "output", "usage")), "generation payload on invalid input"
        return {"error": error, "before_sse": True, "prompt_and_effort_not_echoed": True}
    assert status == 200, f"HTTP {status}"
    view = strict_chat(raw, request["stream"]) if endpoint == CHAT else strict_responses(raw, request["stream"])
    assert view["done"] and view["terminal_count"] == 1 and view["usage"], "missing terminal or usage"
    assert view["finish"] == "stop" and not view["calls"], "unexpected tool/terminal"
    assert view["content"].strip() == "ready", "wrong recovery or OFF answer"
    assert not any(marker in view["content"] for marker in VISIBLE_MARKERS), "visible framing leakage"
    if kind == "off":
        assert not view["reasoning"], "OFF request produced reasoning"
    return view


def save(path, value):
    with path.open("x", encoding="utf-8") as stream:
        json.dump(value, stream, indent=2, ensure_ascii=False)
        stream.write("\n")


def check_drain(output):
    observations = []
    try:
        deadline = time.monotonic() + 10
        while True:
            sample = metrics()
            observations.append(sample)
            if not sample["rows"]:
                return {"checked": False, "reason": "no loaded-model metric rows"}
            values = {field: metric(sample, field) for field in DRAIN_FIELDS}
            if all(value == 0 for value in values.values()):
                return {"checked": True, "passed": True, "values": values}
            assert time.monotonic() < deadline, f"request/page ownership did not drain: {values}"
            time.sleep(0.2)
    except Exception as error:
        return {"checked": True, "passed": False, "failure": f"{type(error).__name__}: {error}"}
    finally:
        save(output / "drain.metrics.json", observations)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    scope = "native unsupported-control error boundary, not OpenRouter hosted route"
    from endpoint_config import base_url
    save(args.output / "run.json", {"model": MODEL, "scope": scope, "base": base_url(),
        "harness_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "planned_cases": 14, "expected_400": 8, "expected_200": 6,
        "endpoint_contract": {"chat_off": "reasoning.enabled=false preserves unsupported effort while OFF",
            "responses_off": "reasoning.effort=none; reasoning.enabled is not modeled by the local Responses type"},
        "limits": ["Binary/artifact/MTP identities are recorded by the parent run.",
                   "No hosted adapter, authentication, billing, or external routing claim."]})
    results = []
    for name, endpoint, request, kind, marker in cases():
        record = {"case": name, "endpoint": endpoint, "request": request, "kind": kind,
                  "expected_http": 400 if kind == "invalid" else 200, "started_unix": time.time()}
        start = time.monotonic()
        try:
            assert request["model"] == MODEL
            assert "enable_thinking" not in request and "chat_template_kwargs" not in request
            status, raw = call(endpoint, request)
            record.update(http=status, raw=raw)
            record["view"] = verify(endpoint, request, kind, marker, status, raw)
            record["passed"] = True
        except Exception as error:
            record.update(passed=False, failure=f"{type(error).__name__}: {error}")
        record["elapsed_seconds"] = time.monotonic() - start
        save(args.output / (name + ".json"), record)
        result = {key: record[key] for key in ("case", "kind", "http", "expected_http", "passed", "failure") if key in record}
        results.append(result)
        print(json.dumps(result), flush=True)
    drain = check_drain(args.output)
    summary = {"schema": 1, "model": MODEL, "scope": scope, "cases": results, "drain": drain,
               "passed": len(results) == 14 and all(row["passed"] for row in results)
                   and (not drain["checked"] or drain["passed"])}
    save(args.output / "summary.json", summary)
    raise SystemExit(0 if summary["passed"] else 1)


if __name__ == "__main__":
    main()
