"""Real loopback lifecycle checks; operates an existing server, never starts one.

Run reference mode with prefix cache OFF, then cached mode with complete cache
ON in an isolated ephemeral-key store and resident cache OFF. Preserve the exact
binary/configuration association separately. Usage and posture prove the bounded
API behavior below, not byte-exact full-state restoration, physical SSD reads,
persistent restart, signed identity, or authenticated coordinator behavior.
"""

import argparse
import hashlib
import http.client
import json
from pathlib import Path
import re
import socket
import struct
import time
import urllib.error
import urllib.request
import uuid

from api_matrix import MODEL, chat_view
from endpoint_config import base_url, headers, open_request, connection_target, raw_http_headers

ENDPOINT = "/v1/chat/completions"
DRAIN_FIELDS = ("kv_active_requests", "kv_waiting_requests",
                "paged_kv_live_bytes", "paged_kv_reserved_bytes")


def save(path, value):
    with path.open("x", encoding="utf-8") as stream:
        json.dump(value, stream, indent=2, ensure_ascii=False)
        stream.write("\n")


def exchange(endpoint, payload=None, timeout=300):
    request = urllib.request.Request(base_url() + endpoint,
        data=None if payload is None else json.dumps(payload).encode(),
        headers=headers())
    started = time.monotonic()
    try:
        response = open_request(request, timeout=timeout)
    except urllib.error.HTTPError as error:
        response = error
    with response:
        return {"http": response.status, "body": response.read().decode(),
                "headers": dict(response.headers), "seconds": time.monotonic() - started}


def metrics():
    response = exchange("/metrics", timeout=10)
    assert response["http"] == 200, f"metrics HTTP {response['http']}"
    rows = []
    for line in response["body"].splitlines():
        match = re.fullmatch(r'(\w+)\{(.*)\}\s+([-+\deE.]+)', line)
        if not match:
            continue
        labels = {key: json.loads('"' + value + '"') for key, value in
                  re.findall(r'(\w+)="((?:[^"\\]|\\.)*)"', match[2])}
        if labels.get("model") == MODEL:
            rows.append({"name": match[1], "labels": labels, "value": float(match[3])})
    return {"unix_time": time.time(), "raw": response["body"], "rows": rows}


def metric(sample, name, **labels):
    rows = [row for row in sample["rows"] if row["name"] == name and
            all(row["labels"].get(key) == value for key, value in labels.items())]
    assert len(rows) == 1, f"expected one actual {name} {labels} metric, got {len(rows)}"
    return rows[0]["value"]


def require_posture(sample, cached):
    assert metric(sample, "kv_backend_info", backend="paged") == 1
    assert metric(sample, "prefix_cache_status", state="ready" if cached else "disabled",
                  reason="ready" if cached else "config_disabled") == 1
    if cached:
        assert metric(sample, "complete_prefix_key_persistent") == 0, "expected isolated ephemeral test key"


def usage(view):
    value = view["usage"]
    assert isinstance(value, dict), "missing usage"
    assert all(isinstance(value.get(key), int) for key in ("prompt_tokens", "completion_tokens", "total_tokens"))
    assert value["total_tokens"] == value["prompt_tokens"] + value["completion_tokens"]
    return value


def cached_tokens(view):
    details = usage(view).get("prompt_tokens_details")
    assert isinstance(details, dict) and isinstance(details.get("cached_tokens"), int), "missing cache usage"
    count = details["cached_tokens"]
    assert 0 <= count <= view["usage"]["prompt_tokens"]
    return count


def output_identity(view):
    return {key: view[key] for key in ("content", "reasoning", "calls", "finish")}


def same_output(actual, expected):
    assert output_identity(actual) == output_identity(expected), "output/finish differs from uncached reference"
    for key in ("prompt_tokens", "completion_tokens", "total_tokens"):
        assert usage(actual)[key] == usage(expected)[key], f"{key} differs from reference"


def long_payload(run_id, suffix=False):
    references = "\n".join(
        f"Record {index:04d}: amber birch cobalt delta echo foxtrot golf hotel."
        for index in range(320))
    instruction = ("201 through 400" if suffix else "1 through 200")
    return {"model": MODEL, "temperature": 0, "seed": 424242, "max_tokens": 128,
        "enable_thinking": False, "stream": False,
        "messages": [{"role": "system", "content": "Synthetic lifecycle fixture " + run_id},
                     {"role": "user", "content": references +
                      "\nIgnore the records. Output every integer from " + instruction +
                      ", in order, separated only by commas. Do not skip numbers or explain."}]}


class Matrix:
    def __init__(self, output):
        self.output = output
        self.results = []

    def case(self, name, action):
        try:
            detail = action()
            result = {"case": name, "passed": True, "detail": detail}
        except Exception as error:
            result = {"case": name, "passed": False,
                      "failure": f"{type(error).__name__}: {error}"}
            save(self.output / (name + ".result.json"), result)
            self.results.append(result)
            print(json.dumps(result), flush=True)
            raise
        save(self.output / (name + ".result.json"), result)
        self.results.append(result)
        print(json.dumps(result), flush=True)
        return detail

    def chat(self, name, payload):
        save(self.output / (name + ".request.json"), payload)
        response = exchange(ENDPOINT, payload)
        save(self.output / (name + ".response.json"), response)
        assert response["http"] == 200, f"HTTP {response['http']}"
        view = chat_view(response["body"], False)
        assert not view["reasoning"] and not view["calls"], "unexpected reasoning/tool output"
        assert view["finish"] in ("length", "stop") and view["content"], "missing output/terminal"
        usage(view)
        save(self.output / (name + ".view.json"), view)
        return view

    def drained(self, name, timeout=15):
        deadline = time.monotonic() + timeout
        samples = []
        try:
            while True:
                sample = metrics()
                samples.append(sample)
                if all(metric(sample, field) == 0 for field in DRAIN_FIELDS):
                    return {"polls": len(samples), "drained_fields": list(DRAIN_FIELDS)}
                assert time.monotonic() < deadline, "native row/page ownership did not drain"
                time.sleep(0.2)
        finally:
            save(self.output / (name + ".metrics.json"), samples)

    def cancel_after_content(self, payload):
        payload = {**payload, "stream": True, "max_tokens": 2048,
                   "stream_options": {"include_usage": True}}
        payload["messages"] = [*payload["messages"][:-1], {"role": "user", "content":
            payload["messages"][-1]["content"].split("\nIgnore the records.")[0] +
            "\nOutput every integer from 1 through 10000, in order, separated only by commas. "
            "Do not skip numbers or explain."}]
        save(self.output / "cancel.request.json", payload)
        transport = socket.create_connection(connection_target(), timeout=120)
        observed = {"frames": [], "content": "", "reset_sent": False}
        response = None
        try:
            body = json.dumps(payload).encode()
            header = raw_http_headers(ENDPOINT, len(body))
            transport.sendall(header + body)
            response = http.client.HTTPResponse(transport)
            response.begin()
            observed["http"] = response.status
            assert response.status == 200, f"stream HTTP {response.status}"
            deadline = time.monotonic() + 120
            captured = 0
            while not observed["content"].strip():
                assert time.monotonic() < deadline, "no content before cancellation deadline"
                line = response.readline()
                assert line, "stream ended before content"
                captured += len(line)
                assert captured < 1_048_576, "bounded synthetic capture limit exceeded"
                if not line.startswith(b"data: "):
                    continue
                body = line[6:].strip().decode()
                observed["frames"].append(body)
                assert body != "[DONE]", "generation finished before cancellation"
                frame = json.loads(body)
                for choice in frame.get("choices", []):
                    assert not choice.get("finish_reason"), "terminal arrived before cancellation"
                    observed["content"] += choice.get("delta", {}).get("content") or ""
            sample = metrics()
            save(self.output / "cancel.before-reset.metrics.json", sample)
            assert metric(sample, "kv_active_requests") > 0, "no live row observed before reset"
            transport.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
            observed["reset_sent"] = True
        finally:
            if response is not None:
                response.close()
            transport.close()
            save(self.output / "cancel.partial-response.json", observed)
        assert observed["content"] and observed["reset_sent"]
        return self.drained("cancel-drain")

    def half_close(self):
        payload = {"model": MODEL, "temperature": 0, "max_tokens": 32,
            "enable_thinking": False, "messages": [{"role": "user", "content":
                                                     "Reply exactly: half close works"}]}
        save(self.output / "half-close.request.json", payload)
        body = json.dumps(payload).encode()
        header = raw_http_headers(ENDPOINT, len(body), close=True)
        with socket.create_connection(connection_target(), timeout=120) as transport:
            transport.sendall(header + body)
            transport.shutdown(socket.SHUT_WR)
            response = http.client.HTTPResponse(transport)
            response.begin()
            result = {"http": response.status, "headers": dict(response.headers),
                      "body": response.read().decode()}
            save(self.output / "half-close.response.json", result)
        assert result["http"] == 200, "legal write EOF cancelled the request"
        view = chat_view(result["body"], False)
        assert view["content"].strip() == "half close works" and view["finish"] == "stop"
        assert not view["reasoning"] and not view["calls"]
        return {"finish": view["finish"], "usage": usage(view)}

    @staticmethod
    def image_payload():
        return {"model": MODEL, "max_tokens": 16, "messages": [{"role": "user", "content": [
            {"type": "text", "text": "Describe this synthetic image."},
            {"type": "image_url", "image_url": {"url": "data:image/png;base64,"
             "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jY9kAAAAASUVORK5CYII="}}]}]}

    def image_supported(self):
        # Capability is selected explicitly from the bound artifact before the
        # request, never inferred from whichever HTTP status happens to arrive.
        # This checks admission/retirement; pixel-answer quality has its own matrix.
        payload = self.image_payload()
        payload.update(temperature=0, max_tokens=64, reasoning={"enabled": False})
        before = metrics()
        view = self.chat("image-supported", payload)
        assert cached_tokens(view) == 0, "short fresh media request unexpectedly reused a checkpoint"
        after = metrics()
        deltas = {name: metric(after, name) - metric(before, name)
                  for name in ("mtp_tokens_proposed_total", "mtp_tokens_accepted_total")}
        assert all(value == 0 for value in deltas.values()), "media unexpectedly speculated"
        return {"http": 200, "finish": view["finish"], "usage": usage(view), "mtp_deltas": deltas,
                "scope": "Declared full-VLM admission; not pixel-answer quality"}

    def image_refusal(self):
        payload = self.image_payload()
        save(self.output / "image-refusal.request.json", payload)
        response = exchange(ENDPOINT, payload)
        save(self.output / "image-refusal.response.json", response)
        assert response["http"] == 400, f"unsupported image HTTP {response['http']}"
        error = json.loads(response["body"]).get("error")
        assert isinstance(error, dict) and error.get("message"), "missing structured refusal"
        # Local HTTP deliberately exposes InferenceFailure's sanitized public
        # message, not its internal code/model detail. This exact boundary is
        # pinned by ProviderCoreTests/InferenceFailurePrivacyTests.swift.
        assert error.get("type") == "invalid_request_error" and \
            error["message"] == "Media input is not supported.", "unexpected public refusal contract"
        assert "base64" not in response["body"] and "iVBOR" not in response["body"], "image payload leaked"
        return {"http": response["http"], "error": error}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", required=True, choices=("reference", "cached"))
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--reference", type=Path)
    parser.add_argument("--media-capability", choices=("supported", "unsupported"),
                        help="Required for cached mode: select from the exact bound artifact, not its response.")
    args = parser.parse_args()
    if args.mode == "cached" and args.reference is None:
        parser.error("cached mode requires --reference from a successful prefix-OFF run")
    if args.mode == "cached" and args.media_capability is None:
        parser.error("cached mode requires explicit --media-capability from the bound artifact")
    args.output.mkdir(parents=True, exist_ok=False)
    suite = Matrix(args.output)
    try:
        if args.mode == "reference":
            run_id = str(uuid.uuid4())
            for name, suffix in (("original", False), ("suffix", True)):
                def baseline(name=name, suffix=suffix):
                    view = suite.chat(name, long_payload(run_id, suffix))
                    assert usage(view)["prompt_tokens"] > 4096, "fixture is too short for prefix reuse"
                    assert usage(view)["completion_tokens"] == 128 and view["finish"] == "length"
                    assert cached_tokens(view) == 0
                    sample = metrics()
                    save(args.output / (name + ".metrics.json"), sample)
                    require_posture(sample, cached=False)
                    return {"usage": usage(view), "output_sha256": hashlib.sha256(view["content"].encode()).hexdigest()}
                suite.case(name, baseline)
        else:
            reference_summary = json.loads((args.reference / "summary.json").read_text())
            assert reference_summary["mode"] == "reference" and reference_summary["passed"]
            requests = {name: json.loads((args.reference / (name + ".request.json")).read_text())
                        for name in ("original", "suffix")}
            expected = {name: json.loads((args.reference / (name + ".view.json")).read_text())
                        for name in requests}
            def cached_case(name, reference, cold=False):
                view = suite.chat(name, requests[reference])
                same_output(view, expected[reference])
                count = cached_tokens(view)
                assert count == 0 if cold else count > 0, "unexpected cache usage"
                sample = metrics()
                save(args.output / (name + ".metrics.json"), sample)
                require_posture(sample, cached=True)
                return {"cached_tokens": count, "usage": usage(view), "matches_uncached_reference": True}
            suite.case("cold", lambda: cached_case("cold", "original", cold=True))
            suite.case("repeat", lambda: cached_case("repeat", "original"))
            suite.case("suffix", lambda: cached_case("suffix", "suffix"))
            suite.case("before-cancel-drain", lambda: suite.drained("before-cancel-drain"))
            suite.case("cancel", lambda: suite.cancel_after_content(requests["original"]))
            suite.case("readmission", lambda: cached_case("readmission", "original"))
            suite.case("half-close", suite.half_close)
            if args.media_capability == "supported":
                suite.case("image-supported", suite.image_supported)
            else:
                suite.case("image-refusal", suite.image_refusal)
            suite.case("final-drain", lambda: suite.drained("final-drain"))
    finally:
        save(args.output / "summary.json", {"mode": args.mode, "model": MODEL,
            "media_capability": args.media_capability,
            "base_url": base_url(), "reference": str(args.reference) if args.reference else None,
            "passed": len(suite.results) == (2 if args.mode == "reference" else 9)
                      and all(row["passed"] for row in suite.results),
            "results": suite.results, "scope": __doc__})


if __name__ == "__main__":
    main()
