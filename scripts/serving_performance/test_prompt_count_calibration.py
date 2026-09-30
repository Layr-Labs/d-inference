import hashlib
import json
import math
import unittest

from .prompt_count_calibration import evaluate_prompt_counts, SHAPE_FIELDS, EXPECTED_GROUPS
from .calibration_statistics import coverage_lower_bound
from .prompt_corpus import generate


def evidence(validation_count=59):
    observed, projected = [], []
    for group in sorted(EXPECTED_GROUPS):
        for partition, count in (("calibration", 20), ("validation", validation_count)):
            for index in range(count):
                identity = f"{partition}-{group[0]}-{group[1]}-{index}"
                work = hashlib.sha256(identity.encode()).hexdigest()
                observed.append(dict(id=identity, partition=partition, family="code", workloadSHA256=work,
                                     actualPromptTokens=1100 if partition == "calibration" else 1050))
                projected.append(dict(corpus_id=identity, workload_sha256=work, estimated_tokens=1024, shape_known=True,
                                      shape={**dict.fromkeys(SHAPE_FIELDS, 0), "body_bytes": 4096,
                                             "message_count": 2, "message_bytes": 4000}))
    return dict(modelID="fixture", artifactSHA256="a" * 64, promptContractID="b" * 64,
                observations=observed), projected


def evaluate(provider, coordinator):
    return evaluate_prompt_counts(json.dumps(provider).encode(),
                                  b"\n".join(json.dumps(row).encode() for row in coordinator))


class PromptCountCalibrationTests(unittest.TestCase):
    def test_real_count_join_fits_training_and_reports_confidence(self):
        provider, coordinator = evidence()
        report = evaluate(provider, coordinator)
        self.assertTrue(report["qualified"], report)
        candidate = report["cells"][0]["candidate"]
        self.assertEqual(candidate["validation_covered"], 59)
        self.assertGreaterEqual(candidate["tail_coverage_lower_bound"], .95)
        self.assertNotIn("observations", candidate)

    def test_exported_confidence_rounds_down_before_cross_language_validation(self):
        # These are the independent holdout population sizes in the promoted
        # corpus. At 493/500 the unrounded Python root fails Go/amd64's strict
        # tail gate despite passing Go/arm64; export a conservative decimal.
        for covered in (498, 495, 493):
            with self.subTest(covered=covered):
                provider, coordinator = evidence(validation_count=500)
                for observation in provider["observations"][-(500 - covered):]:
                    observation["actualPromptTokens"] = 2000
                report = evaluate(provider, coordinator)
                self.assertTrue(report["qualified"], report)
                candidate = report["cells"][-1]["candidate"]
                raw = coverage_lower_bound(covered, 500)
                self.assertEqual(candidate["validation_covered"], covered)
                self.assertEqual(candidate["tail_coverage_lower_bound"], math.floor(raw * 1e12) / 1e12)
                self.assertLessEqual(candidate["tail_coverage_lower_bound"], raw)

    def test_heldout_failure_never_changes_margin(self):
        provider, coordinator = evidence()
        original = evaluate(provider, coordinator)["cells"][-1]["candidate"]
        provider["observations"][-1]["actualPromptTokens"] = 2000
        changed = evaluate(provider, coordinator)
        self.assertFalse(changed["qualified"])
        for field in ("median_ratio", "upper_ratio", "upper_additive_tokens"):
            self.assertEqual(original[field], changed["cells"][-1]["candidate"][field])

    def test_observations_cannot_be_repartitioned_after_counting(self):
        provider, coordinator = evidence()
        # Exchange one row in each direction, preserving both sample counts.
        provider["observations"][0]["partition"] = "validation"
        provider["observations"][20]["partition"] = "calibration"
        report = evaluate(provider, coordinator)
        self.assertFalse(report["qualified"])
        self.assertTrue(any("predeclared corpus ID" in error for error in report["errors"]))

    def test_complete_cohort_identity_cannot_be_reassigned_after_counting(self):
        # Preserve all populations and partitions while exchanging complete
        # IDs across tools, size bands or individual rows of the same cell.
        for other_id in ("validation-tools1-band0-0", "validation-tools0-band1-0",
                         "validation-tools0-band0-1"):
            provider, coordinator = evidence()
            first = next(o for o in provider["observations"] if o["id"] == "validation-tools0-band0-0")
            second = next(o for o in provider["observations"] if o["id"] == other_id)
            first["id"], second["id"] = second["id"], first["id"]
            report = evaluate(provider, coordinator)
            with self.subTest(other_id=other_id):
                self.assertFalse(report["qualified"])
                self.assertTrue(any("canonical workload projection" in error for error in report["errors"]))

    def test_projection_requires_unique_original_corpus_ids(self):
        for mutation in ("missing", "duplicate"):
            provider, coordinator = evidence()
            if mutation == "missing":
                coordinator[0].pop("corpus_id")
            else:
                coordinator[1]["corpus_id"] = coordinator[0]["corpus_id"]
            with self.subTest(mutation=mutation):
                self.assertFalse(evaluate(provider, coordinator)["qualified"])

    def test_validation_domain_is_not_expanded_or_dropped(self):
        provider, coordinator = evidence()
        coordinator[-1]["shape"]["tool_definition_bytes"] = 100_000
        report = evaluate(provider, coordinator)
        self.assertFalse(report["qualified"])
        self.assertEqual(report["cells"][-1]["validation_out_of_domain"], 1)
        self.assertEqual(report["cells"][-1]["candidate"]["validation_samples"], 59)

    def test_every_declared_cohort_must_exist_and_qualify(self):
        provider, coordinator = evidence()
        self.assertTrue(evaluate(provider, coordinator)["qualified"])
        # Remove both matching observations and projections, so missing-pair
        # validation cannot conceal an absent declared workload cohort.
        omitted = {o["workloadSHA256"] for o in provider["observations"] if "-tools1-band2-" in o["id"]}
        provider["observations"] = [o for o in provider["observations"] if o["workloadSHA256"] not in omitted]
        coordinator = [p for p in coordinator if p["workload_sha256"] not in omitted]
        missing = evaluate(provider, coordinator)
        self.assertFalse(missing["qualified"])
        self.assertEqual(len(missing["cells"]), 5)
        self.assertTrue(all(cell["qualified"] for cell in missing["cells"]))
        self.assertTrue(any("exact six" in error for error in missing["errors"]))
        provider, coordinator = evidence()
        for observation in provider["observations"]:
            if observation["id"].startswith("validation-tools1-band2-"):
                observation["actualPromptTokens"] = 2000
        partial = evaluate(provider, coordinator)
        self.assertFalse(partial["qualified"])
        self.assertEqual(sum(cell["qualified"] for cell in partial["cells"]), 5)
        self.assertEqual(partial["errors"], [])

    def test_missing_failed_duplicate_and_unknown_workloads_fail_closed(self):
        for mutation in ("missing", "failed", "duplicate", "unknown", "incomplete_shape"):
            with self.subTest(mutation=mutation):
                provider, coordinator = evidence()
                if mutation == "missing": coordinator.pop()
                elif mutation == "failed": provider["observations"][-1]["failure"] = "template_rejected"
                elif mutation == "duplicate": provider["observations"][-1] = provider["observations"][0]
                elif mutation == "unknown": coordinator[-1]["shape_known"] = False
                else: coordinator[-1]["shape"].pop("tool_call_bytes")
                self.assertFalse(evaluate(provider, coordinator)["qualified"])

    def test_corpus_is_repeatable_but_partitions_have_distinct_content(self):
        first = generate("fixture", 1, 1)
        self.assertEqual(first, generate("fixture", 1, 1))
        generated_groups = {tuple(row["id"].split("-")[1:3]) for row in first}
        self.assertEqual(generated_groups, EXPECTED_GROUPS)
        hashes = [hashlib.sha256(row["request"].encode()).hexdigest() for row in first]
        self.assertEqual(len(set(hashes)), len(first))


if __name__ == "__main__":
    unittest.main()
