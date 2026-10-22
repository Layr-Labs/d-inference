#!/usr/bin/env python3
"""Intentionally close one bounded chat stream; this does not prove retirement."""

import argparse
from datetime import datetime, timezone
import hashlib
import http.client
import json
import math
from pathlib import Path
import time

from cancel_transport import PlannedDisconnect
from client_inputs import inputs, private_file, write_json
from client_observation import ContentObservation
from client_timeout import absolute_timeout
from streaming_latency import receive_events, strict_json


class CancelOutcome(ValueError):
    pass


def run(endpoint, model, prompt_file, token_file, output, mode, timeout=90,
        cancel_after_seconds=0.5, declared_prompt_tokens=None):
    url, secret, prompt, encoded = inputs(endpoint, model, prompt_file, token_file,
                                         timeout, declared_prompt_tokens)
    if mode not in ("before-content", "after-two-content"):
        raise ValueError("Unknown disconnect mode")
    if (type(cancel_after_seconds) not in (int, float)
            or not math.isfinite(cancel_after_seconds)
            or not 0 < cancel_after_seconds <= 30 or cancel_after_seconds >= timeout):
        raise ValueError("Disconnect delay must be positive, <=30s and less than request timeout")
    out = Path(output)
    out.mkdir(mode=0o700, parents=True, exist_ok=False)
    with private_file(out / "request.json") as file:
        file.write(encoded)
    receipt = dict(schema="installed_http_intentional_disconnect_v1", mode=mode,
        endpoint=endpoint, model=model, started_at_utc=datetime.now(timezone.utc).isoformat(),
        timeout_seconds=timeout, cancel_after_post_seconds=cancel_after_seconds if mode == "before-content" else None,
        request_sha256=hashlib.sha256(encoded).hexdigest(),
        prompt_utf8_sha256=hashlib.sha256(prompt).hexdigest(),
        request_origin="client monotonic immediately before HTTP POST, including connect/TLS",
        disconnect_origin="delay starts after HTTPConnection.request returned; content events use complete SSE delimiter receipt",
        content_events_are_token_count=False, native_retirement_verified=False,
        owner_release_verified=False, server_cancellation_verified=False,
        external_sla_qualified=False, performance_qualified=False,
        error=None, http_status=None, body_eof_observed=False, whole_response_captured=False)
    headers = {"Content-Type": "application/json", "Accept": "text/event-stream",
               "Accept-Encoding": "identity", "Authorization": "Bearer " + secret.decode("ascii")}
    cls = http.client.HTTPSConnection if url.scheme == "https" else http.client.HTTPConnection
    connection = cls(url.hostname, url.port, timeout=timeout)
    response = disconnect = None
    observation = ContentObservation(model)
    content, reasoning, content_times = [], [], []
    prefix_bytes = 0
    start = time.monotonic_ns()
    caught = None
    network_wait = False
    capture_hash = hashlib.sha256()
    captured_bytes = line_count = 0
    try:
        with private_file(out / "response.sse") as raw, private_file(out / "arrivals.jsonl") as arrivals:
            def retain(data, elapsed):
                nonlocal captured_bytes, line_count
                if secret in data:
                    raise CancelOutcome("credential_echo_capture_refused")
                line_count += 1
                if line_count > 4096:
                    raise CancelOutcome("capture_line_limit")
                try:
                    raw.write(data)
                    arrivals.write((json.dumps(dict(offset=captured_bytes, bytes=len(data), elapsed_ns=elapsed)) + "\n").encode())
                except OSError as error:
                    raise CancelOutcome("capture_write_failed") from error
                captured_bytes += len(data)
                capture_hash.update(data)

            with absolute_timeout(timeout):
                start = time.monotonic_ns()
                receipt["request_start_monotonic_ns"] = start
                connection.request("POST", url.path, body=encoded, headers=headers)
                receipt["post_submitted_ns"] = time.monotonic_ns() - start
                disconnect = PlannedDisconnect(connection.sock, start)
                if mode == "before-content":
                    disconnect.arm(cancel_after_seconds)
                network_wait = True
                response = connection.getresponse()
                network_wait = False
                receipt["headers_received_ns"] = time.monotonic_ns() - start
                receipt["http_status"] = response.status
                if response.status != 200:
                    raise CancelOutcome("http_error")
                if response.getheader("Content-Type", "").split(";", 1)[0].strip().lower() != "text/event-stream":
                    raise CancelOutcome("wrong_content_type")
                stream = iter(receive_events(response, lambda: time.monotonic_ns() - start,
                                             retain, maximum_bytes=8 * 1024 * 1024))
                while True:
                    network_wait = True
                    try:
                        payload, received = next(stream)
                    except StopIteration:
                        network_wait = False
                        receipt["body_eof_observed"] = True
                        break
                    network_wait = False
                    observation.accept(payload, received)
                    if payload != "[DONE]":
                        for choice in strict_json(payload).get("choices", []):
                            delta = choice["delta"]
                            c = delta.get("content") or ""
                            r = delta.get("reasoning_content", delta.get("reasoning")) or ""
                            prefix_bytes += len(c.encode()) + len(r.encode())
                            if prefix_bytes > 512 * 1024:
                                raise CancelOutcome("text_prefix_limit")
                            if c:
                                content.append(c); content_times.append(received)
                            if r:
                                reasoning.append(r)
                    if mode == "before-content" and content_times:
                        raise CancelOutcome("content_arrived_before_planned_disconnect")
                    if observation.finish_reason is not None or observation.done:
                        raise CancelOutcome("stream_finished_before_disconnect")
                    if mode == "after-two-content" and len(content_times) == 2:
                        disconnect.fire()
                        break
                if disconnect.trigger_ns is None:
                    raise CancelOutcome("stream_ended_before_disconnect")
    except BaseException as error:
        # A planned shutdown may interrupt a blocked read/header operation or
        # expose an unfinished SSE event. Other protocol/identity errors remain
        # failures even when the timer also happened to fire.
        expected_interruption = (isinstance(error, OSError) and not isinstance(error, TimeoutError)) or isinstance(error, http.client.IncompleteRead) or (type(error) is ValueError and str(error) == "Truncated SSE event")
        if network_wait and disconnect is not None and disconnect.trigger_ns is not None and expected_interruption:
            receipt["read_interrupted_after_disconnect_type"] = type(error).__name__
        else:
            caught = error
            receipt["error"] = dict(type=type(error).__name__, code=(str(error) if isinstance(error, CancelOutcome)
                else "absolute_timeout" if isinstance(error, TimeoutError) else "request_failed"))
    finally:
        # Join timer before closing the referenced socket/response. Each close
        # is attempted independently; an operator interruption stays primary.
        cleanup = ([disconnect] if disconnect is not None else []) + [response, connection]
        for owned in cleanup:
            if owned is None:
                continue
            try:
                owned.stop() if owned is disconnect else owned.close()
            except BaseException as error:
                receipt.setdefault("cleanup_errors", []).append(type(error).__name__)
                if caught is None or (not isinstance(error, Exception) and isinstance(caught, Exception)):
                    caught = error
                if receipt["error"] is None:
                    receipt["error"] = dict(type=type(error).__name__, code="connection_cleanup_failed")
        receipt["connection_close_returned_ns"] = time.monotonic_ns() - start
        # macOS Python 3.9's time.monotonic epoch is process-relative. Keep
        # request elapsed values above, but hand off an explicit OS clock to
        # the parent process observing cleanup on this same machine.
        receipt["cleanup_clock"] = "clock_gettime(CLOCK_MONOTONIC)"
        receipt["connection_close_system_monotonic_ns"] = time.clock_gettime_ns(time.CLOCK_MONOTONIC)
        receipt["disconnect_trigger_ns"] = None if disconnect is None else disconnect.trigger_ns
        receipt["socket_shutdown_error"] = None if disconnect is None else disconnect.shutdown_error
        try:
            retained = (out / "response.sse").read_bytes()
            if len(retained) != captured_bytes or hashlib.sha256(retained).hexdigest() != capture_hash.hexdigest():
                raise OSError("Capture differs from retained prefix")
            joined_content, joined_reasoning = "".join(content), "".join(reasoning)
            if secret in joined_content.encode() or secret in joined_reasoning.encode():
                raise CancelOutcome("credential_echo_prefix_refused")
            write_json(out / "prefix.json", dict(content=joined_content, reasoning=joined_reasoning))
            receipt["retained_prefix_verified"] = True
        except Exception as error:
            receipt["retained_prefix_verified"] = False
            if caught is None:
                caught = error
                receipt["error"] = dict(type=type(error).__name__, code="capture_verification_failed")
        target = (disconnect is not None and disconnect.trigger_ns is not None
                  and disconnect.shutdown_error is None and not receipt.get("cleanup_errors")
                  and (not content_times if mode == "before-content" else len(content_times) == 2)
                  and observation.finish_reason is None and not observation.done)
        receipt["requested_disconnect_observed"] = target and caught is None
        receipt["phase_observed"] = ("two_nonempty_content_events" if len(content_times) == 2 else
            "content_before_requested_phase" if content_times else
            "reasoning_without_content" if observation.first_reasoning_ns is not None else
            "headers_without_content" if receipt["http_status"] is not None else "before_response_headers")
        receipt["observation"] = dict(first_content_ns=observation.first_content_ns,
            first_reasoning_ns=observation.first_reasoning_ns, content_event_times_ns=content_times,
            nonempty_content_events=len(content_times), sse_events=observation.event_count,
            finish_reason=observation.finish_reason, done=observation.done, usage=observation.usage,
            declared_prompt_tokens=declared_prompt_tokens, terminal_usage_required=False)
        receipt["response_sha256"] = capture_hash.hexdigest()
        receipt["captured_response_bytes"] = captured_bytes
        receipt["status"] = "disconnected" if receipt["requested_disconnect_observed"] else "failed"
        write_json(out / "receipt.json", receipt)
    if caught is not None and not isinstance(caught, Exception):
        raise caught
    return receipt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("endpoint", "model", "prompt-file", "token-file", "output"):
        parser.add_argument("--" + name, required=True)
    parser.add_argument("--mode", required=True, choices=("before-content", "after-two-content"))
    parser.add_argument("--timeout", type=float, default=90)
    parser.add_argument("--cancel-after-seconds", type=float, default=0.5)
    parser.add_argument("--declared-prompt-tokens", type=int)
    args = parser.parse_args()
    try:
        receipt = run(args.endpoint, args.model, args.prompt_file, args.token_file, args.output,
                      args.mode, args.timeout, args.cancel_after_seconds, args.declared_prompt_tokens)
    except Exception as error:
        print(json.dumps(dict(status="failed_before_receipt", error_type=type(error).__name__)))
        return 1
    print(json.dumps({key: receipt[key] for key in ("status", "mode", "phase_observed", "requested_disconnect_observed")}), flush=True)
    return 0 if receipt["status"] == "disconnected" else 1


if __name__ == "__main__":
    raise SystemExit(main())
