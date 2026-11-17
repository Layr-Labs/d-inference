import email.message
import http.client
import json
import io
import os
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import urllib.request
import urllib.response

import gptoss_replay as r

METRICS = '\n'.join([
    'kv_backend_info{model="gpt-oss-20b",backend="paged"} 1',
    'prefix_cache_status{model="gpt-oss-20b",state="ready",reason="ready"} 1',
    'mtp_active{model="gpt-oss-20b"} 0',
    'kv_active_requests{model="gpt-oss-20b"} 0',
    'kv_waiting_requests{model="gpt-oss-20b"} 0'])
BUILD_OPENER = urllib.request.build_opener


def case(name="hit"):
    return {"id": name, "cache": "hit", "minimum_cached_tokens": 8192, "fixed_tokens": True,
            "payload": {"model": r.MODEL, "stream": True, "max_tokens": 128,
                        "stream_options": {"include_usage": True}}}


class Endpoint(urllib.request.HTTPHandler):
    """Answers HTTP in memory and records where each request went; never opens a socket."""
    def __init__(self, answer):
        super().__init__()
        self.answer, self.seen = answer, []

    def http_open(self, req):
        self.seen.append((req.get_method(), req.host))
        status, body, location = self.answer(req)
        headers = email.message.Message()
        if location:
            headers["Location"] = location
        response = urllib.response.addinfourl(io.BytesIO(body), headers, req.full_url, status)
        response.msg = http.client.responses[status]
        return response


class ReplayTests(unittest.TestCase):
    @staticmethod
    def stream(done=True):
        chunks = [{"choices": [{"delta": {"content": "Answer: B"}}]},
                  {"choices": [{"delta": {}, "finish_reason": "length"}], "usage": {
                      "completion_tokens": 128, "prompt_tokens": 8259,
                      "prompt_tokens_details": {"cached_tokens": 8192}}}]
        return [b"data: " + json.dumps(c).encode() + b"\n\n" for c in chunks] + ([b"data: [DONE]\n"] if done else [])

    def test_complete_stream_and_quality_scoring(self):
        result = r.consume(self.stream(), 0, clock=lambda: 1)
        r.check_case({"cache": "hit", "minimum_cached_tokens": 8192,
                      "fixed_tokens": True, "payload": {"max_tokens": 128}, "answer_letter": "B"}, result)
        self.assertTrue(result["correct"])
        self.assertTrue(result["truncated"])

    def test_premature_eof_and_error_are_failures(self):
        with self.assertRaises(ValueError):
            r.consume(self.stream(False), 0)
        with self.assertRaises(ValueError):
            r.consume([b'data: {"error":"failed"}\n', b'data: [DONE]\n'], 0)

    def test_cache_flags_cannot_replace_actual_hit(self):
        result = r.consume(self.stream(), 0)
        result["usage"]["prompt_tokens_details"]["cached_tokens"] = 0
        with self.assertRaises(ValueError):
            r.check_case(case(), result)
        with self.assertRaises(ValueError):
            r.check_case(dict(case(), minimum_cached_tokens=0), result)

    def test_early_stop_invalidates_fixed_work(self):
        result = r.consume(self.stream(), 0)
        result["finish_reason"] = "stop"
        with self.assertRaises(ValueError):
            r.check_case({"fixed_tokens": True, "payload": {"max_tokens": 128}}, result)

    def test_runtime_guard_rejects_wrong_backend_cache_or_ownership(self):
        metrics = METRICS
        self.assertTrue(r.runtime_guard(metrics))
        for bad in (metrics.replace('backend="paged"', 'backend="contiguous"'),
                    metrics.replace('state="ready"', 'state="error"'),
                    metrics.replace('kv_active_requests{model="gpt-oss-20b"} 0', 'kv_active_requests{model="gpt-oss-20b"} 1')):
            with self.assertRaises(ValueError):
                r.runtime_guard(bad)

    def test_metric_labels_must_match_exact_keys(self):
        with self.assertRaises(ValueError):
            r.runtime_guard(METRICS.replace('model=', 'other_model='))

    def test_noninteger_and_impossible_usage_is_rejected(self):
        for value in (True, 0.5, float("nan"), float("inf"), -1, "8192", None, 8260):
            result = r.consume(self.stream(), 0)
            result["usage"]["prompt_tokens_details"]["cached_tokens"] = value
            with self.subTest(value=value), self.assertRaises(ValueError):
                r.check_case(case(), result)
        for value in (True, 128.0, 0, 129, -1, None):
            result = r.consume(self.stream(), 0)
            result["usage"]["completion_tokens"] = value
            with self.subTest(completion=value), self.assertRaises(ValueError):
                r.check_case(dict(case(), fixed_tokens=False), result)

    def test_malformed_terminal_order_and_json_fail(self):
        for bad in (self.stream() + self.stream()[:1],
                    self.stream()[:-1] + self.stream(),
                    [b'data: {"error":false,"error":true}\n'],
                    [b'data: {"usage":{"completion_tokens":NaN}}\n']):
            with self.assertRaises(ValueError):
                r.consume(bad, 0)

    def test_suite_preflight_rejects_invalid_work_and_cache_contracts(self):
        good = {"cohorts": [{"id": "warm", "cases": [case()]}]}
        self.assertEqual(len(r.validate_suite(good)), 1)
        for change in ({"minimum_cached_tokens": 0}, {"cache": "invalid"},
                       {"fixed_tokens": "false"}, {"answer_letter": "E"},
                       {"payload": dict(case()["payload"], stream=1)},
                       {"payload": dict(case()["payload"], max_tokens=True)},
                       {"payload": dict(case()["payload"], n=2)}):
            with self.subTest(change=change), self.assertRaises(ValueError):
                r.validate_suite({"cohorts": [{"id": "warm", "cases": [dict(case(), **change)]}]})
        with self.assertRaises(ValueError):
            r.validate_suite({"cohorts": [{"id": "empty", "cases": []}]})


class ReplayRunTests(unittest.TestCase):
    """Exercise the real orchestration with in-memory responses, never a server."""
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.args = SimpleNamespace(base_url="http://127.0.0.1:1", suite=self.root / "suite.json",
                                    identity=self.root / "identity.json", output=self.root / "output",
                                    resource_window="CPU fixture, no server")
        self.args.suite.write_text(json.dumps({"cohorts": [{"id": "warm", "cases": [case("one"), case("two")]}]}))
        self.args.identity.write_text(json.dumps({k: "a" * 64 for k in (
            "model_artifact_sha256", "binary_sha256", "metallib_sha256", "config_sha256", "prompt_contract_sha256")}))
        self.posts = []
        self.raw_stream = b"".join(ReplayTests.stream())
        self.open = self.enterContext(patch.object(r.urllib.request, "build_opener")).return_value.open
        self.open.side_effect = self.respond
        self.enterContext(patch.object(r.time, "sleep"))

    def respond(self, req, timeout):
        if isinstance(req, str):
            return io.BytesIO(METRICS.encode())
        self.posts.append(req)
        return io.BytesIO(self.raw_stream)

    def test_complete_cohort_retains_streams_identity_and_valid_summary(self):
        r.run(self.args)
        self.assertEqual(len(self.posts), 2)
        summary = json.loads((self.args.output / "cohorts.json").read_text())[0]
        self.assertTrue(summary["valid"])
        self.assertGreater(summary["aggregate_end_to_end_tokens_per_second"], 0)
        self.assertEqual((self.args.output / "one.sse").read_bytes(), self.raw_stream)
        self.assertFalse(json.loads((self.args.output / "complete.json").read_text())["qualified"])

    def test_invalid_cohort_has_no_throughput_or_completion_receipt(self):
        self.raw_stream = self.raw_stream.replace(b'"cached_tokens": 8192', b'"cached_tokens": 0')
        with self.assertRaisesRegex(ValueError, "Invalid cohort"):
            r.run(self.args)
        summary = json.loads((self.args.output / "cohorts.json").read_text())[0]
        self.assertFalse(summary["valid"])
        self.assertIsNone(summary["aggregate_end_to_end_tokens_per_second"])
        # A failed case aborts the barrier, so a peer still waking from it can stop before it
        # sends; the case that released the barrier always streams, and its raw stream is kept.
        self.assertTrue(any((self.args.output / f"{name}.sse").exists() for name in ("one", "two")))
        self.assertFalse((self.args.output / "complete.json").exists())

    def test_request_file_failure_occurs_before_any_post(self):
        original = Path.write_text
        def fail(path, *args, **kwargs):
            if path.name == "one-request.json":
                raise OSError("injected disk full")
            return original(path, *args, **kwargs)
        with patch.object(Path, "write_text", fail), self.assertRaises(OSError):
            r.run(self.args)
        self.assertFalse(self.posts)

    def test_failed_raw_log_does_not_post_that_request_or_hang_peers(self):
        original = Path.open
        def fail(path, *args, **kwargs):
            if path.name == "one.sse":
                raise OSError("injected disk full")
            return original(path, *args, **kwargs)
        with patch.object(Path, "open", fail), self.assertRaisesRegex(ValueError, "Invalid cohort"):
            r.run(self.args)
        self.assertLessEqual(len(self.posts), 1)
        self.assertFalse((self.args.output / "complete.json").exists())

    def test_stream_capture_is_bounded(self):
        self.args.suite.write_text(json.dumps({"cohorts": [{"id": "warm", "cases": [case("one")]}]}))
        with patch.object(r, "MAX_STREAM_BYTES", 10), self.assertRaisesRegex(ValueError, "Invalid cohort"):
            r.run(self.args)
        result = json.loads((self.args.output / "one-result.json").read_text())
        self.assertIn("bounded capture", result["error"])

    def test_final_runtime_guard_is_required(self):
        reads = 0
        def changed(req, timeout):
            nonlocal reads
            if isinstance(req, str):
                reads += 1
                text = METRICS.replace('state="ready"', 'state="error"') if reads == 4 else METRICS
                return io.BytesIO(text.encode())
            return self.respond(req, timeout)
        self.open.side_effect = changed
        with self.assertRaisesRegex(ValueError, "cache is not ready"):
            r.run(self.args)
        self.assertFalse((self.args.output / "complete.json").exists())

    def test_drain_deadline_stops_before_next_cohort(self):
        with patch.object(r.time, "monotonic", side_effect=[0, 31]), self.assertRaisesRegex(ValueError, "failed to drain"):
            r.run(self.args)
        summary = json.loads((self.args.output / "cohorts.json").read_text())[0]
        self.assertEqual(summary["status"], "runtime_failed")
        self.assertFalse(summary["valid"])
        self.assertIsNone(summary["aggregate_end_to_end_tokens_per_second"])
        self.assertFalse((self.args.output / "complete.json").exists())

    def test_redirects_are_refused(self):
        with self.assertRaisesRegex(ValueError, "must not redirect"):
            r.NoRedirect().redirect_request(None, None, 307, "", {}, "http://external.invalid/")

    def test_only_a_bare_loopback_http_endpoint_is_contacted(self):
        for url in ("https://api.darkbloom.dev", "http://api.darkbloom.dev", "https://127.0.0.1:18241",
                    "http://localhost.evil.test:18241", "http://10.0.0.8:18241", "http://user:pw@127.0.0.1:18241",
                    "http://user@localhost:18241", "http://127.0.0.1:18241/v1", "http://127.0.0.1:18241/?x=1",
                    "http://127.0.0.1:18241/#top"):
            with self.subTest(url=url):
                self.args.base_url = url
                with self.assertRaisesRegex(ValueError, "local, explicitly allocated"):
                    r.run(self.args)
                self.assertFalse(self.open.called)
                self.assertFalse(self.args.output.exists())
        for index, url in enumerate(("http://127.0.0.1:18241", "http://localhost:18241/", "http://[::1]:18241")):
            with self.subTest(url=url):
                self.open.reset_mock()
                self.args.base_url, self.args.output = url, self.root / f"accepted-{index}"
                r.run(self.args)
                opened = [c.args[0] if isinstance(c.args[0], str) else c.args[0].full_url
                          for c in self.open.call_args_list]
                self.assertTrue(opened)
                self.assertTrue(all(u.startswith(url.rstrip("/") + "/") for u in opened), opened)

    def through_the_real_opener(self, endpoint):
        # run() builds its own opener; the endpoint replaces only the socket-level HTTP handler.
        return patch.object(r.urllib.request, "build_opener", lambda *handlers: BUILD_OPENER(*handlers, endpoint))

    def test_an_environment_proxy_never_carries_the_traffic(self):
        endpoint = Endpoint(lambda req: (200, METRICS.encode() if req.get_method() == "GET" else self.raw_stream, None))
        proxy = {"http_proxy": "http://proxy.invalid:3128", "HTTP_PROXY": "http://proxy.invalid:3128",
                 "no_proxy": "", "NO_PROXY": ""}
        with patch.dict(os.environ, proxy), self.through_the_real_opener(endpoint):
            r.run(self.args)
        self.assertEqual({host for _, host in endpoint.seen}, {"127.0.0.1:1"})
        self.assertEqual([method for method, _ in endpoint.seen].count("POST"), 2)
        self.assertTrue((self.args.output / "complete.json").exists())

    def test_a_redirect_stops_the_run_unfollowed(self):
        endpoint = Endpoint(lambda req: (307, b"", "http://external.invalid/metrics"))
        with self.through_the_real_opener(endpoint), self.assertRaisesRegex(ValueError, "must not redirect"):
            r.run(self.args)
        self.assertEqual(endpoint.seen, [("GET", "127.0.0.1:1")])
        self.assertFalse((self.args.output / "metrics-before.txt").exists())


if __name__ == "__main__":
    unittest.main()
