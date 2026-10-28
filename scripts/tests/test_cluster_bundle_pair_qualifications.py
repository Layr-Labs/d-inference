#!/usr/bin/env python3
"""Isolated bundler contract tests; synthetic records never qualify a model."""
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "cluster-bundle-pair-qualifications.sh"
OUTPUT = Path("provider-swift/Sources/ProviderCore/Inference/Distributed/Installed/DistributedInstalledPairQualificationRecords.swift")
ARTIFACT = "a4722b6020adb1894c700b45ddcd58bc0e0f033abe7139f86cbbbfe60cba4eb6"
PLAIN, EIGHT = "registered_gemma4_26b", "registered_gemma4_26b_8bit"


def record(model, artifact=ARTIFACT, ordinal=0):
    # These are deliberately labelled synthetic unit inputs, not copied,
    # relabelled, or bundled qualification evidence from real Macs.
    return json.dumps({
        "schema": "darkbloom_cluster_pair_qualification_v1", "runtimeModelID": model,
        "artifactSHA256": artifact, "producer": "synthetic-bundler-unit-test",
        "pairReportSHA256": f"{ordinal:064x}", "passed": False,
        "comparisons": [], "ranks": [], "cuts": [], "transport": "unit-test",
    }, separators=(",", ":"), sort_keys=True)


class BundleAliases(unittest.TestCase):
    def run_bundle(self, lines):
        with tempfile.TemporaryDirectory(prefix="gemma-alias-bundle-") as directory:
            root = Path(directory)
            (root / "scripts").mkdir()
            shutil.copy2(SCRIPT, root / "scripts" / SCRIPT.name)
            out = root / OUTPUT
            out.parent.mkdir(parents=True)
            out.write_text("unchanged on refusal\n")
            source = root / "records.jsonl"
            source.write_text("\n".join(lines) + "\n")
            result = subprocess.run(["bash", str(root / "scripts" / SCRIPT.name), str(source)],
                                    text=True, capture_output=True)
            return result, out.read_text(), source.read_text()

    def test_exact_aliases_preserve_both_original_runtime_ids_and_records(self):
        lines = [record(PLAIN, ordinal=1), record(EIGHT, ordinal=2)]
        for inputs in [lines, lines[::-1], lines + lines[::-1]]:
            result, output, source = self.run_bundle(inputs)
            self.assertEqual(result.returncode, 0, result.stderr)
            actual = [line for line in output.splitlines() if line.startswith("{")]
            self.assertEqual(actual, sorted(set(lines)))
            self.assertEqual(source, "\n".join(inputs) + "\n")
            self.assertEqual({json.loads(line)["runtimeModelID"] for line in actual}, {PLAIN, EIGHT})

    def test_unrelated_digest_or_id_remains_refused_in_either_input_order(self):
        invalid = [
            [record(PLAIN, "b" * 64), record(EIGHT, "b" * 64)],
            [record(PLAIN), record("registered_gemma4_26b_qat_4bit")],
            [record(EIGHT), record("registered_qwen3_5_35b_a3b")],
            [record(PLAIN), record(EIGHT), record("unregistered")],
        ]
        for lines in invalid:
            for inputs in [lines, lines[::-1], lines + lines[::-1]]:
                result, output, source = self.run_bundle(inputs)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("mislabelled record", result.stderr)
                self.assertEqual(output, "unchanged on refusal\n")
                self.assertEqual(source, "\n".join(inputs) + "\n")

    def test_existing_single_identity_and_exact_duplicate_behavior_is_unchanged(self):
        for model in [PLAIN, EIGHT, "registered_qwen3_8_27b"]:
            line = record(model, "c" * 64)
            result, output, _ = self.run_bundle([line, line])
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual([item for item in output.splitlines() if item.startswith("{")], [line])


if __name__ == "__main__":
    unittest.main()
