"""Bounded 81K/82K envelope qualification on an existing loopback server.

Requires native paging, prefix cache OFF and the requested actual MTP posture.
One positive long-context request and two invalid-envelope requests are sent.
This does not certify the model card context, physical 128-GB hardware, signed
persistence, arbitrary long-context quality, or a hosted production route.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re

from api_matrix import MODEL
from lifecycle_matrix import Matrix, exchange, metric, metrics, require_posture, save
from reasoning_on_matrix import VISIBLE_MARKERS, strict_chat

assert MODEL == "DarkBloom/Qwen3.8-Flash-Next-Q4-mtp"
LIMIT = 82_000
ENDPOINT = "/v1/chat/completions"
MTP_COUNTERS = ("mtp_rounds_total", "mtp_tokens_proposed_total", "mtp_tokens_accepted_total")
TOKEN_COUNTERS = ("mlx_server_prompt_tokens_total", "mlx_server_completion_tokens_total")
LIMITS = [
    "Positive actual usage must be at least 80000 prompt tokens and prompt+32 no greater than the advertised 82000.",
    "Repeated text units are a fixture construction choice, not an assumed tokenizer or template overhead count.",
    "Output comparison is exact returned text/finish/usage, not a full-logit or internal-state comparison.",
    "Negative cases require structured rejection with no served-token/MTP-counter increase; metrics are not a hardware instruction trace.",
    "This is the owned provider 82K envelope, not the original model-card context, physical 128-GB qualification, or broad retrieval quality.",
    "Parent records source, binary, metallib and weight identities; this script never changes serving configuration or starts a model.",
]


def request(text, maximum):
    return {"model": MODEL, "messages": [{"role": "user", "content": text}],
            "temperature": 0, "seed": 424242, "max_tokens": maximum,
            "reasoning": {"enabled": False}, "stream": False}


def posture(sample, mtp):
    require_posture(sample, cached=False)
    assert metric(sample, "mtp_active") == (1 if mtp == "on" else 0), "wrong actual MTP mode"
    return {"backend": "paged", "prefix_cache": "off", "mtp_active": metric(sample, "mtp_active")}


def token_counter(sample, name):
    rows = re.findall(r"^" + re.escape(name) + r" ([0-9]+(?:\.0+)?)$", sample["raw"], flags=re.MULTILINE)
    assert len(rows) == 1, f"missing/ambiguous {name}"
    return int(float(rows[0]))


def captured_exchange(output, label, endpoint, body=None):
    if body is not None:
        save(output / (label + ".request.json"), body)
    try:
        response = exchange(endpoint, body, timeout=300)
    except Exception as error:
        save(output / (label + ".response.json"), {"transport_error": f"{type(error).__name__}: {error}"})
        raise
    save(output / (label + ".response.json"), response)
    return response


def advertisement(output):
    response = captured_exchange(output, "models", "/v1/models")
    assert response["http"] == 200
    models = [item for item in json.loads(response["body"])["data"] if item.get("id") == MODEL]
    assert len(models) == 1, "owned Flash-Next model missing/duplicated"
    model = models[0]
    assert model.get("context_length") == LIMIT and model.get("max_model_len") == LIMIT, "82K advertisement not verified"
    return {"model": MODEL, "context_length": model["context_length"], "max_model_len": model["max_model_len"]}


def positive(matrix, mode):
    before = metrics()
    save(matrix.output / "positive.before.metrics.json", before)
    posture(before, mode)
    text = ("Ignore the filler below. After it, follow only the counting instruction.\n"
            + " z" * 81_000
            + "\nOutput every integer from 1 through 100, in order, separated only by commas. "
              "Do not omit integers or add an explanation.")
    body = request(text, 32)
    response = captured_exchange(matrix.output, "positive", ENDPOINT, body)
    assert response["http"] == 200, f"positive envelope HTTP {response['http']}"
    view = strict_chat(response["body"], False)
    save(matrix.output / "positive.view.json", view)
    usage = view["usage"]
    assert usage["prompt_tokens"] >= 80_000, "positive prompt did not exercise the requested context band"
    assert usage["prompt_tokens"] + 32 <= LIMIT, "positive request outside advertised envelope"
    assert usage["completion_tokens"] == 32 and view["finish"] == "length", "output budget did not execute exactly"
    assert view["content"] and not view["reasoning"] and not view["calls"], "unexpected content channels"
    assert not any(marker in view["content"] for marker in VISIBLE_MARKERS), "visible framing leakage"
    details = usage.get("prompt_tokens_details") or {}
    assert details.get("cached_tokens", 0) == 0, "unexpected prefix reuse"
    matrix.drained("positive-drain")
    after = metrics()
    save(matrix.output / "positive.after.metrics.json", after)
    posture(after, mode)
    deltas = {name: metric(after, name) - metric(before, name) for name in MTP_COUNTERS}
    assert all(value >= 0 and int(value) == value for value in deltas.values()), "MTP counters reset or malformed"
    if mode == "on":
        assert deltas["mtp_rounds_total"] > 0 and deltas["mtp_tokens_proposed_total"] > 0, "MTP ON did not run real drafts"
        assert deltas["mtp_tokens_accepted_total"] <= deltas["mtp_tokens_proposed_total"]
    else:
        assert all(value == 0 for value in deltas.values()), "MTP OFF executed draft work"
    return {"prompt_tokens": usage["prompt_tokens"], "completion_tokens": usage["completion_tokens"],
            "total_reserved_tokens": usage["prompt_tokens"] + 32, "finish": view["finish"],
            "output_sha256": hashlib.sha256(view["content"].encode()).hexdigest(), "mtp_deltas": deltas}


def reject(matrix, mode, name, body, sentinel):
    before = metrics()
    save(matrix.output / (name + ".before.metrics.json"), before)
    posture(before, mode)
    response = captured_exchange(matrix.output, name, ENDPOINT, body)
    assert response["http"] == 400, f"invalid envelope HTTP {response['http']}, expected 400"
    assert not any(line.startswith(("event:", "data:")) for line in response["body"].splitlines()), "error started SSE"
    data = json.loads(response["body"])
    error = data.get("error")
    assert isinstance(error, dict) and error.get("type") == "invalid_request_error", "missing structured invalid-input error"
    assert isinstance(error.get("message"), str) and error["message"]
    assert sentinel not in response["body"], "synthetic prompt echoed into error"
    assert not any(key in data for key in ("choices", "output", "usage")), "invalid request exposed generation output"
    matrix.drained(name + "-drain")
    after = metrics()
    save(matrix.output / (name + ".after.metrics.json"), after)
    posture(after, mode)
    for name in MTP_COUNTERS:
        assert metric(before, name) == metric(after, name), "rejected request changed MTP counters"
    for name in TOKEN_COUNTERS:
        assert token_counter(before, name) == token_counter(after, name), "rejected request recorded served tokens"
    return {"http": 400, "error": error, "no_served_token_or_mtp_counter_increase": True}


def reference_comparison(output, reference, harness_hash):
    summary = json.loads((reference / "summary.json").read_text())
    assert summary.get("passed") is True and summary.get("mtp") == "off" and summary.get("model") == MODEL
    assert summary.get("harness_sha256") == harness_hash, "reference used another harness"
    current_request = json.loads((output / "positive.request.json").read_text())
    expected_request = json.loads((reference / "positive.request.json").read_text())
    assert current_request == expected_request, "reference input differs"
    actual = json.loads((output / "positive.view.json").read_text())
    expected = json.loads((reference / "positive.view.json").read_text())
    for key in ("content", "reasoning", "calls", "finish", "usage"):
        assert actual[key] == expected[key], f"target/MTP {key} differs"
    return {"reference": str(reference), "exact_content_finish_usage": True}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--mtp", required=True, choices=("off", "on"))
    parser.add_argument("--reference", type=Path, help="successful target-only output directory")
    args = parser.parse_args()
    if args.reference and args.mtp != "on":
        parser.error("--reference compares an MTP ON run to a successful target-only OFF directory")
    args.output.mkdir(parents=True, exist_ok=False)
    matrix = Matrix(args.output)
    harness_hash = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
    summary = {"schema": 1, "model": MODEL, "mtp": args.mtp, "harness_sha256": harness_hash,
               "scope": "owned provider 81K/82K context envelope", "passed": False, "limits": LIMITS}
    save(args.output / "run.json", {**summary, "advertised_limit": LIMIT, "http_timeout_seconds": 300,
        "reference": str(args.reference) if args.reference else None})
    try:
        matrix.case("advertisement", lambda: advertisement(args.output))
        initial = metrics()
        save(args.output / "initial.metrics.json", initial)
        matrix.case("initial-posture", lambda: posture(initial, args.mtp))
        matrix.case("initial-drain", lambda: matrix.drained("initial-drain"))
        matrix.case("positive-envelope", lambda: positive(matrix, args.mtp))
        if args.reference:
            matrix.case("target-mtp-reference", lambda: reference_comparison(args.output, args.reference, harness_hash))
        sentinel = "PRIVATE_OVERSIZED_PROMPT_DO_NOT_ECHO"
        oversized = request(sentinel + " z" * 83_000 + "\nReply with exactly: ready", 32)
        matrix.case("oversized-prompt", lambda: reject(matrix, args.mtp, "oversized-prompt", oversized, sentinel))
        budget_sentinel = "PRIVATE_OVERSIZED_OUTPUT_BUDGET_DO_NOT_ECHO"
        oversized_budget = request(budget_sentinel + ". Reply with exactly: ready", 82_001)
        matrix.case("oversized-output-budget", lambda: reject(matrix, args.mtp, "oversized-output-budget", oversized_budget, budget_sentinel))
        matrix.case("final-drain", lambda: matrix.drained("final-drain"))
        summary["passed"] = all(row["passed"] for row in matrix.results)
    except Exception as error:
        summary["failure"] = f"{type(error).__name__}: {error}"
    finally:
        summary["checks"] = matrix.results
        save(args.output / "summary.json", summary)
    raise SystemExit(0 if summary["passed"] else 1)


if __name__ == "__main__":
    main()
