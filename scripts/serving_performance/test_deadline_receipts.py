import copy
import json
import unittest

from .deadline_receipts import assemble_deadline_receipt


def run(partition, duration=1_000_000_000):
    mtp = {"enabled": True, "artifact_sha256": "f" * 64, "max_draft_tokens": 7,
           "max_speculative_batch": 8, "verification_mode": "rectangular", "max_automatic_rectangular_tokens": 0}
    runtime = {"configured_context_tokens": 262144, "effective_max_concurrency": 4, "prefill_chunk_size": 1024,
               "max_concurrent_partial_prefills": 1, "solo_prefill_stripe_tokens": 4096}
    row = {"requestID": partition, "workloadSHA256": ("a" if partition == "calibration" else "b") * 64,
        "promptTokens": 4096, "requestedOutputTokens": 128, "completionTokens": 2,
        "firstContentMs": 1100., "contentArrivalMs": [1100., 1110.], "cachedTokens": 0,
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
    posture = {"source": "ac", "mode": "automatic", "raw_mode": 0}
    provenance = {"return_code": 0, "artifact_unchanged": True, "source_unchanged": True, "binary_unchanged": True,
        "power_posture_before": posture, "power_posture_after": copy.deepcopy(posture),
        "source": {"dirty": False, "head": "a" * 40, "dependency_head": "b" * 40, "source_tree_sha256": "c" * 64},
        "build_configuration": "release", "debug_compilation_condition": False,
        "test_binaries_sha256": {"test-binary": "d" * 64}, "metallibs_sha256": {"mlx.metallib": "e" * 64}}
    return report, provenance


def assemble(*runs):
    return assemble_deadline_receipt([(json.dumps(r).encode(), json.dumps(p).encode()) for r, p in runs],
                                     profile_id="deadline-fixture", prompt_min=4096, prompt_max=4096, checks={})


class DeadlineReceiptTests(unittest.TestCase):
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

    def test_mismatched_configuration_or_observation_accounting_rejects(self):
        training, validation = run("calibration"), run("validation")
        validation[0]["deadlineRuntimeConfiguration"]["effective_max_concurrency"] = 8
        with self.assertRaises(ValueError):
            assemble(training, validation)
        broken, provenance = run("calibration")
        broken["trials"][0]["rows"][0]["completionTokens"] = 3
        with self.assertRaises(ValueError):
            assemble((broken, provenance))
