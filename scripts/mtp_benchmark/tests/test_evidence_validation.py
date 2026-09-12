"""Offline malformed-evidence regressions; no child process or model execution."""
from __future__ import annotations

import hashlib
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

import test_contract as contracts
from mtp_benchmark import artifacts


class EvidenceValidationTests(unittest.TestCase):
    def test_config_facts_describe_the_same_bounded_payload(self):
        with tempfile.TemporaryDirectory() as temporary:
            snapshot = Path(temporary) / "repository" / "snapshots" / "revision"
            snapshot.mkdir(parents=True)
            config = snapshot / "config.json"
            config.write_bytes(b'{"quantization":{"bits":4}}')
            (snapshot / "model.safetensors").write_bytes(b"synthetic weights")
            replacement = b'{"model_type":"gemma4_text","quantization":{"bits":8}}'
            read_bounded = artifacts.read_bounded
            observed = []

            def replace_before_read(descriptor, maximum_bytes):
                # Deterministic replacement between the old independent hash
                # and parse reads. The new implementation hashes this payload.
                config.write_bytes(replacement)
                payload = read_bounded(descriptor, maximum_bytes)
                observed.append(payload)
                return payload

            with patch.object(artifacts, "read_bounded", side_effect=replace_before_read):
                facts = artifacts.artifact_facts("example/model", snapshot)
            self.assertEqual(observed, [replacement])
            self.assertEqual(facts["configMetadata"]["effective_quantization_bits"], 8)
            self.assertEqual(facts["configSHA256"], hashlib.sha256(replacement).hexdigest())
            self.assertEqual(facts["configSizeBytes"], len(replacement))

    def test_production_rejects_malformed_elapsed_and_aggregate_metrics(self):
        invalid = (None, True, False, "20", {}, [], -1, -0.5,
                   float("nan"), float("inf"), float("-inf"))
        for field in ("elapsedMs", "medianAggregateDecodeTokensPerSecond"):
            for value in invalid:
                with self.subTest(field=field, value=value):
                    report, artifact = contracts.report_fixture("production-performance")
                    destination = report if field == "elapsedMs" else report["cases"][0]
                    destination[field] = value
                    with self.assertRaises(ValueError):
                        contracts.ReportContractTests().validate(report, artifact, mode="production-performance")

    def test_production_retains_zero_and_finite_metric_ranges(self):
        # A one-token stream has zero decode intervals; zero throughput is
        # valid evidence, not a speedup claim. No positive threshold is added.
        for value in (0, 0.0, 1, 0.125, sys.float_info.min, sys.float_info.max):
            with self.subTest(value=value):
                report, artifact = contracts.report_fixture("production-performance")
                report["elapsedMs"] = value
                for case in report["cases"]:
                    case["medianAggregateDecodeTokensPerSecond"] = value
                contracts.ReportContractTests().validate(report, artifact, mode="production-performance")


if __name__ == "__main__":
    unittest.main()
