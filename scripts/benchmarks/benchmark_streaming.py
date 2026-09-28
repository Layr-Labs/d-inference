#!/usr/bin/env python3
"""Measure one external streaming request, retaining failures and exact wire bytes.

Python standard library, macOS/Linux. The endpoint is explicit; no default
production traffic. API key comes only from DARKBLOOM_API_KEY, never the report.
"""

import argparse
from contextlib import contextmanager
from datetime import datetime, timezone
import hashlib
import http.client
import json
import math
import os
from pathlib import Path
import signal
import time
from urllib.parse import urlsplit

from streaming_latency import StreamObservation, receive_events, strict_json


@contextmanager
def absolute_timeout(seconds):
    """Bound DNS, connect, headers and streaming together, including trickles."""
    if signal.getitimer(signal.ITIMER_REAL) != (0.0, 0.0):
        raise RuntimeError("Existing process alarm; use a standalone client")
    previous = signal.getsignal(signal.SIGALRM)
    def expired(signum, frame):
        raise TimeoutError("Absolute request timeout")
    signal.signal(signal.SIGALRM, expired)
    signal.setitimer(signal.ITIMER_REAL, seconds)
    try:
        yield
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        signal.signal(signal.SIGALRM, previous)


def run(endpoint, request_path, output, timeout=300, prompt_tokens=None, client_label="external-client"):
    url = urlsplit(endpoint)
    if url.scheme not in ("http", "https") or not url.hostname or url.username or url.password or url.query or url.fragment:
        raise ValueError("Use an explicit HTTP(S) endpoint without credentials, query or fragment")
    if not math.isfinite(timeout) or not 0 < timeout <= 3600:
        raise ValueError("Timeout must be in (0, 3600] seconds")
    if prompt_tokens is not None and (type(prompt_tokens) is not int or not 0 <= prompt_tokens <= 10_000_000):
        raise ValueError("Invalid declared prompt token count")
    encoded = Path(request_path).read_bytes()
    body = strict_json(encoded)
    if (not isinstance(body, dict) or body.get("stream") is not True or body.get("n", 1) != 1
            or body.get("tools") or body.get("functions") or body.get("function_call")):
        raise ValueError("Request must select stream:true and one text completion without tools")
    out = Path(output)
    out.mkdir(mode=0o700, parents=True, exist_ok=False)
    (out / "request.json").write_bytes(encoded)
    headers = {"Content-Type": "application/json", "Accept": "text/event-stream", "Accept-Encoding": "identity"}
    key = os.environ.get("DARKBLOOM_API_KEY")
    if key:
        headers["Authorization"] = "Bearer " + key
    cls = http.client.HTTPSConnection if url.scheme == "https" else http.client.HTTPConnection
    connection = cls(url.hostname, url.port, timeout=timeout)
    observation = StreamObservation()
    receipt = dict(schema="external_streaming_latency_v1", endpoint=endpoint, client_label=client_label,
                   request_sha256=hashlib.sha256(encoded).hexdigest(), model=body.get("model"),
                   started_at_utc=datetime.now(timezone.utc).isoformat(), error=None,
                   clock_scope="client monotonic clock immediately before HTTP request through complete SSE token event receipt; includes connect/TLS",
                   upstream_openrouter_path_verified=False)
    start = time.monotonic_ns()
    caught = None
    try:
        with (out / "response.sse").open("xb") as raw, (out / "arrivals.jsonl").open("x") as arrivals:
            offset = 0
            def retain(line, elapsed):
                nonlocal offset
                raw.write(line)
                arrivals.write(json.dumps(dict(offset=offset, bytes=len(line), elapsed_ns=elapsed)) + "\n")
                offset += len(line)
            start = time.monotonic_ns()
            with absolute_timeout(timeout):
                connection.request("POST", url.path or "/", body=encoded, headers=headers)
                response = connection.getresponse()
                receipt["headers_received_ns"] = time.monotonic_ns() - start
                receipt["http_status"] = response.status
                # Retain timing/route correlation, not cookies or arbitrary secrets.
                receipt["response_headers"] = {k.lower(): v for k, v in response.getheaders()
                    if k.lower() in ("content-type", "x-request-id", "x-timing", "retry-after")}
                if response.status != 200:
                    raw.write(response.read(64 * 1024))
                    raise ValueError("HTTP " + str(response.status))
                if response.getheader("Content-Type", "").split(";", 1)[0].strip().lower() != "text/event-stream":
                    raise ValueError("Expected text/event-stream")
                for payload, received in receive_events(response, lambda: time.monotonic_ns() - start, retain):
                    observation.accept(payload, received)
                    if observation.done:
                        break
                if not observation.summary(time.monotonic_ns() - start)["complete"]:
                    raise ValueError("Incomplete stream: content, terminal choice and [DONE] required")
    except BaseException as error:
        caught = error
        # Server bodies, prompts and credential-bearing arbitrary exception text
        # stay out of the report; raw response remains in its private output dir.
        receipt["error"] = dict(type=type(error).__name__, message=str(error) if isinstance(error, (ValueError, TimeoutError)) else "Request failed")
    finally:
        elapsed = time.monotonic_ns() - start
        try:
            connection.close()
        except BaseException as error:
            receipt["cleanup_error"] = type(error).__name__
            if caught is None:
                caught = error
                receipt["error"] = dict(type=type(error).__name__, message="Connection cleanup failed")
            elif not isinstance(error, Exception) and isinstance(caught, Exception):
                caught = error  # Propagate operator interruption after retaining the primary error.
        receipt["measurement"] = observation.summary(elapsed, prompt_tokens, request_succeeded=caught is None)
        receipt["status"] = "completed" if caught is None else "failed"
        try:
            receipt["response_sha256"] = hashlib.sha256((out / "response.sse").read_bytes()).hexdigest()
        except OSError as error:
            receipt["capture_error"] = type(error).__name__
            receipt["status"] = "failed"
            receipt["measurement"] = observation.summary(elapsed, prompt_tokens, request_succeeded=False)
        (out / "receipt.json").write_text(json.dumps(receipt, indent=2, allow_nan=False) + "\n")
    if caught is not None and not isinstance(caught, Exception):
        raise caught
    return receipt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--endpoint", required=True, help="Full /v1/chat/completions URL")
    parser.add_argument("--request", type=Path, required=True, help="Exact streaming JSON request; use max_tokens:128 for MTP trials")
    parser.add_argument("--output", type=Path, required=True, help="New private result directory")
    parser.add_argument("--timeout", type=float, default=300)
    parser.add_argument("--prompt-tokens", type=int, help="Optional caller-declared SLA count, separate from reported usage")
    parser.add_argument("--client-label", required=True, help="Location/path label; a direct request is not OpenRouter-route verification")
    args = parser.parse_args()
    receipt = run(args.endpoint, args.request, args.output, args.timeout, args.prompt_tokens, args.client_label)
    print(json.dumps(dict(status=receipt["status"], measurement=receipt["measurement"], receipt=str(args.output / "receipt.json"))))
    return 0 if receipt["status"] == "completed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
