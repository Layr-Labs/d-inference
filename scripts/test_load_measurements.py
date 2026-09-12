"""CPU-only load-driver lifecycle and latency fixtures; no inference requests."""
import asyncio
from contextlib import redirect_stdout
import csv
import importlib.util
import io
from pathlib import Path
import sys
import tempfile
import threading
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import load_soak


class SoakTests(unittest.TestCase):
    def test_final_csv_accounts_for_requests_completed_after_deadline(self):
        started = threading.Event()
        finish = threading.Event()
        stop = threading.Event()
        clock = SimpleNamespace(now=0)
        original_stop = stop.set

        def tick(timeout):
            self.assertTrue(started.wait(5), "worker did not start")
            clock.now += timeout

        def stop_admission():
            original_stop()
            finish.set()

        def request(args, number, stats, pool):
            started.set()
            # Complete only after admission has stopped, with no timed sleep.
            if not finish.wait(5):
                raise AssertionError("admission did not stop before request drain")
            clock.now += 0.1
            stats.record_ok(0.4, 0.4, 7)

        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "soak.csv"
            args = ["--model", "fixture", "--duration-minutes", "0.005", "--concurrency", "1",
                    "--report-every-seconds", "0.05", "--out", str(output)]
            with patch.object(load_soak, "do_request", side_effect=request), \
                 patch.object(load_soak, "threading", SimpleNamespace(Event=lambda: stop, Lock=threading.Lock)), \
                 patch.object(stop, "wait", side_effect=tick), \
                 patch.object(stop, "set", side_effect=stop_admission), \
                 patch.object(load_soak.time, "monotonic", side_effect=lambda: clock.now), redirect_stdout(io.StringIO()):
                self.assertEqual(0, load_soak.main(args))
            self.assertTrue(started.is_set())
            with output.open() as source:
                rows = list(csv.DictReader(source))
            self.assertEqual(1, sum(int(row["ok"]) for row in rows))
            self.assertEqual(1, int(rows[-1]["cum_ok"]))
            self.assertEqual(0, int(rows[-1]["cum_err"]))

    def test_cumulative_counts_belong_to_the_same_snapshot(self):
        stats = load_soak.Stats()
        stats.record_ok(1, 2, 7)
        stats.record_err("http_503")
        first = stats.snapshot_and_reset(2)
        stats.record_ok(3, 4, 11)
        second = stats.snapshot_and_reset(2)
        self.assertEqual((1, 1, 1, 1), (first["ok"], first["err"], first["cum_ok"], first["cum_err"]))
        self.assertEqual((1, 0, 2, 1), (second["ok"], second["err"], second["cum_ok"], second["cum_err"]))
        self.assertEqual({"http_503": 1}, first["err_kinds"])
        self.assertEqual({}, second["err_kinds"])
        self.assertEqual(3.5, first["tok_per_s"])
        self.assertEqual(5.5, second["tok_per_s"])

    def test_interrupt_stops_admission_before_executor_drains(self):
        stop = threading.Event()

        def interrupt(timeout):
            raise KeyboardInterrupt

        class Executor:
            def __init__(self, **kwargs):
                pass
            def __enter__(self):
                return self
            def submit(self, worker):
                return SimpleNamespace(result=lambda: None)
            def __exit__(inner, *args):
                self.assertTrue(stop.is_set(), "executor drain must follow admission stop")

        with tempfile.TemporaryDirectory() as directory:
            with patch.object(load_soak, "threading", SimpleNamespace(Event=lambda: stop, Lock=threading.Lock)), \
                 patch.object(stop, "wait", side_effect=interrupt), \
                 patch.object(load_soak, "ThreadPoolExecutor", Executor), redirect_stdout(io.StringIO()):
                result = load_soak.main(["--model", "fixture", "--out", str(Path(directory) / "soak.csv")])
            self.assertEqual(1, result)


class LightBenchmarkTests(unittest.TestCase):
    def test_success_latency_includes_response_body(self):
        clock = SimpleNamespace(now=0)

        class Response:
            status = 200
            async def __aenter__(self):
                clock.now = 1  # headers available
                return self
            async def json(self):
                clock.now = 5  # complete JSON body available
                return {"usage": {"completion_tokens": 20}}
            async def __aexit__(self, *args):
                # Stop this continuous worker after exactly one stub response.
                raise asyncio.CancelledError

        class Session:
            async def __aenter__(self):
                return self
            async def __aexit__(self, *args):
                pass
            def post(self, *args, **kwargs):
                self_payload = kwargs["json"]
                assert self_payload["max_tokens"] == 200
                return Response()

        aiohttp = SimpleNamespace(ClientSession=Session, ClientTimeout=lambda **kwargs: kwargs)
        path = Path(__file__).with_name("benchmark-light.py")
        spec = importlib.util.spec_from_file_location("benchmark_light_fixture", path)
        module = importlib.util.module_from_spec(spec)
        with patch.dict(sys.modules, {"aiohttp": aiohttp}), patch.dict("os.environ", {"DARKBLOOM_API_KEY": "fixture-key"}):
            spec.loader.exec_module(module)
        output = io.StringIO()
        with patch.object(module.time, "monotonic", side_effect=lambda: clock.now), redirect_stdout(output):
            with self.assertRaises(asyncio.CancelledError):
                asyncio.run(module.worker(1, "fixture", "fixture prompt"))
        self.assertIn("5.0s, 20 tok, 4.0 tok/s", output.getvalue())
        self.assertNotIn("fixture-key", output.getvalue())


if __name__ == "__main__":
    unittest.main()
