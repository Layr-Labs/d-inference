#!/usr/bin/env python3
"""Exercise the actual curator CLI without a model, GPU or mutable raw evidence."""
import copy
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).with_name("curate_runs.py")
ARTIFACTS = {"darkbloom": "a" * 64, "mlx.metallib": "b" * 64}


def generation():
    return {"runtimeIdentity": {"binary_sha256": ARTIFACTS["darkbloom"],
                                "metallib_sha256": ARTIFACTS["mlx.metallib"]}}


def scores():
    diagnostic = {"records": [{"nanCount": 0, "infiniteCount": 0}], "top1": [1]}
    return {"executableSHA256": ARTIFACTS["darkbloom"],
            "metallibSHA256": ARTIFACTS["mlx.metallib"],
            "diagnostic": diagnostic, "repeatedDiagnostic": copy.deepcopy(diagnostic),
            "input": {"promptTokens": [1, 2]}, "plainTop1": [1], "meanForcedTokenNLL": 1.25}


class CuratedExecutionIdentityTests(unittest.TestCase):
    def invoke(self, report, mode="retrieval", parsed=True, expected=None, raw_changed=False,
               native_peer=None, include_peer=True, peer_parsed=True, peer_changed=False):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            stage = root / "stage"
            stage.mkdir()
            label = "fixture-" + mode + "-balanced"
            raw = stage / (label + ".json")
            raw.write_text(json.dumps(report) if parsed else "failed before any JSON report\n")
            log = stage / (label + ".log")
            log.write_text("CPU fixture; no inference execution\n")
            digest = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
            entry = {"modelID": "fixture", "mode": mode, "requestedPrecision": "balanced",
                     "command": [], "reportParsed": parsed, "exitCode": 0 if parsed else 2,
                     "jsonSHA256": digest(raw), "logSHA256": digest(log)}
            manifest = {"candidateArtifacts": ARTIFACTS if expected is None else expected,
                        "candidateSourceDigest": "fixture-source", "results": [entry]}
            if native_peer is not None:
                peer_raw = stage / "fixture-scores-native.json"
                peer_raw.write_text(json.dumps(native_peer))
                peer_log = stage / "fixture-scores-native.log"
                peer_log.write_text("CPU native peer fixture\n")
                peer = {"modelID": "fixture", "mode": "scores", "requestedPrecision": "native",
                        "command": [], "reportParsed": peer_parsed, "exitCode": 0 if peer_parsed else 2,
                        "jsonSHA256": digest(peer_raw), "logSHA256": digest(peer_log)}
                if include_peer:
                    manifest["results"].append(peer)
                if peer_changed:
                    peer_raw.write_text(peer_raw.read_text() + " ")
            (stage / "run.json").write_text(json.dumps(manifest))
            if raw_changed:
                raw.write_text(raw.read_text() + " ")
            output = root / "curated.json"
            result = subprocess.run(
                [sys.executable, str(SCRIPT), "--root", str(root), "--stages", "stage",
                 "--output", str(output)], capture_output=True, text=True, timeout=10)
            return result, json.loads(output.read_text()) if output.exists() else None

    def test_both_real_report_schemas_project_verified_identities(self):
        for mode, report in [("retrieval", generation()), ("scores", scores())]:
            with self.subTest(mode=mode):
                result, output = self.invoke(report, mode)
                self.assertEqual(result.returncode, 0, result.stderr)
                entry = output["stages"][0]["results"][0]
                self.assertEqual(entry["executableSHA256"], ARTIFACTS["darkbloom"])
                self.assertEqual(entry["metallibSHA256"], ARTIFACTS["mlx.metallib"])

    def test_every_completed_mode_requires_both_exact_lowercase_hashes(self):
        for mode in ("retrieval", "arithmetic", "program", "long_retrieval", "scores"):
            for field in (("executableSHA256", "metallibSHA256") if mode == "scores"
                          else ("binary_sha256", "metallib_sha256")):
                for invalid in (None, True, "c" * 64, "A" * 64, "b" * 63):
                    report = scores() if mode == "scores" else generation()
                    target = report if mode == "scores" else report["runtimeIdentity"]
                    if invalid is None:
                        del target[field]
                    else:
                        target[field] = invalid
                    with self.subTest(mode=mode, field=field, invalid=invalid):
                        result, output = self.invoke(report, mode)
                        self.assertNotEqual(result.returncode, 0)
                        self.assertIsNone(output)
                        self.assertIn("execution artifact", result.stderr.lower())

    def test_other_schema_cannot_supply_a_fallback_or_hide_a_mismatch(self):
        variants = []
        flat = scores()
        variants.append(("retrieval", flat))
        nested = generation()
        variants.append(("scores", nested))
        conflicting = generation()
        conflicting["executableSHA256"] = "c" * 64
        variants.append(("retrieval", conflicting))
        conflicting = scores()
        conflicting["runtimeIdentity"] = {"binary_sha256": "c" * 64}
        variants.append(("scores", conflicting))
        malformed = scores()
        malformed["runtimeIdentity"] = "invalid envelope"
        variants.append(("scores", malformed))
        for mode, report in variants:
            with self.subTest(mode=mode, report=report):
                result, output = self.invoke(report, mode)
                self.assertNotEqual(result.returncode, 0)
                self.assertIsNone(output)

    def test_manifest_identity_is_required_and_well_formed(self):
        for artifact in ARTIFACTS:
            expected = dict(ARTIFACTS)
            del expected[artifact]
            result, output = self.invoke(generation(), expected=expected)
            self.assertNotEqual(result.returncode, 0)
            self.assertIsNone(output)

    def test_failed_unparsed_results_are_retained_without_invented_identity(self):
        result, output = self.invoke(None, parsed=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        entry = output["stages"][0]["results"][0]
        self.assertFalse(entry["reportParsed"])
        self.assertEqual(entry["exitCode"], 2)
        self.assertNotIn("executableSHA256", entry)
        self.assertNotIn("metallibSHA256", entry)

    def test_raw_hash_drift_still_refuses_curation(self):
        result, output = self.invoke(generation(), raw_changed=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIsNone(output)
        self.assertIn("Retained evidence changed", result.stderr)

    def test_comparison_requires_a_parsed_manifest_peer(self):
        wrong = scores()
        wrong["executableSHA256"] = "c" * 64
        wrong["metallibSHA256"] = "d" * 64
        for include, parsed in [(False, True), (True, False)]:
            with self.subTest(include=include, parsed=parsed):
                result, output = self.invoke(
                    scores(), "scores", native_peer=wrong, include_peer=include, peer_parsed=parsed)
                self.assertEqual(result.returncode, 0, result.stderr)
                balanced = output["stages"][0]["results"][0]
                self.assertNotIn("nativeTop1Matches", balanced["diagnosticChecks"])
                if include:
                    peer = output["stages"][0]["results"][1]
                    self.assertFalse(peer["reportParsed"])
                    self.assertEqual(peer["exitCode"], 2)
                    self.assertNotIn("executableSHA256", peer)
        result, output = self.invoke(scores(), "scores", native_peer=scores())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(output["stages"][0]["results"][0]["diagnosticChecks"]["nativeTop1Matches"], 1)

    def test_bound_peer_hash_and_artifacts_are_checked_before_comparison(self):
        result, output = self.invoke(scores(), "scores", native_peer=scores(), peer_changed=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIsNone(output)
        self.assertIn("Retained native peer evidence changed", result.stderr)
        for field in ("executableSHA256", "metallibSHA256"):
            wrong = scores()
            wrong[field] = "c" * 64
            wrong["input"] = {"promptTokens": [99]}
            with self.subTest(field=field):
                result, output = self.invoke(scores(), "scores", native_peer=wrong)
                self.assertNotEqual(result.returncode, 0)
                self.assertIsNone(output)
                self.assertIn("Execution artifact mismatch", result.stderr)


if __name__ == "__main__":
    unittest.main()
