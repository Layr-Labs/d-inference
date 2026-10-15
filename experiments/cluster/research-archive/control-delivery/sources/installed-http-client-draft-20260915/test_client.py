"""Local fake HTTP only. Timed delays verify clock boundaries, not performance."""

from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import io
import os
from pathlib import Path
import tempfile
import threading
import time
import unittest
from unittest.mock import Mock, patch

from client import run
from client_inputs import inputs
from client_observation import ContentObservation


SECRET = "fixture-secret-0123456789"
MODEL = "fixture-public-model"


def event(content=None, reasoning=None, finish=None, usage=None, **overrides):
    delta = {}
    if content is not None:
        delta["content"] = content
    if reasoning is not None:
        delta["reasoning_content"] = reasoning
    value = dict(id="chatcmpl-fixture", object="chat.completion.chunk", created=1, model=MODEL,
                 choices=[dict(index=0, delta=delta, finish_reason=finish)])
    if usage is not None:
        value["usage"] = usage
    value.update(overrides)
    return ("data: " + json.dumps(value) + "\r\n\r\n").encode()


USAGE = dict(prompt_tokens=23, completion_tokens=128, total_tokens=151)
DONE = b"data: [DONE]\r\n\r\n"


@contextmanager
def server(chunks, status=200):
    requests = []

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def do_POST(self):
            body = self.rfile.read(int(self.headers["Content-Length"]))
            requests.append((self.path, self.headers.get("Authorization"), json.loads(body)))
            self.send_response(status)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Connection", "close")
            self.end_headers()
            try:
                for delay, data in chunks:
                    time.sleep(delay)
                    self.wfile.write(data)
                    self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                pass

    httpd = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    httpd.daemon_threads = True
    thread = threading.Thread(target=httpd.serve_forever, daemon=True)
    thread.start()
    try:
        yield "http://127.0.0.1:%s/v1/chat/completions" % httpd.server_port, requests
    finally:
        httpd.shutdown()
        httpd.server_close()
        thread.join(2)


class ClientTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.prompt = self.root / "prompt.txt"
        self.prompt.write_text("Describe a cache in two sentences.\n")
        self.token = self.root / "token"
        self.token.write_text(SECRET + "\n")
        self.token.chmod(0o600)

    def request(self, chunks, status=200, timeout=2):
        with server(chunks, status) as (endpoint, requests):
            receipt = run(endpoint, MODEL, self.prompt, self.token,
                          self.root / "result", timeout, 23)
        for path in (self.root / "result").iterdir():
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertNotIn(SECRET.encode(), path.read_bytes())
        self.assertEqual((self.root / "result").stat().st_mode & 0o777, 0o700)
        return receipt, requests

    def test_content_clock_and_supported_request_are_exact(self):
        chunks = [(0, event()), (.035, event(reasoning="planning")),
                  (.04, event(content="A cache stores results.")),
                  (0, event(finish="length", usage=USAGE) + DONE)]
        receipt, requests = self.request(chunks)
        self.assertEqual(receipt["status"], "completed")
        measurement = receipt["measurement"]
        self.assertEqual(measurement["ttft_ns"], measurement["first_content_ns"])
        self.assertLess(measurement["first_reasoning_ns"], measurement["ttft_ns"])
        self.assertGreater(measurement["ttft_ns"], 50_000_000)
        self.assertEqual(measurement["usage"], USAGE)
        self.assertTrue(measurement["reported_output_is_128"])
        self.assertTrue(measurement["content_sla"]["reported_prompt_tokens"]["request_passed"])
        self.assertEqual(len(requests), 1)
        path, auth, request = requests[0]
        self.assertEqual(path, "/v1/chat/completions")
        self.assertEqual(auth, "Bearer " + SECRET)
        self.assertEqual(request, dict(model=MODEL, messages=[dict(role="user", content=self.prompt.read_text())],
            stream=True, stream_options=dict(include_usage=True), max_tokens=128,
            temperature=0, top_p=1, top_k=0, repetition_penalty=1,
            presence_penalty=0, frequency_penalty=0, enable_thinking=False, reasoning_parser="qwen3"))
        self.assertEqual((self.root / "result/response.sse").read_bytes(), b"".join(v for _, v in chunks))
        self.assertFalse(receipt["native_retirement_verified"])

    def test_reasoning_only_128_is_explicit_no_content(self):
        receipt, _ = self.request([(0, event(reasoning="reasoning only")),
                                   (0, event(finish="length", usage=USAGE) + DONE)])
        self.assertEqual(receipt["status"], "no_content")
        m = receipt["measurement"]
        self.assertTrue(m["stream_terminal_complete"])
        self.assertIsNone(m["ttft_ns"])
        self.assertIsNotNone(m["first_reasoning_ns"])
        self.assertEqual(m["usage"]["completion_tokens"], 128)
        self.assertFalse(m["content_sla"]["reported_prompt_tokens"]["request_passed"])

    def test_absolute_timeout_includes_keepalive_trickle(self):
        receipt, _ = self.request([(.025, b": heartbeat\n\n")] * 25, timeout=.13)
        self.assertEqual(receipt["status"], "failed")
        self.assertEqual(receipt["error"]["code"], "absolute_timeout")
        self.assertLess(receipt["measurement"]["elapsed_ns"], 700_000_000)
        self.assertGreater(receipt["captured_response_bytes"], 0)

    def test_http_failure_retains_body_and_never_redirects(self):
        receipt, requests = self.request([(0, b'{"error":"fixture refusal"}')], status=503)
        self.assertEqual(receipt["http_status"], 503)
        self.assertEqual(receipt["error"]["code"], "http_error")
        self.assertEqual(len(requests), 1)
        self.assertIn(b"fixture refusal", (self.root / "result/response.sse").read_bytes())

    def test_truncated_stream_retains_partial_content_and_fails(self):
        receipt, _ = self.request([(0, event(content="partial")), (0, b'data: {"choices":')])
        self.assertEqual(receipt["status"], "failed")
        self.assertIsNotNone(receipt["measurement"]["first_content_ns"])
        self.assertFalse(receipt["measurement"]["content_sla"]["declared_prompt_tokens"]["request_passed"])

    def test_buffered_record_after_done_is_rejected(self):
        receipt, _ = self.request([(0, event(content="x", finish="length", usage=USAGE) + DONE + event(content="late"))])
        self.assertEqual(receipt["status"], "failed")

    def test_usage_required_even_when_stream_has_content_and_terminal(self):
        receipt, _ = self.request([(0, event(content="x", finish="stop") + DONE)])
        self.assertEqual(receipt["error"]["code"], "missing_usage")
        self.assertEqual(receipt["status"], "failed")

    def test_credential_echo_does_not_enter_artifacts(self):
        receipt, _ = self.request([(0, SECRET.encode())], status=500)
        self.assertEqual(receipt["error"]["code"], "credential_echo_capture_refused")
        self.assertFalse(receipt["capture_complete"])

    def test_private_token_and_input_guards_precede_network(self):
        self.token.chmod(0o644)
        with self.assertRaises(ValueError):
            inputs("http://127.0.0.1:1/v1/chat/completions", MODEL, self.prompt, self.token, 120, None)
        self.token.chmod(0o600)
        alias = self.root / "alias"
        alias.symlink_to(self.token)
        with self.assertRaises(OSError):
            inputs("http://127.0.0.1:1/v1/chat/completions", MODEL, self.prompt, alias, 120, None)
        for endpoint, timeout, count in [("http://user:password@example.invalid/v1/chat/completions",120,None),
                                         ("http://127.0.0.1:1/v1/completions",120,None),
                                         ("http://127.0.0.1:1/v1/chat/completions",301,None),
                                         ("http://127.0.0.1:1/v1/chat/completions",120,True)]:
            with self.assertRaises(ValueError):
                inputs(endpoint, MODEL, self.prompt, self.token, timeout, count)

    def test_precise_content_deadline_and_malformed_usage(self):
        o = ContentObservation(MODEL)
        o.accept(event(reasoning="x").decode()[6:].strip(), 1)
        o.accept(event(content="x", finish="length", usage=USAGE).decode()[6:].strip(), 10_023_000_001)
        o.accept("[DONE]", 10_024_000_000)
        m = o.content_summary(10_025_000_000, 8192, True)
        self.assertEqual(m["content_sla"]["reported_prompt_tokens"]["content_margin_ns"], -1)
        self.assertFalse(m["content_sla"]["reported_prompt_tokens"]["request_passed"])
        self.assertTrue(m["content_sla"]["declared_prompt_tokens"]["request_passed"])
        for usage in [dict(prompt_tokens=True, completion_tokens=128, total_tokens=129),
                      dict(prompt_tokens=23, completion_tokens=129, total_tokens=152),
                      dict(prompt_tokens=23, completion_tokens=128, total_tokens=150)]:
            with self.assertRaises(ValueError):
                ContentObservation(MODEL).accept(event(content="x", usage=usage).decode()[6:].strip(), 1)
        for wire in [event(content=False), event(content="x", model="other"),
                     event(content="x", choices=[dict(index=False, delta={})])]:
            with self.assertRaises(ValueError):
                ContentObservation(MODEL).accept(wire.decode()[6:].strip(), 1)

    def response_fixture(self, usage=USAGE):
        response = io.BytesIO(event(content="x", finish="length", usage=usage) + DONE)
        response.status = 200
        response.getheader = lambda *args: "text/event-stream"
        connection = Mock()
        connection.getresponse.return_value = response
        return response, connection

    def test_response_close_failure_still_closes_connection_and_fails(self):
        response, connection = self.response_fixture()
        response.close = Mock(side_effect=OSError("fixture cleanup"))
        with patch("client.http.client.HTTPConnection", return_value=connection):
            receipt = run("http://127.0.0.1:1/v1/chat/completions", MODEL, self.prompt,
                          self.token, self.root / "result")
        connection.close.assert_called_once()
        self.assertEqual(receipt["status"], "failed")
        self.assertTrue(receipt["measurement"]["stream_terminal_complete"])
        self.assertFalse(receipt["measurement"]["content_sla"]["reported_prompt_tokens"]["request_passed"])
        io.BytesIO.close(response)

    def test_operator_interrupt_survives_cleanup_and_receipt(self):
        response, connection = self.response_fixture()
        response.close = Mock(side_effect=KeyboardInterrupt())
        connection.close.side_effect = OSError("secondary cleanup")
        with patch("client.http.client.HTTPConnection", return_value=connection), self.assertRaises(KeyboardInterrupt):
            run("http://127.0.0.1:1/v1/chat/completions", MODEL, self.prompt,
                self.token, self.root / "result")
        connection.close.assert_called_once()
        receipt = json.loads((self.root / "result/receipt.json").read_text())
        self.assertEqual(receipt["status"], "failed")
        self.assertEqual(receipt["cleanup_errors"], ["KeyboardInterrupt", "OSError"])
        io.BytesIO.close(response)

    def test_8k_content_deadline_miss_is_retained_as_miss(self):
        response, connection = self.response_fixture(dict(prompt_tokens=8192, completion_tokens=128, total_tokens=8320))
        ticks = iter([0, 0, 1, 18_192_000_000, 18_192_000_001,
                      18_192_000_002, 18_192_000_003, 18_192_000_004, 18_192_000_005])
        with patch("client.http.client.HTTPConnection", return_value=connection), \
                patch("client.time.monotonic_ns", side_effect=lambda: next(ticks)):
            receipt = run("http://127.0.0.1:1/v1/chat/completions", MODEL, self.prompt,
                          self.token, self.root / "result")
        self.assertEqual(receipt["status"], "content_deadline_missed")
        self.assertEqual(receipt["measurement"]["usage"]["prompt_tokens"], 8192)
        self.assertEqual(receipt["measurement"]["ttft_ns"], 18_192_000_001)


if __name__ == "__main__":
    unittest.main()
