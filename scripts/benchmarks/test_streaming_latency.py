"""Client timing and failure tests against controlled SSE, never a model."""

from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import io
import json
from pathlib import Path
import tempfile
import threading
import time
import unittest
from unittest.mock import Mock, patch

from benchmark_streaming import run
from streaming_latency import StreamObservation, receive_events


def frame(delta=None, finish=None, usage=None):
    value = dict(choices=[] if delta is None else [dict(index=0, delta=delta, finish_reason=finish)])
    if usage is not None:
        value["usage"] = usage
    return ("data: " + json.dumps(value) + "\r\n\r\n").encode()


@contextmanager
def server(chunks, status=200):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def do_POST(self):
            self.rfile.read(int(self.headers["Content-Length"]))
            self.send_response(status)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Set-Cookie", "private-cookie")
            self.end_headers()
            try:
                for delay, data in chunks:
                    time.sleep(delay)
                    self.wfile.write(data)
                    self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                pass
    httpd = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=httpd.serve_forever, daemon=True)
    thread.start()
    try:
        yield "http://127.0.0.1:%d/v1/chat/completions" % httpd.server_port
    finally:
        httpd.shutdown()
        httpd.server_close()
        thread.join(2)


class StreamTests(unittest.TestCase):
    def request(self, endpoint, timeout=3, prompt_tokens=8192):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        root = Path(tmp.name)
        path = root / "request.json"
        path.write_text(json.dumps(dict(model="test-fixture", messages=[dict(role="user", content="Hi")],
                                        stream=True, max_tokens=128, stream_options=dict(include_usage=True))))
        with patch.dict("os.environ", {"DARKBLOOM_API_KEY": "test-secret-key"}):
            result = run(endpoint, path, root / "result", timeout, prompt_tokens, "local-fixture")
        self.assertNotIn("test-secret-key", (root / "result/receipt.json").read_text())
        self.assertNotIn("private-cookie", (root / "result/receipt.json").read_text())
        return result, root / "result"

    def test_client_waits_for_text_and_keeps_separate_content_clock(self):
        usage = dict(prompt_tokens=8195, completion_tokens=17)
        chunks = [(0, b": heartbeat\r\n\r\n" + frame(dict(role="assistant", content=""))),
                  (.08, frame(dict(reasoning_content="Thinking"))),
                  (.04, frame(dict(content="Hello"))),
                  (0, frame({}, "stop") + frame(usage=usage) + b"data: [DONE]\r\n\r\n")]
        with server(chunks) as endpoint:
            receipt, out = self.request(endpoint)
        self.assertEqual(receipt["status"], "completed")
        result = receipt["measurement"]
        self.assertGreater(result["ttft_ns"], 60_000_000)
        self.assertLess(result["ttft_ns"], 2_000_000_000)
        self.assertEqual(result["ttft_ns"], result["first_reasoning_ns"])
        self.assertGreater(result["first_content_ns"], result["ttft_ns"])
        self.assertEqual(result["usage"], usage)
        self.assertEqual(result["text_events"], 2)  # not 17 tokens
        self.assertIsNone(result["engine_decode_tps"])
        self.assertEqual(result["sla"]["reported_prompt_tokens"]["deadline_ns"], 18_195_000_000)
        self.assertEqual(result["sla"]["declared_prompt_tokens"]["deadline_ns"], 18_192_000_000)
        self.assertEqual((out / "response.sse").read_bytes(), b"".join(data for _, data in chunks))

    def test_trickle_is_bounded_by_total_timeout_and_retains_partial(self):
        with server([(.03, b": heartbeat\n\n")] * 30) as endpoint:
            receipt, out = self.request(endpoint, timeout=.14)
        self.assertEqual(receipt["status"], "failed")
        self.assertEqual(receipt["error"]["type"], "TimeoutError")
        self.assertLess(receipt["measurement"]["elapsed_ns"], 700_000_000)
        self.assertFalse(receipt["measurement"]["sla"]["declared_prompt_tokens"]["request_passed"])
        self.assertTrue((out / "response.sse").read_bytes())

    def test_partial_output_failure_is_not_a_successful_sla_request(self):
        with server([(0, frame(dict(content="Hello"))), (0, b'data: {"error":{"message":"fixture"}}\n\n')]) as endpoint:
            receipt, out = self.request(endpoint)
        self.assertEqual(receipt["status"], "failed")
        self.assertIsNotNone(receipt["measurement"]["ttft_ns"])
        self.assertFalse(receipt["measurement"]["sla"]["declared_prompt_tokens"]["request_passed"])
        self.assertIn(b'"error"', (out / "response.sse").read_bytes())

    def test_http_error_is_retained_without_following_redirect(self):
        with server([(0, b"redirect fixture")], status=302) as endpoint:
            receipt, out = self.request(endpoint)
        self.assertEqual(receipt["http_status"], 302)
        self.assertEqual(receipt["status"], "failed")
        self.assertEqual((out / "response.sse").read_bytes(), b"redirect fixture")

    def test_parser_multiline_and_truncation(self):
        retained = []
        wire = b': ping\n\ndata: {"choices":\r\ndata: []}\r\n\r\n'
        events = list(receive_events(io.BytesIO(wire), lambda: 123, lambda raw, elapsed: retained.append(raw)))
        self.assertEqual(json.loads(events[0][0]), {"choices": []})
        self.assertEqual(events[0][1], 123)
        self.assertEqual(b"".join(retained), wire)
        with self.assertRaisesRegex(ValueError, "Truncated"):
            list(receive_events(io.BytesIO(b'data: {}\n'), lambda: 123, lambda *args: None))

    def test_deadline_boundary_does_not_round_into_a_pass(self):
        value = StreamObservation()
        value.accept(json.dumps(dict(choices=[dict(delta=dict(content="x"))])), 18_192_000_001)
        value.accept(json.dumps(dict(choices=[dict(delta={}, finish_reason="stop")])), 18_193_000_000)
        value.accept("[DONE]", 18_194_000_000)
        result = value.summary(18_195_000_000, 8192)
        sla = result["sla"]["declared_prompt_tokens"]
        self.assertEqual(sla["first_token_margin_ns"], -1)
        self.assertFalse(sla["request_passed"])
        self.assertIsNone(result["usage"])

    def test_failure_after_terminal_withholds_request_pass(self):
        value = StreamObservation()
        value.accept(json.dumps(dict(choices=[dict(delta=dict(content="x"), finish_reason="stop")])), 12)
        value.accept("[DONE]", 15)
        result = value.summary(20, 8192, request_succeeded=False)
        self.assertTrue(result["complete"])
        self.assertFalse(result["sla"]["declared_prompt_tokens"]["request_passed"])

    def test_invalid_nonfinite_usage_keeps_failure_receipt(self):
        wire = frame(dict(content="x"), "stop") + b'data: {"choices":[],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":NaN}}\n\n'
        with server([(0, wire)]) as endpoint:
            receipt, out = self.request(endpoint)
        self.assertEqual(receipt["status"], "failed")
        self.assertIsNone(receipt["measurement"]["usage"])
        self.assertTrue((out / "receipt.json").exists())
        with self.assertRaisesRegex(ValueError, "Duplicate"):
            StreamObservation().accept('{"choices":[],"choices":[]}', 0)
        with self.assertRaisesRegex(ValueError, "Nonfinite"):
            StreamObservation().accept('{"choices":[],"usage":{"prompt_tokens":1,"completion_tokens":1,"extra":1e999}}', 0)

    def test_tool_and_error_terminals_are_not_text_success(self):
        for delta, finish in [(dict(function_call=dict(name="fixture")), None), ({}, "error"), ({}, "tool_calls")]:
            with self.subTest(delta=delta, finish=finish), self.assertRaises(ValueError):
                StreamObservation().accept(json.dumps(dict(choices=[dict(delta=delta, finish_reason=finish)])), 0)

    def test_connection_close_failure_retains_completed_stream_but_fails_request(self):
        response = io.BytesIO(frame(dict(content="x"), "stop") + b'data: [DONE]\n\n')
        response.status = 200
        response.getheaders = lambda: [("Content-Type", "text/event-stream")]
        response.getheader = lambda *args: "text/event-stream"
        connection = Mock()
        connection.getresponse.return_value = response
        connection.close.side_effect = OSError("fixture close failure")
        with patch("benchmark_streaming.http.client.HTTPConnection", return_value=connection):
            receipt, out = self.request("http://127.0.0.1:1/v1/chat/completions")
        self.assertEqual(receipt["status"], "failed")
        self.assertEqual(receipt["cleanup_error"], "OSError")
        self.assertTrue(receipt["measurement"]["complete"])
        self.assertFalse(receipt["measurement"]["sla"]["declared_prompt_tokens"]["request_passed"])
        self.assertTrue((out / "receipt.json").exists())


if __name__ == "__main__":
    unittest.main()
