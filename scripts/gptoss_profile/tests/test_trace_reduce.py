import json
import tempfile
import unittest
from pathlib import Path

from scripts.gptoss_profile.trace_reduce import reduce_trace
from scripts.gptoss_profile.trace_schema import OPEN_FIELDS, interval_metrics


class TraceReductionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def fixture(self, extra=()):
        context = {"generation": 1, "run_id": 1, "request_id": 2,
                   "chunk_id": 0, "decode_step_id": 3, "layer": 4, "logical_op_id": 25}

        def event(kind, oid, values=(), name="", timestamp=10):
            return {"kind": kind, "object_id": oid, "values": list(values),
                    "name": name, "context": context, "timestamp_ns": timestamp}

        events = [
            event("run_begin", 1, (512, 0)),
            event("decode_step_begin", 3, (7, 2, 2, 2, 0, 0, 1)),
            event("logical_scope_begin", 25, timestamp=20),
            event("pipeline", 8, name="qmv_test"),
            event("pipeline", 8, name="qmv_test"),
            event("dispatch", 9, (2, 1, 1, 32, 1, 1, 8), name="threads"),
            event("primitive_begin", 10, name="GatherQMM"),
            event("logical_scope_end", 25, timestamp=40),
            event("command_buffer_complete", 11, (100, 150, 4)),
            event("command_buffer_complete", 12, (125, 175, 4)),
            *extra,
        ]
        self.manifest = {"schema_version": 1, "complete": True, "records_written": len(events),
                         "records_dropped": 0, "explicit_failures": 0, "scope_errors": 0,
                         "primitive_context_association_exhausted": False,
                         "gpu_capture_incomplete": False, "gpu_capture_security_failure_stage": 0,
                         "gpu_capture_security_failure_errno": 0,
                         "detail_selected_decode_steps": [7],
                         **dict.fromkeys(OPEN_FIELDS, 0)}
        self.summary = {**self.manifest, "records": len(events), "dropped_records": 0}
        (self.root / "events.ndjson").write_text("\n".join(map(json.dumps, events)) + "\n")
        self.save_metadata()

    def save_metadata(self):
        (self.root / "manifest.json").write_text(json.dumps(self.manifest))
        (self.root / "summary.json").write_text(json.dumps(self.summary))

    def test_dispatch_join_and_overlap_do_not_count_pipeline_lookup_as_dispatch(self):
        self.fixture()
        result, tables = reduce_trace(self.root)
        self.assertTrue(result["valid"], result["errors"])
        self.assertEqual(tables["kernels"][0]["dispatches"], 1)
        self.assertEqual(tables["kernels"][0]["operation"], "routed_expert_gate_projection")
        self.assertEqual(tables["operators"][0]["graph_scope_inclusive_host_ns"], 20)
        self.assertEqual(tables["phases"][0]["public_gpu_union_ns"], 75)
        self.assertEqual(tables["phases"][0]["public_gpu_overlap_ns"], 25)

    def test_missing_summary_is_incomplete(self):
        self.fixture()
        (self.root / "summary.json").unlink()
        result, _ = reduce_trace(self.root)
        self.assertFalse(result["valid"])
        self.assertIn("missing or invalid summary.json", result["errors"])

    def test_dropped_records_and_open_scopes_reject_trace(self):
        self.fixture()
        self.manifest.update(records_dropped=4, open_primitives=1)
        self.save_metadata()
        result, _ = reduce_trace(self.root)
        self.assertFalse(result["valid"])
        self.assertTrue(any("records_dropped" in e for e in result["errors"]))
        self.assertTrue(any("open_primitives" in e for e in result["errors"]))

    def test_missing_selected_region_and_capture_are_not_claimed_complete(self):
        self.fixture()
        self.manifest.update(detail_selected_decode_steps=[99], gpu_capture_selected_decode_steps=[99])
        self.save_metadata()
        result, _ = reduce_trace(self.root)
        self.assertFalse(result["valid"])
        self.assertEqual(result["capture"]["status"], "failed_or_incomplete")
        self.assertFalse(result["capture"]["replay_validated"])

    def test_interval_union_ignores_unavailable_zero_timestamps(self):
        self.assertEqual(interval_metrics([(0, 10), (10, 20), (15, 30)])["public_gpu_union_ns"], 20)

    def test_manifest_cannot_hide_unpaired_logical_scope(self):
        self.fixture(extra=[{"kind": "logical_scope_end", "object_id": 88,
                            "context": {}, "timestamp_ns": 80, "values": []}])
        result, _ = reduce_trace(self.root)
        self.assertFalse(result["valid"])
        self.assertTrue(any("unpaired logical scopes" in e for e in result["errors"]))

    def test_unknown_dispatch_pipeline_rejects_attribution(self):
        self.fixture(extra=[{"kind": "dispatch", "object_id": 88, "name": "threads",
                            "context": {}, "timestamp_ns": 80,
                            "values": [1, 1, 1, 32, 1, 1, 98765]}])
        result, _ = reduce_trace(self.root)
        self.assertFalse(result["valid"])
        self.assertEqual(result["unknown_pipeline_dispatches"], 1)


if __name__ == "__main__":
    unittest.main()
