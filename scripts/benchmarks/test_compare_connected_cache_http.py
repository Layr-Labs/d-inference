import copy
import unittest
from compare_connected_cache_http import compare


def fixture(cache):
    usage = {"prompt_tokens": 2048, "completion_tokens": 64, "reasoning_tokens": 4}
    names = ["cold_donor_a", "same_prompt_a", "tenant_isolation_a", "continuation_b",
             "original_after_continuation", "tools", "vision", "cancel", "after_cancel", "sidecar_unavailable"]
    return {"schema": 1, "state": "completed", "wire_dropped": 0,
            "input": {"cache_mode": cache, "artifact": {"model_id": "gpt-oss-20b", "model_aggregate_sha256": "a"*64, "prompt_contract_id": "b"*64},
                      "catalog": [{"entry": "exact fixture"}], "provider_sha256": "c"*64, "metallib_sha256": "d"*64,
                      "sidecar_sha256": "e"*64, "backend": "paged", "mtp_mode": "off", "max_concurrent": 1,
                      "tools_request": {"tools": ["fixture"]}, "prompt": "authored fixture"}, "cases": [
                {"name": name, "status": "passed", "request": {"fixture": name}, "tenant_index": 0,
                 "request_date_utc": "2026-09-05",
                 "http": {"done": True, "finish_reason": "stop", "content": "blue", "reasoning": "thought", "usage": dict(usage)},
                 "wire": [{"type": "inference_complete", "fields": {"usage": dict(usage)}}]} for name in names]}


class CompareConnectedHTTPTests(unittest.TestCase):
    def test_complete_pair(self):
        self.assertEqual([], compare(fixture("off"), fixture("ssd")))

    def test_identity_request_date_and_output_changes_refuse(self):
        changes = [lambda r: r["input"].update(provider_sha256="different"),
                   lambda r: r["input"].update(artifact={"model_id": "substitute"}),
                   lambda r: r["input"].update(mtp_mode="on"),
                   lambda r: r["cases"][0].update(request_date_utc="2026-09-06"),
                   lambda r: r["cases"][0].update(request={"fixture": "changed"}),
                   lambda r: r["cases"][0]["http"].update(reasoning="changed"),
                   lambda r: r["cases"][0]["http"].update(finish_reason="length"),
                   lambda r: r["cases"][0]["http"].update(usage={}),
                   lambda r: r.update(wire_dropped=1)]
        for change in changes:
            with self.subTest(change=change):
                candidate = copy.deepcopy(fixture("ssd"))
                change(candidate)
                self.assertTrue(compare(fixture("off"), candidate))

    def test_unrun_or_failed_cells_never_pass(self):
        for status in ["not_run", "running", "failed"]:
            candidate = fixture("ssd")
            candidate["cases"][7]["status"] = status
            self.assertTrue(compare(fixture("off"), candidate))

    def test_partial_cancel_counts_are_not_parity_measurements(self):
        candidate = copy.deepcopy(fixture("ssd"))
        candidate["cases"][7]["wire"][0]["fields"]["usage"]["completion_tokens"] = 2
        candidate["cases"][7]["http"]["content"] = "partial"
        self.assertEqual([], compare(fixture("off"), candidate))


if __name__ == "__main__":
    unittest.main()
