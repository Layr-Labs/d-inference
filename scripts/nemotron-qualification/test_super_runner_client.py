"""CPU-only checks of the runner client: SSE timing math, abort accounting,
launch cleanup, diagnostics connections, workload parsing, percentiles and the
PNG generator. No runner or GPU."""
import http.client
import http.server
import importlib.util
import json
from pathlib import Path
import signal
import struct
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock
import zlib

sys.dont_write_bytecode = True
_spec = importlib.util.spec_from_file_location(
    "super_runner_client", Path(__file__).resolve().parent / "super_runner_client.py")
client = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(client)


class _SSEHandler(http.server.BaseHTTPRequestHandler):
    deltas = 5
    delay = 0.02

    def do_POST(self):
        length = int(self.headers["Content-Length"])
        body = json.loads(self.rfile.read(length))
        assert self.headers["Authorization"] == "Bearer token"
        assert body["stream"] and body["stream_options"] == {"include_usage": True}
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        try:
            for index in range(self.deltas):
                time.sleep(self.delay)
                self._event({"choices": [{"index": 0, "delta": {"content": "x"}}]})
            self._event({"choices": [{"index": 0, "delta": {}, "finish_reason": "length"}],
                         "usage": {"prompt_tokens": 40, "completion_tokens": self.deltas,
                                   "prompt_tokens_details": {"cached_tokens": 0}}})
            self.wfile.write(b"data: [DONE]\n\n")
        except (BrokenPipeError, ConnectionResetError):
            pass

    def _event(self, value):
        self.wfile.write(b"data: " + json.dumps(value).encode() + b"\n\n")
        self.wfile.flush()

    def log_message(self, *args):
        pass


class StreamChatTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), _SSEHandler)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        cls.url = f"http://127.0.0.1:{cls.server.server_address[1]}"

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()

    def test_rates_follow_usage_and_delta_times(self):
        result = client.stream_chat(self.url, "token", {"model": "m", "messages": []})
        self.assertEqual(result["status"], 200)
        self.assertIsNone(result["error"])
        self.assertTrue(result["done"])
        self.assertEqual((result["prompt_tokens"], result["completion_tokens"]), (40, 5))
        self.assertEqual(result["delta_count"], 5)
        self.assertFalse(result["aborted"])
        self.assertAlmostEqual(result["prefill_tokens_per_s"], 40 / result["ttft_s"])
        span = result["last_delta_s"] - result["first_delta_s"]
        self.assertAlmostEqual(result["decode_tokens_per_s"], 4 / span)
        self.assertAlmostEqual(result["e2e_output_tokens_per_s"], 5 / result["total_s"])

    def test_abort_on_first_delta_is_recorded(self):
        abort = client.AbortHandle()
        result = client.stream_chat(self.url, "token", {"model": "m", "messages": []},
                                    abort=abort, on_first_delta=abort.abort)
        self.assertTrue(result["aborted"])
        self.assertIsNone(result["error"])
        self.assertEqual(result["delta_count"], 1)

    def test_non_loopback_endpoint_is_refused(self):
        with self.assertRaises(client.RunnerError):
            client.stream_chat("http://example.invalid:80", "token", {})


class LaunchTests(unittest.TestCase):
    """A launched runner lives in its own session: a failed launch must stop it."""

    def _launch_unready(self, script, **launch):
        """Launch ``script`` as a runner that never writes its ready file."""
        launched = []
        popen = subprocess.Popen

        def recording_popen(*args, **kwargs):
            launched.append(popen(*args, **kwargs))
            return launched[-1]

        with tempfile.TemporaryDirectory() as work, \
                mock.patch.object(client.subprocess, "Popen", recording_popen):
            with self.assertRaises(client.RunnerError):
                client.Runner.launch_process([sys.executable, "-c", script], work, **launch)
        self.assertEqual(len(launched), 1)
        return launched[0]

    def test_unready_runner_is_interrupted_and_reaped(self):
        process = self._launch_unready("import time; time.sleep(60)", timeout=0.5)
        self.assertIsNotNone(process.returncode, "the runner was left running")
        self.assertNotEqual(process.returncode, -signal.SIGKILL)

    def test_runner_ignoring_the_interrupt_is_killed_and_reaped(self):
        script = "import signal, time; signal.signal(signal.SIGINT, signal.SIG_IGN); time.sleep(60)"
        process = self._launch_unready(script, timeout=2.0, abort_timeout=0.2)
        self.assertEqual(process.returncode, -signal.SIGKILL)

    def test_runner_exiting_before_ready_reports_its_code(self):
        with tempfile.TemporaryDirectory() as work:
            with self.assertRaisesRegex(client.RunnerError, "exited with 3 before ready"):
                client.Runner.launch_process([sys.executable, "-c", "raise SystemExit(3)"], work)


class _MalformedStatusHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        # http.client closes its own connection only for connection errors.
        self.wfile.write(b"not an HTTP status line\r\n")
        self.close_connection = True

    def log_message(self, *args):
        pass


class DiagnosticsTests(unittest.TestCase):
    def test_connection_is_closed_when_the_request_fails(self):
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), _MalformedStatusHandler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        closed = []

        class RecordingConnection(http.client.HTTPConnection):
            def close(self):
                closed.append(self)
                super().close()

        with tempfile.TemporaryDirectory() as state:
            token = Path(state, "token")
            token.write_text("token")
            url = f"http://127.0.0.1:{server.server_address[1]}"
            Path(state, client.READY_FILE).write_text(json.dumps({
                "base_url": url, "diagnostics_url": url, "auth_token_file": str(token),
                "events_file": str(Path(state, client.EVENTS_FILE))}))
            runner = client.Runner(state)
            with mock.patch.object(client.http.client, "HTTPConnection", RecordingConnection):
                with self.assertRaises(http.client.HTTPException):
                    runner.status()
        self.assertEqual(len(closed), 1)


class HelperTests(unittest.TestCase):
    def test_percentiles_interpolate_between_ranks(self):
        self.assertEqual(client.percentile([4, 1, 3, 2], 0.5), 2.5)
        self.assertAlmostEqual(client.percentile([1, 2, 3, 4], 0.9), 3.7)
        self.assertIsNone(client.percentile([None], 0.5))
        self.assertEqual(client.summarize([]), {"n": 0})

    def test_workload_parsing(self):
        self.assertEqual(client.parse_contexts("short=128,long=15360"), {"short": 128, "long": 15360})
        self.assertEqual(client.parse_images("512x512,2048X1536"), [(512, 512), (2048, 1536)])

    def test_png_is_rgb8_with_valid_crcs(self):
        data = client.png_rgb(33, 17, seed=5)
        self.assertEqual(data[:8], b"\x89PNG\r\n\x1a\n")
        offset, chunks = 8, {}
        while offset < len(data):
            (length,) = struct.unpack(">I", data[offset:offset + 4])
            kind = data[offset + 4:offset + 8]
            payload = data[offset + 8:offset + 8 + length]
            (crc,) = struct.unpack(">I", data[offset + 8 + length:offset + 12 + length])
            self.assertEqual(crc, zlib.crc32(kind + payload))
            chunks[kind] = payload
            offset += 12 + length
        width, height, depth, color = struct.unpack(">IIBB", chunks[b"IHDR"][:10])
        self.assertEqual((width, height, depth, color), (33, 17, 8, 2))
        self.assertEqual(len(zlib.decompress(chunks[b"IDAT"])), height * (1 + 3 * width))
        self.assertEqual(client.png_rgb(33, 17, seed=5), data)


if __name__ == "__main__":
    unittest.main()
