from contextlib import contextmanager, redirect_stderr, redirect_stdout
from datetime import datetime, timedelta, timezone
import io
import json
import os
from pathlib import Path
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import tempfile
import threading
import unittest
from unittest.mock import patch

from .cli import main
from .http_probe import Client, Result, TestProbe, validate_base_url
from .test_observer import BUILD, model


@contextmanager
def server(reply="STARTUP_OK", redirect=None):
    calls = []

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def respond(self, status, body):
            encoded = json.dumps(body).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(encoded)))
            self.end_headers()
            self.wfile.write(encoded)

        def do_GET(self):
            calls.append(("GET", self.path, None, self.headers.get("Authorization")))
            if self.path == "/health":
                self.respond(200, {"status": "ok", "build_commit": BUILD, "private": "response-secret"})
            elif self.path == "/readyz":
                self.respond(200, {"ready": True, "draining": False})
            elif self.path == "/v1/models/capacity":
                self.respond(200, {"models": [model("m1")]})
            else:
                self.respond(401, {"error": "response-secret"})

        def do_POST(self):
            body = self.rfile.read(int(self.headers["Content-Length"]))
            calls.append(("POST", self.path, body, self.headers.get("Authorization")))
            if redirect:
                self.send_response(307)
                self.send_header("Location", redirect)
                self.send_header("Content-Length", "0")
                self.end_headers()
            else:
                self.respond(200, {"model": "m1", "choices": [{"finish_reason": "stop", "message": {"content": reply}}],
                                   "usage": {"prompt_tokens": 99}, "private": "response-secret"})

    httpd = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=httpd.serve_forever, daemon=True)
    thread.start()
    try:
        yield f"http://127.0.0.1:{httpd.server_port}", calls
    finally:
        httpd.shutdown()
        httpd.server_close()
        thread.join()


class HTTPProbeTests(unittest.TestCase):
    def arguments(self, origin, output):
        began = datetime.now(timezone.utc) - timedelta(seconds=1)
        return ["--base-url", origin, "--expected-build-commit", BUILD, "--model", "m1",
                "--process-started-at", began.isoformat(), "--duration", "3", "--output", str(output)]

    def test_default_cli_only_gets_and_reports_inference_unverified(self):
        with server() as (origin, calls), tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "result.json"
            console = io.StringIO()
            with redirect_stdout(console), patch.dict(os.environ, {"SYNTHETIC_KEY": "key-secret"}):
                self.assertEqual(0, main(self.arguments(origin, output)))
            report = json.loads(output.read_text())
            self.assertFalse(report["inference_verified"])
            self.assertEqual("not_measured", report["correctness"])
            self.assertEqual(["GET", "GET", "GET"], [method for method, *_ in calls])
            self.assertTrue(all(auth is None for *_, auth in calls))
            self.assertEqual(0o600, output.stat().st_mode & 0o777)
            self.assertNotIn("response-secret", output.read_text() + console.getvalue())
            self.assertNotIn("key-secret", output.read_text() + console.getvalue())

    def test_inference_requires_config_and_reports_only_booleans(self):
        with server(reply="different-synthetic-answer") as (origin, calls), tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / "test.json"
            config.write_text(json.dumps({"environment": "disposable-test", "base_url": origin, "api_key_env": "SYNTHETIC_KEY"}))
            output = Path(directory) / "result.json"
            args = self.arguments(origin, output) + ["--allow-test-inference", "--test-inference-config", str(config)]
            with patch.dict(os.environ, {"SYNTHETIC_KEY": "key-secret"}), redirect_stdout(io.StringIO()):
                self.assertEqual(3, main(args))
            report = json.loads(output.read_text())
            self.assertTrue(report["inference_verified"])
            self.assertEqual("failed", report["correctness"])
            self.assertEqual(1, sum(method == "POST" for method, *_ in calls))
            post = next(call for call in calls if call[0] == "POST")
            self.assertEqual("Bearer key-secret", post[3])
            self.assertEqual("m1", json.loads(post[2])["model"])
            for private in ("key-secret", "response-secret", "different-synthetic-answer", "prompt_tokens", "messages"):
                self.assertNotIn(private, output.read_text())

    def test_unpaired_opt_in_is_rejected_before_network(self):
        with server() as (origin, calls), tempfile.TemporaryDirectory() as directory:
            for extra in (["--allow-test-inference"], ["--test-inference-config", "missing.json"]):
                with self.assertRaises(SystemExit), redirect_stderr(io.StringIO()):
                    main(self.arguments(origin, Path(directory) / "result.json") + extra)
            self.assertEqual([], calls)

    def test_known_production_and_wrong_targets_refused(self):
        with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {"SYNTHETIC_KEY": "key-secret"}):
            config = Path(directory) / "test.json"
            for origin in ("https://api.darkbloom.dev", "https://api.darkbloom.dev."):
                config.write_text(json.dumps({"environment": "disposable-test", "base_url": origin, "api_key_env": "SYNTHETIC_KEY"}))
                with self.assertRaises(ValueError):
                    TestProbe.from_file(config, origin)
            config.write_text(json.dumps({"environment": "disposable-test", "base_url": "http://127.0.0.1:1111", "api_key_env": "SYNTHETIC_KEY"}))
            with self.assertRaises(ValueError):
                TestProbe.from_file(config, "http://127.0.0.1:2222")

    def test_redirect_cannot_forward_test_credentials(self):
        with server() as (destination, destination_calls), server(redirect=destination + "/v1/chat/completions") as (origin, _):
            result = TestProbe("key-secret").run(Client(origin), "m1", 1)
            self.assertEqual(307, result["status"])
            self.assertFalse(result["availability_success"])
            self.assertEqual([], destination_calls)

    def test_errors_do_not_emit_bodies(self):
        with server() as (origin, _):
            result = Client(origin).request("/unknown", 1)
            self.assertEqual(401, result.status)
            self.assertNotIn("response-secret", json.dumps(result.public()))

    def test_partial_empty_error_and_wrong_model_responses_are_not_success(self):
        responses = [
            {}, {"error": "private-error"},
            {"model": "m1", "choices": [{"message": {"content": "STARTUP_OK"}}]},
            {"model": "m1", "choices": [{"finish_reason": "stop", "message": {"content": ""}}]},
            {"model": "other", "choices": [{"finish_reason": "stop", "message": {"content": "STARTUP_OK"}}]},
        ]
        for body in responses:
            class Stub:
                def request(self, *args, **kwargs):
                    return Result(200, "json", body)
            self.assertFalse(TestProbe("key-secret").run(Stub(), "m1", 1)["availability_success"])

    def test_complete_correct_inference_is_measured_without_content(self):
        with server() as (origin, _):
            result = TestProbe("key-secret").run(Client(origin), "m1", 1)
            self.assertTrue(result["availability_success"])
            self.assertTrue(result["synthetic_answer_matches"])
            self.assertNotIn("STARTUP_OK", json.dumps(result))

    def test_response_size_is_bounded_and_body_is_discarded(self):
        class HugeResponse:
            code = 200
            closed = False

            def read1(self, size):
                return b"x" * size

            def close(self):
                self.closed = True

        response = HugeResponse()
        client = Client("http://127.0.0.1:9000")
        with patch.object(client.opener, "open", return_value=response):
            result = client.request("/health", 1)
        self.assertEqual("response_too_large", result.outcome)
        self.assertIsNone(result.body)
        self.assertTrue(response.closed)

    def test_invalid_header_secret_cannot_reach_http_library_errors(self):
        client = Client("http://127.0.0.1:9000")
        with patch.object(client.opener, "open") as open_request:
            result = client.request("/v1/chat/completions", 1, api_key="key-secret\x00", payload={})
        open_request.assert_not_called()
        self.assertNotIn("key-secret", json.dumps(result.public()))
        self.assertEqual("invalid_credentials", result.outcome)

    def test_origins_reject_credentials_and_query_secrets(self):
        for origin in ("https://user:secret@example.com", "https://example.com?token=secret", "https://example.com/path", "https://example.com#secret"):
            with self.assertRaises(ValueError):
                validate_base_url(origin)


if __name__ == "__main__":
    unittest.main()
