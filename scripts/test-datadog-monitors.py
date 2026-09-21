#!/usr/bin/env python3
"""Static checks for the Datadog monitor definitions under deploy/datadog/monitors/.

They are applied by deploy/datadog/apply-monitor.sh; this keeps a broken or
inconsistent definition from reaching Datadog.
"""
import json
import pathlib
import re
import subprocess
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
MONITORS = ROOT / "deploy" / "datadog" / "monitors"
APPLY = ROOT / "deploy" / "datadog" / "apply-monitor.sh"


def monitors():
    paths = sorted(MONITORS.glob("*.json"))
    assert paths, f"no monitor definitions under {MONITORS}"
    return [(p, json.loads(p.read_text(encoding="utf-8"))) for p in paths]


class MonitorDefinitions(unittest.TestCase):
    def test_required_shape(self):
        for path, m in monitors():
            with self.subTest(path=path.name):
                for key in ("name", "type", "query", "message", "tags", "options"):
                    self.assertIn(key, m)
                self.assertEqual(m["type"], "query alert")
                self.assertIn("managed-by:deploy/datadog", m["tags"], "apply-monitor.sh finds existing monitors by this tag")
                self.assertIn("__NOTIFY__", m["message"], "apply-monitor.sh substitutes DD_MONITOR_NOTIFY for this line")
                self.assertIn("{{key.name}}", m["message"], "the alert must name the failing cache key")

    def test_query_is_coordinator_metric_with_consistent_threshold(self):
        for path, m in monitors():
            with self.subTest(path=path.name):
                q = m["query"]
                self.assertIn("d_inference.", q, "coordinator metrics carry the DogStatsD namespace prefix")
                self.assertIn(" by {", q)
                self.assertIn("key", q.split(" by {", 1)[1].split("}", 1)[0].split(","))
                threshold = re.search(r"[><]=?\s*([0-9.]+)\s*$", q)
                self.assertIsNotNone(threshold, f"query must end with a comparison: {q}")
                self.assertEqual(float(threshold.group(1)), float(m["options"]["thresholds"]["critical"]))

    def test_sparse_counter_alerts_do_not_page_on_no_data(self):
        # cache.refresh_failed is emitted only on failure, so silence is healthy.
        for path, m in monitors():
            if "refresh_failed" not in m["query"]:
                continue
            with self.subTest(path=path.name):
                self.assertFalse(m["options"].get("notify_no_data", True))
                self.assertIn("default_zero(", m["query"], "gaps must read as zero so the alert recovers")

    def test_apply_script_is_executable_and_parses(self):
        self.assertTrue(APPLY.exists())
        self.assertTrue(APPLY.stat().st_mode & 0o111, "apply-monitor.sh must be executable")
        subprocess.run(["bash", "-n", str(APPLY)], check=True)


if __name__ == "__main__":
    unittest.main()
