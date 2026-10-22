#!/usr/bin/env python3
"""One bounded external chat request; auth is read only from a private file."""

import argparse
from datetime import datetime, timezone
import hashlib
import http.client
import json
from pathlib import Path
import time

from client_inputs import inputs, private_file, write_json
from terminal_observation import TerminalObservation
from client_timeout import absolute_timeout
from streaming_latency import receive_events


class ClientOutcome(ValueError):
    pass


def run(endpoint, model, prompt_file, token_file, output, timeout=120,
        declared_prompt_tokens=None):
    url, secret, prompt, encoded = inputs(endpoint, model, prompt_file, token_file,
                                         timeout, declared_prompt_tokens)
    out = Path(output)
    out.mkdir(mode=0o700, parents=True, exist_ok=False)
    with private_file(out / "request.json") as file:
        file.write(encoded)
    receipt = dict(schema="installed_external_terminal_observer_v1", endpoint=endpoint,
                   model=model, request_sha256=hashlib.sha256(encoded).hexdigest(),
                   prompt_utf8_sha256=hashlib.sha256(prompt).hexdigest(),
                   started_at_utc=datetime.now(timezone.utc).isoformat(), timeout_seconds=timeout,
                   request_settings=dict(max_tokens=128, enable_thinking=False, reasoning_parser="qwen3",
                                         temperature=0, top_p=1, top_k=0,
                                         repetition_penalty=1, presence_penalty=0, frequency_penalty=0),
                   clock_scope="client monotonic clock immediately before HTTP POST, including connection/TLS, through the delimiter of the first SSE event with nonempty delta.content",
                   error=None, http_status=None, capture_complete=False, http_body_eof_observed=False,
                   server_token_count_independently_verified=False,
                   model_answer_correctness_verified=False, native_retirement_verified=False,
                   owner_release_verified=False, cancellation_qualification=False,
                   engine_performance_measured=False, product_qualification=False)
    headers = {"Content-Type": "application/json", "Accept": "text/event-stream",
               "Accept-Encoding": "identity", "Authorization": "Bearer " + secret.decode("ascii")}
    cls = http.client.HTTPSConnection if url.scheme == "https" else http.client.HTTPConnection
    connection = cls(url.hostname, url.port, timeout=timeout)
    response = None
    observation = TerminalObservation(model)
    start = time.monotonic_ns()
    caught = None
    error_code = None
    capture_hash = hashlib.sha256()
    captured_bytes = 0
    try:
        with private_file(out / "response.sse") as raw, private_file(out / "arrivals.jsonl") as arrivals:
            line_count = 0

            def retain(data, elapsed):
                nonlocal captured_bytes, line_count
                if secret in data:
                    # Do not persist a credential echoed by a peer. This leaves
                    # an explicitly partial capture, never a redacted exact-wire claim.
                    raise ClientOutcome("credential_echo_capture_refused")
                line_count += 1
                if line_count > 4096:
                    raise ClientOutcome("capture_line_limit")
                raw.write(data)
                arrivals.write((json.dumps(dict(offset=captured_bytes, bytes=len(data),
                                                 elapsed_ns=elapsed)) + "\n").encode())
                captured_bytes += len(data)
                capture_hash.update(data)

            with absolute_timeout(timeout):
                start = time.monotonic_ns()
                receipt["request_start_monotonic_ns"] = start
                connection.request("POST", url.path, body=encoded, headers=headers)
                response = connection.getresponse()
                receipt["headers_received_ns"] = time.monotonic_ns() - start
                receipt["http_status"] = response.status
                if response.status != 200:
                    body = response.read(65537)
                    receipt["http_error_body_truncated"] = len(body) > 65536
                    retain(body[:65536], time.monotonic_ns() - start)
                    receipt["capture_complete"] = len(body) <= 65536
                    raise ClientOutcome("http_error")
                if response.getheader("Content-Type", "").split(";", 1)[0].strip().lower() != "text/event-stream":
                    raise ClientOutcome("wrong_content_type")
                for payload, received in receive_events(
                        response, lambda: time.monotonic_ns() - start, retain,
                        maximum_bytes=8 * 1024 * 1024):
                    observation.accept(payload, received)
                    # Continue through HTTP body EOF, detecting records after
                    # [DONE] rather than silently accepting a buffered suffix.
                receipt["capture_complete"] = True
                receipt["http_body_eof_observed"] = True
                receipt["http_body_eof_received_ns"] = time.monotonic_ns() - start
                if observation.typed_error is not None:
                    if not observation.done:
                        raise ClientOutcome("typed_error_missing_done")
                    raise ClientOutcome("typed_terminal_failure")
                if not observation.done or observation.finish_reason is None:
                    raise ClientOutcome("incomplete_stream")
                if observation.usage is None:
                    raise ClientOutcome("missing_usage")
                if observation.first_content_ns is None:
                    raise ClientOutcome("no_content")
    except BaseException as error:
        caught = error
        error_code = (str(error) if isinstance(error, ClientOutcome)
                      else "absolute_timeout" if isinstance(error, TimeoutError) else "request_failed")
        receipt["error"] = dict(type=type(error).__name__, code=error_code)
    finally:
        elapsed = time.monotonic_ns() - start
        # A partial HTTP/1.0 response can retain its socket file after the
        # connection object detaches it. Close both, even when the first fails.
        for owned in (response, connection):
            if owned is None:
                continue
            try:
                owned.close()
            except BaseException as error:
                receipt.setdefault("cleanup_errors", []).append(type(error).__name__)
                if caught is None:
                    caught = error
                    receipt["error"] = dict(type=type(error).__name__, code="connection_cleanup_failed")
                elif not isinstance(error, Exception) and isinstance(caught, Exception):
                    caught = error
        receipt["cleanup_clock"] = "clock_gettime(CLOCK_MONOTONIC)"
        receipt["connection_close_system_monotonic_ns"] = time.clock_gettime_ns(time.CLOCK_MONOTONIC)
        try:
            retained = (out / "response.sse").read_bytes()
            if len(retained) != captured_bytes or hashlib.sha256(retained).hexdigest() != capture_hash.hexdigest():
                raise OSError("Capture differs from received bytes")
        except OSError as error:
            receipt["capture_complete"] = False
            receipt["capture_error"] = type(error).__name__
            if caught is None:
                caught = error
                receipt["error"] = dict(type=type(error).__name__, code="capture_verification_failed")
        measurement = observation.content_summary(elapsed, declared_prompt_tokens, caught is None)
        receipt["measurement"] = measurement
        receipt["response_sha256"] = capture_hash.hexdigest()
        receipt["captured_response_bytes"] = captured_bytes
        if caught is not None:
            receipt["status"] = "no_content" if error_code == "no_content" else "failed"
        else:
            passed = measurement["content_sla"]["reported_prompt_tokens"]["request_passed"]
            receipt["status"] = "completed" if passed else "content_deadline_missed"
        write_json(out / "receipt.json", receipt)
    if caught is not None and not isinstance(caught, Exception):
        raise caught
    return receipt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--endpoint", required=True)
    parser.add_argument("--model", required=True, help="Exact installed public model ID")
    parser.add_argument("--prompt-file", required=True, type=Path)
    parser.add_argument("--token-file", required=True, type=Path, help="Owned regular 0600 bearer-token file")
    parser.add_argument("--output", required=True, type=Path, help="New private result directory")
    parser.add_argument("--timeout", default=120, type=float)
    parser.add_argument("--declared-prompt-tokens", type=int, help="Optional caller assertion, separate from server usage")
    args = parser.parse_args()
    try:
        receipt = run(args.endpoint, args.model, args.prompt_file, args.token_file,
                      args.output, args.timeout, args.declared_prompt_tokens)
    except Exception as error:
        print(json.dumps(dict(status="failed_before_receipt", error_type=type(error).__name__)))
        return 1
    print(json.dumps(dict(status=receipt["status"], measurement=receipt["measurement"],
                          receipt=str(args.output / "receipt.json")), allow_nan=False))
    return 0 if receipt["status"] == "completed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
