"""Actual loopback HTTP only; fabricated streams, no model or remote machine."""

from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import http.client
import json
from pathlib import Path
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

from cancel_client import run
from client_inputs import private_file


SECRET = "fixture-secret-0123456789"
MODEL = "fixture-public-model"


def event(content=None, reasoning=None, finish=None, **extra):
    delta = {}
    if content is not None: delta["content"] = content
    if reasoning is not None: delta["reasoning_content"] = reasoning
    value = dict(id="chatcmpl-cancel-fixture", object="chat.completion.chunk", model=MODEL,
                 choices=[dict(index=0, delta=delta, finish_reason=finish)])
    value.update(extra)
    return ("data: " + json.dumps(value) + "\r\n\r\n").encode()


@contextmanager
def server(chunks, header_delay=0, status=200):
    requests, errors = [], []
    eof = threading.Event()
    finished = threading.Event()

    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"
        def log_message(self, *args): pass
        def do_POST(self):
            try:
                body = self.rfile.read(int(self.headers["Content-Length"]))
                requests.append((self.path, self.headers.get("Authorization"), json.loads(body)))
                time.sleep(header_delay)
                self.send_response(status)
                self.send_header("Content-Type", "text/event-stream")
                self.send_header("Connection", "close")
                self.end_headers()
                for delay, data in chunks:
                    time.sleep(delay)
                    self.wfile.write(data); self.wfile.flush()
                self.connection.settimeout(1)
                if self.connection.recv(1) == b"": eof.set()
            except (BrokenPipeError, ConnectionResetError):
                # Also an actual kernel observation that this test transport
                # was closed, not a native/owner retirement assertion.
                eof.set()
            except Exception as error:
                errors.append(type(error).__name__)
            finally:
                finished.set()

    httpd = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    httpd.daemon_threads = True
    thread = threading.Thread(target=lambda: httpd.serve_forever(poll_interval=.01), daemon=True)
    thread.start()
    try:
        yield "http://127.0.0.1:%s/v1/chat/completions" % httpd.server_port, requests, eof, errors
    finally:
        finished.wait(2)
        httpd.shutdown(); httpd.server_close(); thread.join(2)


class CancellationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.prompt = self.root / "prompt.txt"; self.prompt.write_text("Describe a cache.\n")
        self.token = self.root / "token"; self.token.write_text(SECRET + "\n"); self.token.chmod(0o600)

    def request(self, chunks, mode="after-two-content", timeout=1, delay=.05, **options):
        with server(chunks, **options) as (endpoint, requests, eof, errors):
            receipt = run(endpoint, MODEL, self.prompt, self.token, self.root / "result",
                          mode, timeout, delay, 23)
            self.assertTrue(eof.wait(2), "fake peer must observe actual transport closure")
        self.assertEqual(errors, [])
        self.assertEqual((self.root / "result").stat().st_mode & 0o777, 0o700)
        for path in (self.root / "result").iterdir():
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertNotIn(SECRET.encode(), path.read_bytes())
        return receipt, requests

    def test_two_content_events_exclude_role_reasoning_and_empty(self):
        chunks = [(0, event()), (.01, event(reasoning="private reasoning")),
                  (.01, event(content="first ")), (0, event(content="")),
                  (.01, event(content="second"))]
        receipt, requests = self.request(chunks)
        self.assertEqual(receipt["status"], "disconnected")
        self.assertEqual(receipt["observation"]["nonempty_content_events"], 2)
        self.assertIsNone(receipt["observation"]["usage"])
        self.assertFalse(receipt["observation"]["terminal_usage_required"])
        self.assertFalse(receipt["whole_response_captured"])
        self.assertFalse(receipt["native_retirement_verified"])
        self.assertFalse(receipt["external_sla_qualified"])
        self.assertEqual(json.loads((self.root / "result/prefix.json").read_text()),
                         dict(content="first second", reasoning="private reasoning"))
        times = receipt["observation"]["content_event_times_ns"]
        self.assertLessEqual(times[0], times[1])
        self.assertLessEqual(times[1], receipt["disconnect_trigger_ns"])
        self.assertLessEqual(receipt["disconnect_trigger_ns"], receipt["connection_close_returned_ns"])
        self.assertEqual((self.root / "result/response.sse").read_bytes(), b"".join(data for _, data in chunks))
        path, auth, body = requests[0]
        self.assertEqual(path, "/v1/chat/completions"); self.assertEqual(auth, "Bearer " + SECRET)
        self.assertEqual(body["enable_thinking"], False)
        self.assertEqual(body["reasoning_parser"], "qwen3")
        self.assertEqual(body["max_tokens"], 128)
        self.assertEqual((body["temperature"], body["top_p"], body["top_k"]), (0, 1, 0))

    def test_before_content_shutdown_interrupts_partial_sse_line(self):
        receipt, _ = self.request([(0, event()), (0, b'data: {"partial":')], mode="before-content")
        self.assertEqual(receipt["status"], "disconnected")
        self.assertEqual(receipt["phase_observed"], "headers_without_content")
        self.assertEqual(receipt["observation"]["nonempty_content_events"], 0)
        self.assertGreaterEqual(receipt["disconnect_trigger_ns"] - receipt["post_submitted_ns"], 40_000_000)
        self.assertLess(receipt["connection_close_returned_ns"], 600_000_000)
        self.assertIn(b'"partial":', (self.root / "result/response.sse").read_bytes())

    def test_before_response_headers_is_explicit_phase(self):
        receipt, _ = self.request([], mode="before-content", header_delay=.15)
        self.assertEqual(receipt["status"], "disconnected")
        self.assertEqual(receipt["phase_observed"], "before_response_headers")
        self.assertIsNone(receipt["http_status"])

    def test_content_beating_timer_is_failed_phase_not_success(self):
        receipt, _ = self.request([(0, event(content="too soon"))], mode="before-content", delay=.2)
        self.assertEqual(receipt["status"], "failed")
        self.assertEqual(receipt["error"]["code"], "content_arrived_before_planned_disconnect")
        self.assertIsNone(receipt["disconnect_trigger_ns"])

    def test_normal_finish_before_two_events_is_not_cancellation(self):
        receipt, _ = self.request([(0, event(content="one", finish="stop"))])
        self.assertEqual(receipt["status"], "failed")
        self.assertEqual(receipt["error"]["code"], "stream_finished_before_disconnect")

    def test_wrong_identity_is_not_masked_as_disconnect(self):
        receipt, _ = self.request([(0, event(content="x", model="wrong"))])
        self.assertEqual(receipt["status"], "failed")
        self.assertFalse(receipt["requested_disconnect_observed"])

    def test_absolute_timeout_trickling_stream_still_closes_socket(self):
        receipt, _ = self.request([(.015, b": heartbeat\n\n")] * 10, timeout=.08, delay=.02)
        self.assertEqual(receipt["status"], "failed")
        self.assertEqual(receipt["error"]["code"], "absolute_timeout")
        self.assertLess(receipt["connection_close_returned_ns"], 600_000_000)

    def test_http_refusal_does_not_become_success(self):
        receipt, _ = self.request([], status=503)
        self.assertEqual(receipt["status"], "failed")
        self.assertEqual(receipt["error"]["code"], "http_error")

    def test_credential_echo_is_not_written(self):
        receipt, _ = self.request([(0, event(content=SECRET))])
        self.assertEqual(receipt["error"]["code"], "credential_echo_capture_refused")

    def test_connection_cleanup_failure_is_retained(self):
        actual = http.client.HTTPConnection
        class FailingClose(actual):
            close_count = 0
            def close(self):
                super().close()
                self.close_count += 1
                if self.close_count >= 2:
                    raise OSError("fabricated close failure")
        with patch("cancel_client.http.client.HTTPConnection", FailingClose):
            receipt, _ = self.request([(0, event(content="a")), (0, event(content="b"))])
        self.assertEqual(receipt["status"], "failed")
        self.assertIn("OSError", receipt["cleanup_errors"])

    def test_invalid_private_file_fails_before_any_connection(self):
        self.token.chmod(0o644)
        with patch("cancel_client.http.client.HTTPConnection") as connection, self.assertRaises(ValueError):
            run("http://127.0.0.1:1/v1/chat/completions", MODEL, self.prompt, self.token,
                self.root / "result", "before-content")
        connection.assert_not_called()

    def test_capture_close_failure_after_disconnect_is_not_network_interruption(self):
        @contextmanager
        def failing_file(path):
            with private_file(path) as file:
                yield file
            if path.name == "response.sse":
                raise OSError("fabricated capture close error")
        with patch("cancel_client.private_file", failing_file):
            receipt, _ = self.request([(0, event(content="a")), (0, event(content="b"))])
        self.assertEqual(receipt["status"], "failed")
        self.assertEqual(receipt["error"]["code"], "request_failed")
        self.assertIsNotNone(receipt["disconnect_trigger_ns"])

    def test_operator_interrupt_during_cleanup_survives_receipt(self):
        actual = http.client.HTTPConnection
        class InterruptedClose(actual):
            close_count = 0
            def close(self):
                super().close()
                self.close_count += 1
                if self.close_count >= 2:
                    raise KeyboardInterrupt()
        with server([(0, event(content="a")), (0, event(content="b"))]) as (endpoint, _, eof, _):
            with patch("cancel_client.http.client.HTTPConnection", InterruptedClose), self.assertRaises(KeyboardInterrupt):
                run(endpoint, MODEL, self.prompt, self.token, self.root / "result", "after-two-content")
            self.assertTrue(eof.wait(2))
        receipt = json.loads((self.root / "result/receipt.json").read_text())
        self.assertEqual(receipt["status"], "failed")
        self.assertEqual(receipt["cleanup_errors"], ["KeyboardInterrupt"])


if __name__ == "__main__":
    unittest.main()
