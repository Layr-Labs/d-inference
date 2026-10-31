#!/usr/bin/env python3
"""Self-test for loadgen.py against a tiny local stub server; no model needed.

Run: python3 scripts/benchmarks/cluster/test_loadgen.py

The stub counts prompt tokens as (words in the messages + 7), waits
prompt_tokens / PREFILL_TPS, then streams max_tokens one-token frames at
DECODE_TPS and finishes with a usage frame and [DONE]. The checks compare what
the generator records with what the stub was told to do, and check the
aggregation arithmetic on hand-made records with exact expected values.
"""

from __future__ import annotations

import contextlib
import io
import json
import sys
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import loadgen  # noqa: E402

PREFILL_TPS = 4000.0
DECODE_TPS = 200.0
OVERHEAD_TOKENS = 7


class Stub(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    in_flight = 0
    max_in_flight = 0
    seen_prompts = []
    guard = threading.Lock()

    def log_message(self, *_):
        pass

    def handle(self):
        try:
            super().handle()
        except (ConnectionResetError, BrokenPipeError):
            pass  # the client closes its connection after every request

    def do_GET(self):
        body = b"stub_requests_total 1\n" if self.path == "/metrics" else b"{}"
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def frame(self, payload):
        data = payload if isinstance(payload, str) else json.dumps(payload)
        chunk = f"data: {data}\n\n".encode()
        self.wfile.write(f"{len(chunk):x}\r\n".encode() + chunk + b"\r\n")
        self.wfile.flush()

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        model = request["model"]
        text = " ".join(message["content"] for message in request["messages"])
        prompt_tokens = len(text.split()) + OVERHEAD_TOKENS
        with Stub.guard:
            Stub.in_flight += 1
            Stub.max_in_flight = max(Stub.max_in_flight, Stub.in_flight)
            Stub.seen_prompts.append(text)
        try:
            if model == "stub-503":
                body = json.dumps({"error": {"message": "overloaded"}}).encode()
                self.send_response(503)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            started = time.perf_counter()
            self.frame({"choices": [{"index": 0, "delta": {"role": "assistant"}}]})
            if model == "stub-sse-error":
                self.frame({"error": {"message": "engine failed"}})
                self.wfile.write(b"0\r\n\r\n")
                return
            count = 5 if model == "stub-early-stop" else request["max_tokens"]
            for index in range(count):
                due = started + prompt_tokens / PREFILL_TPS + index / DECODE_TPS
                time.sleep(max(0.0, due - time.perf_counter()))
                self.frame({"choices": [{"index": 0, "delta": {"content": "tok "}}]})
                if model == "stub-truncate" and index == 2:
                    self.wfile.write(b"0\r\n\r\n")
                    return
            reason = "stop" if model == "stub-early-stop" else "length"
            self.frame({"choices": [{"index": 0, "delta": {}, "finish_reason": reason}]})
            self.frame({"choices": [], "usage": {
                "prompt_tokens": prompt_tokens, "completion_tokens": count,
                "total_tokens": prompt_tokens + count,
                "engine": {"prefill_tokens_per_second": PREFILL_TPS, "decode_tokens_per_second": DECODE_TPS}}})
            self.frame("[DONE]")
            self.wfile.write(b"0\r\n\r\n")
        finally:
            with Stub.guard:
                Stub.in_flight -= 1


class LoadgenTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), Stub)
        cls.server.daemon_threads = True
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()
        cls.base = f"http://127.0.0.1:{cls.server.server_address[1]}"
        cls.endpoint = loadgen.Endpoint(cls.base)
        cls.prompts = loadgen.Prompts(loadgen.DEFAULT_TEXT.read_text())

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()

    def setUp(self):
        Stub.max_in_flight = 0
        Stub.seen_prompts = []

    # ---- arithmetic, exact

    def test_percentile_is_nearest_rank(self):
        values = [5, 1, 4, 2, 3]
        self.assertEqual(loadgen.percentile(values, 0.50), 3)
        self.assertEqual(loadgen.percentile(values, 0.95), 5)
        self.assertEqual(loadgen.percentile(list(range(1, 101)), 0.95), 95)
        self.assertEqual(loadgen.percentile([7], 0.95), 7)
        self.assertIsNone(loadgen.percentile([], 0.5))

    def test_rates_and_summary_on_hand_made_records(self):
        def record(prompt, output, first, last, total, ok=True, warmup=False):
            return loadgen.derive({"ok": ok, "warmup": warmup, "http_status": 200 if ok else 503,
                                   "error": None if ok else "http 503", "finish_reason": "length" if ok else None,
                                   "prompt_tokens": prompt, "completion_tokens": output, "first_token_s": first,
                                   "first_content_s": first, "last_token_s": last, "total_s": total,
                                   "server": {"usage.engine.decode_tokens_per_second": 50.0} if ok else {}})
        records = [
            record(1000, 101, 0.5, 2.5, 2.6),                # prefill 2000, decode 100/2 = 50
            record(1000, 101, 1.0, 5.0, 5.1),                # prefill 1000, decode 25
            record(1000, 101, 0.25, 1.25, 1.3),              # prefill 4000, decode 100
            record(1000, 101, 9.0, 9.9, 10.0, warmup=True),  # discarded
            record(None, None, None, None, 0.1, ok=False),   # failure
        ]
        self.assertEqual(records[0]["client_prefill_tps"], 2000.0)
        self.assertEqual(records[0]["client_decode_tps"], 50.0)
        summary = loadgen.summarize(records, wall_seconds=10.0)
        self.assertEqual((summary["requests"], summary["ok"], summary["failed"]), (4, 3, 1))
        self.assertEqual(summary["failures"], ["http 503"])
        self.assertEqual(summary["finish_reasons"], {"length": 3})
        self.assertEqual(summary["client_prefill_tps"]["p50"], 2000.0)
        self.assertEqual(summary["client_prefill_tps"]["p95"], 4000.0)
        self.assertEqual(summary["client_decode_tps"]["p50"], 50.0)
        self.assertEqual(summary["client_decode_tps"]["min"], 25.0)
        self.assertEqual(summary["first_token_s"]["p50"], 0.5)
        self.assertEqual(summary["first_token_s"]["p95"], 1.0)
        self.assertEqual(summary["aggregate_output_tokens_per_second"], 30.3)
        self.assertEqual(summary["aggregate_prompt_tokens_per_second"], 300.0)
        self.assertEqual(summary["server"]["usage.engine.decode_tokens_per_second"]["p50"], 50.0)

    def test_single_token_answer_has_no_decode_rate(self):
        record = loadgen.derive({"prompt_tokens": 10, "completion_tokens": 1,
                                 "first_token_s": 0.1, "last_token_s": 0.1})
        self.assertIsNone(record["client_decode_tps"])
        self.assertEqual(record["client_prefill_tps"], 100.0)

    def test_minute_buckets(self):
        records = [{"ok": True, "finished_at_s": 10, "completion_tokens": 10, "prompt_tokens": 100,
                    "client_decode_tps": 40.0, "client_prefill_tps": 900.0, "first_token_s": 0.2},
                   {"ok": False, "finished_at_s": 50},
                   {"ok": True, "finished_at_s": 61, "completion_tokens": 20, "prompt_tokens": 200,
                    "client_decode_tps": 30.0, "client_prefill_tps": 800.0, "first_token_s": 0.3}]
        rows = loadgen.minute_buckets(records)
        self.assertEqual([(row["bucket"], row["requests"], row["failed"], row["output_tokens"]) for row in rows],
                         [(0, 2, 1, 10), (1, 1, 0, 20)])
        self.assertEqual(rows[1]["client_decode_tps_p50"], 30.0)

    # ---- against the stub

    def test_prompts_are_deterministic_and_nonce_differs(self):
        first = self.prompts.messages(50, 1)[0]["content"]
        self.assertEqual(first, self.prompts.messages(50, 1)[0]["content"])
        self.assertNotEqual(first, self.prompts.messages(50, 2)[0]["content"])
        self.assertEqual(len(first.split()), len(self.prompts.messages(50, 2)[0]["content"].split()))

    def test_calibration_hits_the_server_token_count(self):
        for target in (64, 1024, 4096):
            entry = loadgen.calibrate(self.endpoint, "stub", self.prompts, target)
            self.assertTrue(entry["within_tolerance"], entry)
            self.assertLessEqual(abs(entry["prompt_tokens"] - target), max(2, int(target * 0.002)))
            words = len(self.prompts.messages(entry["words"], 0)[0]["content"].split())
            self.assertEqual(words + OVERHEAD_TOKENS, entry["prompt_tokens"])

    def test_one_request_is_recorded_as_the_stub_served_it(self):
        body = loadgen.request_body("stub", self.prompts.messages(793, 1), 40)
        record = loadgen.run_request(self.endpoint, body)
        self.assertTrue(record["ok"], record["error"])
        prompt_tokens = len(body["messages"][0]["content"].split()) + OVERHEAD_TOKENS
        self.assertEqual((record["http_status"], record["finish_reason"]), (200, "length"))
        self.assertEqual((record["prompt_tokens"], record["completion_tokens"]), (prompt_tokens, 40))
        self.assertEqual(record["content_frames"], 40)
        expected_first = prompt_tokens / PREFILL_TPS
        self.assertGreaterEqual(record["first_token_s"], expected_first)
        self.assertLess(record["first_token_s"], expected_first + 0.15)
        self.assertEqual(record["first_token_s"], record["first_content_s"])
        self.assertAlmostEqual(record["client_decode_tps"], DECODE_TPS, delta=DECODE_TPS * 0.2)
        self.assertLessEqual(record["last_token_s"], record["total_s"])
        self.assertEqual(record["server"]["usage.engine.decode_tokens_per_second"], DECODE_TPS)
        self.assertEqual(record["text_head"], "tok " * 20)

    def test_failures_become_records(self):
        cases = {"stub-503": ("http 503", 503), "stub-truncate": ("incomplete stream", 200),
                 "stub-sse-error": ("sse error", 200)}
        for model, (message, status) in cases.items():
            record = loadgen.run_request(self.endpoint, loadgen.request_body(model, self.prompts.messages(5, 1), 8))
            self.assertFalse(record["ok"], model)
            self.assertIn(message, record["error"])
            self.assertEqual(record["http_status"], status)
        refused = loadgen.run_request(loadgen.Endpoint("http://127.0.0.1:9"),
                                      loadgen.request_body("stub", self.prompts.messages(5, 1), 8))
        self.assertFalse(refused["ok"])
        self.assertIsNone(refused["http_status"])

    def test_early_stop_is_ok_and_reports_its_reason(self):
        record = loadgen.run_request(self.endpoint,
                                     loadgen.request_body("stub-early-stop", self.prompts.messages(5, 1), 64))
        self.assertTrue(record["ok"])
        self.assertEqual((record["finish_reason"], record["completion_tokens"]), ("stop", 5))

    def test_cells_concurrency_warmup_and_soak_end_to_end(self):
        with tempfile.TemporaryDirectory() as folder:
            calibration = Path(folder) / "calibration.json"
            status = loadgen.main(["--base-url", self.base, "--model", "stub", "--output", folder,
                                   "--label", "run", "--cell", "64:16:1:3", "--cell", "512:16:4:8",
                                   "--warmup", "1", "--calibration", str(calibration),
                                   "--soak-seconds", "1.5", "--soak-mix", "64,512", "--soak-output", "8",
                                   "--soak-concurrency", "2", "--sample-command", "echo sample",
                                   "--sample-every", "0.5"])
            self.assertEqual(status, 0)
            report = json.loads((Path(folder) / "run.summary.json").read_text())
            records = [json.loads(line) for line in (Path(folder) / "run.requests.jsonl").read_text().splitlines()]
            first, second = report["cells"]
            self.assertEqual((first["requests"], first["ok"], first["warmup_requests"]), (3, 3, 1))
            self.assertEqual((second["requests"], second["ok"], second["concurrency"]), (8, 8, 4))
            self.assertEqual(Stub.max_in_flight, 4)
            self.assertEqual(sum(1 for record in records if record["warmup"]), 2)
            self.assertEqual(first["completion_tokens"]["p50"], 16)
            self.assertLessEqual(abs(first["prompt_tokens"]["p50"] - 64), 2)
            self.assertLessEqual(abs(second["prompt_tokens"]["p50"] - 512), 2)
            # four workers at 16 tokens each: aggregate rate is between one and four streams' worth
            self.assertGreater(second["aggregate_output_tokens_per_second"], DECODE_TPS * 1.5)
            soak = report["soak"]
            self.assertGreater(soak["ok"], 4)
            self.assertEqual(soak["failed"], 0)
            self.assertEqual(sorted(soak["by_size"]), ["512", "64"])
            self.assertEqual(sum(row["requests"] for row in soak["buckets"]), soak["requests"])
            # every measured prompt is unique (per-request number), so no cache can answer it
            prompts = [prompt for prompt in Stub.seen_prompts]
            measured = len(records)
            self.assertGreaterEqual(len(set(prompts)), measured)
            # a second run with another label uses other prompt numbers
            self.assertEqual(loadgen.main(["--base-url", self.base, "--model", "stub", "--output", folder,
                                           "--label", "run-two", "--cell", "64:16:1:3", "--warmup", "0",
                                           "--calibration", str(calibration)]), 0)
            self.assertEqual(len(set(Stub.seen_prompts)), len(Stub.seen_prompts))
            self.assertNotEqual(report["nonce_base"],
                                json.loads((Path(folder) / "run-two.summary.json").read_text())["nonce_base"])
            stored = json.loads(calibration.read_text())
            self.assertEqual(sorted(stored["targets"], key=int), ["64", "512"])
            samples = (Path(folder) / "run.samples.jsonl").read_text().splitlines()
            self.assertGreaterEqual(len(samples), 3)
            self.assertEqual(json.loads(samples[0])["tag"], "before")
            self.assertTrue((Path(folder) / "run.metrics.jsonl").exists())
            # a second run with the same label refuses to overwrite
            with self.assertRaises(SystemExit), contextlib.redirect_stderr(io.StringIO()):
                loadgen.main(["--base-url", self.base, "--model", "stub", "--output", folder,
                              "--label", "run", "--cell", "64:16:1:1"])

    def test_failed_cell_sets_the_exit_status(self):
        with tempfile.TemporaryDirectory() as folder:
            calibration = Path(folder) / "calibration.json"
            calibration.write_text(json.dumps({"model": "stub-503", "text_sha256": self.prompts.text_sha256,
                                               "instruction": self.prompts.instruction,
                                               "targets": {"64": {"words": 40, "prompt_tokens": 64}}}))
            status = loadgen.main(["--base-url", self.base, "--model", "stub-503", "--output", folder,
                                   "--label", "bad", "--cell", "64:8:1:2", "--warmup", "0",
                                   "--calibration", str(calibration), "--metrics-path", ""])
            self.assertEqual(status, 1)
            report = json.loads((Path(folder) / "bad.summary.json").read_text())
            self.assertEqual((report["cells"][0]["ok"], report["cells"][0]["failed"]), (0, 2))
            self.assertEqual(report["cells"][0]["http_statuses"], [503])


if __name__ == "__main__":
    unittest.main(verbosity=2)
