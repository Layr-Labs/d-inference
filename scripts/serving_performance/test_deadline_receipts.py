import copy
import hashlib
import json
import unittest

from .deadline_receipts import assemble_deadline_receipt
from .qualification_build import encode_build_record
from .posture import COOLED_DEADLINE_APPLICABILITY
from .posture_fixtures import cooldown, trial_posture
from .test_qualification_build import fixture_build_record


def run(partition, duration=1_000_000_000):
    mtp = {"enabled": True, "artifact_sha256": "f" * 64, "max_draft_tokens": 7,
           "max_speculative_batch": 8, "verification_mode": "rectangular", "max_automatic_rectangular_tokens": 0}
    runtime = {"configured_context_tokens": 262144, "effective_max_concurrency": 4, "prefill_chunk_size": 1024,
               "max_concurrent_partial_prefills": 1, "solo_prefill_stripe_tokens": 4096}
    row = {"requestID": partition, "workloadSHA256": ("a" if partition == "calibration" else "b") * 64,
        "promptTokens": 4096, "requestedOutputTokens": 128, "completionTokens": 2,
        "firstContentMs": 1100., "contentArrivalMs": [1100., 1110.], "elapsedMs": 1200., "cachedTokens": 0,
        "profile": {"running_at_admit": 0, "waiting_at_admit": 0,
                    "engine": {"prompt_computed_ns": duration + 1, "prefill_first_launch_ns": 1}}}
    report = {"buildIdentity": {"version": 1, "debugCompilationCondition": False,
        "debugAssertionsEnabled": False, "binarySHA256": "d" * 64}, "complete": True, "job": {"width": 1, "reused": False, "servingPolicy": True,
        "partition": partition, "modelID": "fixture", "artifactSHA256": "c" * 64, "runID": partition,
        "toolHistory": True}, "deadlineRuntimeConfiguration": runtime, "providerVersion": "test",
        "runtimeRevision": "cbv2-first-content-v2", "actualKVBackend": "paged", "chipName": "Apple M5 Max",
        "gpuCores": 40, "memoryBytes": 128 * 1024**3, "promptContractID": "d" * 64, "mtp": mtp,
        "trials": [{"rows": [row], "iteration": 0, "promptTarget": 4096, "thermalState": 0, "lowPowerMode": False,
            "retired": True, "mtpActive": True, "mtpRounds": 1, "mtpProposed": 1,
            "forwardShapes": {"completedStepTimings": [], "droppedStepTimings": 0,
                "droppedTokenTimings": 0, "entries": [], "confirmedTokenTimings": [
                    {"rowOrdinal": 0, "tokenCount": 1, "relativeNanos": 0},
                    {"rowOrdinal": 0, "tokenCount": 1, "relativeNanos": 10_000_000}]}}]}
    report["trials"][0]["posture"] = trial_posture()
    report["cooldowns"] = [cooldown()]
    report["preparationCooldowns"] = [cooldown()]
    posture = {"source": "ac", "mode": "automatic", "raw_mode": 0}
    provenance = {"return_code": 0, "artifact_unchanged": True, "source_unchanged": True, "binary_unchanged": True,
        "power_posture_before": posture, "power_posture_after": copy.deepcopy(posture),
        "source": {"dirty": False, "head": "a" * 40, "dependency_head": "b" * 40, "source_tree_sha256": "c" * 64},
        "build_configuration": "release", "debug_compilation_condition": False,
        "test_binaries_sha256": {"test-binary": "d" * 64}, "metallibs_sha256": {"mlx.metallib": "e" * 64}}
    provenance["build_record"] = fixture_build_record(provenance["source"], "release",
        provenance["test_binaries_sha256"], provenance["metallibs_sha256"])
    provenance["build_record_sha256"] = hashlib.sha256(encode_build_record(provenance["build_record"])).hexdigest()
    return report, provenance


def assemble(*runs):
    return assemble_deadline_receipt([(json.dumps(r).encode(), json.dumps(p).encode()) for r, p in runs],
                                     profile_id="deadline-fixture", prompt_min=4096, prompt_max=4096, checks={})


class DeadlineReceiptTests(unittest.TestCase):
    def test_plain_target_requires_observed_mtp_inactivity(self):
        training, validation = run("calibration"), run("validation")
        for report, _ in (training, validation):
            report.pop("mtp")
            report["trials"][0].update(mtpActive=False, mtpRounds=0, mtpProposed=0)
        self.assertNotIn("mtp", assemble(training, validation)["identity"])
        for field, value in (("mtpActive", True), ("mtpRounds", 1), ("mtpProposed", 1)):
            changed = copy.deepcopy(training)
            changed[0]["trials"][0][field] = value
            with self.subTest(field=field), self.assertRaisesRegex(ValueError, "unexpected_mtp"):
                assemble(changed, validation)

    def test_validation_never_selects_rates_or_expands_declared_band(self):
        value = assemble(run("calibration"), run("validation", duration=10_000_000_000))
        cell = value["deadline_calibration"]["cells"][0]
        self.assertEqual(cell["prefill_tps"], 4096)
        self.assertEqual(cell["decode_tps"], 100)
        self.assertEqual(cell["prompt_tokens_min"], 4096)
        self.assertEqual(cell["prompt_tokens_max"], 4096)
        self.assertEqual(cell["context_tokens_min"], 4129)
        self.assertEqual(cell["context_tokens_max"], 4129)
        self.assertEqual(cell["samples"][0]["context_tokens"], 4129)
        self.assertEqual(cell["samples"][0]["requested_output_tokens"], 128)
        self.assertEqual(cell["samples"][0]["decode_work_tokens"], 33)
        self.assertEqual(len(cell["samples"]), 2)
        self.assertEqual(value["identity"]["configured_context_tokens"], 262144)
        self.assertEqual(value["applicability"], COOLED_DEADLINE_APPLICABILITY)

    def test_source_power_and_cold_isolation_must_be_observed(self):
        for mutation in ("power", "trial_power", "missing_power", "changed", "warm", "busy", "incomplete", "old_runtime", "screen"):
            report, provenance = run("calibration")
            if mutation == "power": provenance["power_posture_before"]["mode"] = "high"
            elif mutation == "trial_power": report["trials"][0]["lowPowerMode"] = True
            elif mutation == "missing_power": report["trials"][0].pop("lowPowerMode")
            elif mutation == "changed": provenance["source_unchanged"] = False
            elif mutation == "warm": report["trials"][0]["rows"][0]["cachedTokens"] = 128
            elif mutation == "busy": report["trials"][0]["rows"][0]["profile"]["running_at_admit"] = 1
            elif mutation == "incomplete": report["complete"] = False
            elif mutation == "old_runtime": report.pop("deadlineRuntimeConfiguration")
            else: report["job"]["partition"] = "baseline"
            with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                assemble((report, provenance))

    def test_battery_or_unknown_automatic_power_cannot_certify_ac_deadlines(self):
        for source in ("battery", "unknown", None):
            report, provenance = run("calibration")
            for key in ("power_posture_before", "power_posture_after"):
                provenance[key]["source"] = source
            with self.subTest(source=source), self.assertRaisesRegex(ValueError, "AC power"):
                assemble((report, provenance))

    def test_mismatched_configuration_or_observation_accounting_rejects(self):
        training, validation = run("calibration"), run("validation")
        validation[0]["deadlineRuntimeConfiguration"]["effective_max_concurrency"] = 8
        with self.assertRaises(ValueError):
            assemble(training, validation)
        broken, provenance = run("calibration")
        broken["trials"][0]["rows"][0]["completionTokens"] = 3
        with self.assertRaises(ValueError):
            assemble((broken, provenance))

    def test_full_fixed_recovery_and_midtrial_nominal_evidence_are_mandatory(self):
        for mutation in ("missing", "short", "unstable", "failed", "midtrial", "before", "after"):
            report, provenance = run("calibration")
            if mutation == "missing": report.pop("cooldowns")
            elif mutation == "short": report["cooldowns"][0]["waitedMilliseconds"] = 19999
            elif mutation == "unstable": report["cooldowns"][0]["nominalStableMilliseconds"] = 4999
            elif mutation == "failed": report["cooldowns"][0]["passed"] = False
            elif mutation == "midtrial": report["trials"][0]["posture"]["worstThermalState"] = 1
            else: report["trials"][0]["posture"][mutation]["thermalState"] = 1
            with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                assemble((report, provenance))
