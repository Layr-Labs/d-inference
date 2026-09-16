import json
from contextlib import redirect_stdout
import io
import os
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import radix_prefix_cache as bench
import run_radix_http


def frame(delta=None, finish=None, usage=None):
    return json.dumps({"choices": [{"index": 0, "delta": delta or {}, "finish_reason": finish}], "usage": usage})


class StreamEvidenceTests(unittest.TestCase):
    def test_multiline_crlf_and_comments(self):
        lines = [b": heartbeat\r\n", b"data: {\r\n", b'data: "choices": []}\r\n', b"\r\n", b"data: [DONE]\r\n", b"\r\n"]
        self.assertEqual(list(bench.events(lines)), ['{\n"choices": []}', "[DONE]"])

    def test_reasoning_is_not_duplicated_and_role_is_not_first_token(self):
        ticks = iter([1, 2, 3, 4, 5, 6])
        payloads = [frame({"role": "assistant"}),
                    frame({"reasoning": "thought", "reasoning_content": "thought"}),
                    frame({"content": "answer"}),
                    frame(finish="length", usage={"prompt_tokens": 20, "completion_tokens": 3}), "[DONE]"]
        result = bench.collect(payloads, 0, clock=lambda: next(ticks))
        self.assertEqual((result["ttft_s"], result["last_content_s"]), (2, 3))
        self.assertEqual(result["reasoning"], "thought")
        self.assertEqual(result["text"], "answer")
        self.assertTrue(result["done"])

    def test_errors_and_truncated_streams_cannot_pass(self):
        for payloads in ([json.dumps({"error": {"message": "failure"}})],
                         [frame({"content": "partial"})], ["[DONE]"]):
            with self.assertRaises(RuntimeError):
                bench.collect(payloads, 0)

    def test_cancellation_is_recorded_without_claiming_success(self):
        result = bench.collect([frame({"content": "first"}), "invalid-after-disconnect"], 0, cancel_after=1)
        self.assertTrue(result["cancelled"])
        self.assertFalse(result["done"])

    def test_empty_usage_is_not_valid_token_count_evidence(self):
        with self.assertRaisesRegex(RuntimeError, "usage.prompt_tokens"):
            bench.collect([frame({"content": "answer"}), frame(finish="stop", usage={}), "[DONE]"], 0)

    def test_equal_text_with_different_counts_fails(self):
        first = {"text": "same", "reasoning": "", "finish_reasons": ["length"], "usage": {"prompt_tokens": 12, "completion_tokens": 2}}
        other = dict(first, usage={"prompt_tokens": 12, "completion_tokens": 3})
        comparison = bench.equality(first, other)
        self.assertFalse(comparison["text_and_counts_equal"])
        self.assertEqual(comparison["differences"], ["completion_tokens"])
        self.assertFalse(comparison["generated_token_ids_compared"])

    def test_branches_share_long_prefix_and_repetitions_are_isolated(self):
        plan = list(bench.cases([8192], 2))
        first, repeat, branch = plan[:3]
        self.assertEqual(first["messages"], repeat["messages"])
        self.assertEqual(first["messages"][1]["content"][:32000], branch["messages"][1]["content"][:32000])
        self.assertNotEqual(first["messages"][0], plan[6]["messages"][0])
        self.assertEqual(plan[4]["parent"], first["id"])


class ReplayInputTests(unittest.TestCase):
    response = {"text": "answer", "reasoning": "", "finish_reasons": ["stop"],
                "usage": {"prompt_tokens": 10, "completion_tokens": 2}, "ttft_s": 1}

    def test_invalid_plan_is_refused_before_requests_and_artifact_writes(self):
        def row(name, model="fixture", **case):
            return {"case": {"id": name, "kind": "first", **case},
                    "request": {"model": model}, "response": self.response}
        plans = [[], [row("../escaped")], [row("/absolute")], [row("nested/file")],
                 [row("a\\b")], [row("bad\x00id")], [row("warmup")], [row("REPORT")],
                 [row("cancellation")], [row("same"), row("same")],
                 [row("same"), row("SAME")], [row("first", "other-model")],
                 [row("first", equal_to="missing")], [row(None)],
                 [row("café"), row("cafe\u0301")], [row("first", equal_to=["missing"])],
                 *[[row("first", equal_to=value)] for value in (0, False, [], {}, "")],
                 [row("x" * 251)], [row("é" * 126)]]
        for rows in plans:
            with self.subTest(rows=rows), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                rows = [{**item, "case": {**item["case"], "id": str(root / "absolute")}}
                        if item["case"]["id"] == "/absolute" else item for item in rows]
                source, output = root / "source.json", root / "run"
                source.write_text(json.dumps({"rows": rows}))
                args = SimpleNamespace(output=str(output), replay=str(source), model="fixture",
                                       base="http://fixture.invalid", lengths=[512], repeats=1, label="fixture")
                with patch.object(bench, "request", return_value=self.response) as request, \
                     patch.object(bench, "metrics", return_value="stub") as metrics, \
                     redirect_stdout(io.StringIO()), self.assertRaises(ValueError):
                    bench.run(args)
                request.assert_not_called()
                metrics.assert_not_called()
                self.assertFalse(output.exists())
                self.assertFalse((root / "escaped.json").exists())

    def test_wrapper_refuses_invalid_replay_before_host_work(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "invalid.json"
            source.write_text('{"rows": []}')
            output = root / "new-output"
            argv = ["run_radix_http.py", "--binary", "/unused/provider", "--output", str(output),
                    "--model", "fixture", "--replay", str(source)]
            with patch.object(run_radix_http.sys, "argv", argv), \
                 patch.object(run_radix_http, "ranked_job", side_effect=AssertionError("host probe")) as ranked, \
                 patch.object(run_radix_http.subprocess, "Popen") as launch, \
                 self.assertRaises(ValueError):
                run_radix_http.main()
            ranked.assert_not_called()
            launch.assert_not_called()
            self.assertFalse(output.exists())

    def test_filename_byte_boundary_includes_json_suffix(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            limit = os.pathconf(root, "PC_NAME_MAX")
            source = root / "source.json"
            for name in ("x" * (limit - 5), "é" * ((limit - 5) // 2)):
                row = {"case": {"id": name, "kind": "first", "equal_to": None},
                       "request": {"model": "fixture"}}
                source.write_text(json.dumps({"rows": [row]}))
                self.assertEqual(list(bench.load_replay(source, "fixture")), [name])

    def test_replay_preserves_order_and_entire_request_body(self):
        response = {"text": "retained answer", "reasoning": "", "finish_reasons": ["stop"],
                    "usage": {"prompt_tokens": 10, "completion_tokens": 2}, "ttft_s": 1}
        body = {"model": "fixture", "messages": [{"role": "user", "content": "authored"}],
                "tools": [{"type": "function", "function": {"name": "lookup"}}],
                "temperature": 0.7, "max_tokens": 13, "_darkbloom_prompt_date": "2026-09-05"}
        rows = [{"case": {"id": "custom-first", "kind": "first"}, "request": body, "response": response},
                {"case": {"id": "custom-repeat", "kind": "repeat", "equal_to": "custom-first"},
                 "request": dict(body, seed=42), "response": response}]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source, output = root / "source.json", root / "run"
            source.write_text(json.dumps({"rows": rows}))
            original = source.read_bytes()
            args = SimpleNamespace(output=str(output), replay=str(source), model="fixture",
                                   base="http://fixture.invalid", lengths=[512], repeats=1, label="fixture")
            with patch.object(bench, "request", return_value=response) as request, \
                 patch.object(bench, "metrics", return_value="stub metrics"), redirect_stdout(io.StringIO()):
                bench.run(args)
            self.assertEqual([call.args[1] for call in request.call_args_list[1:3]], [row["request"] for row in rows])
            actual = json.loads((output / "report.json").read_text())["rows"]
            self.assertEqual([item["case"] for item in actual], [row["case"] for row in rows])
            self.assertEqual([item["request"] for item in actual], [row["request"] for row in rows])
            self.assertEqual(source.read_bytes(), original)


if __name__ == "__main__":
    unittest.main()
