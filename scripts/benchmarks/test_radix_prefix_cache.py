import json
import unittest

import radix_prefix_cache as bench


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


if __name__ == "__main__":
    unittest.main()
