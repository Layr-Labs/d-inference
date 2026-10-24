import contextlib
import copy
import datetime
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
import uuid

import checkpoint_storage as runner
from storage_summary import compare_reports, summarize


HERE = Path(__file__).resolve().parent


def base_spec():
    return dict(modelID="local-test-model", openRouterID="test/model", directory="/local/model",
                expectedWeightHash="synthetic-weight-hash", modelType="test_model", outputPath="/unused.json",
                pairs=1, outputTokens=64, warmupIterations=1, kvBackend="paged",
                cases=[dict(name="shared", donorTokens=2048, sharedTokens=1536, forkTokens=2048, demandedTokens=1024)])


def synthetic_report(spec, pid=21, producer=None):
    base = spec["benchmark"]
    roles = (["cold_fork", "warm_full_prefill", "novel_donor", "donor", "ssd_restore", "donor_ssd_restore",
              "donor_ssd_repeat", "other_tenant", "after_cancel_restore"] if spec["phase"] in ("benchmark", "donate") else
             ["read_budget_refusal"] if spec["phase"] == "refuse" else
             ["ssd_restart_restore", "cold_fork", "warm_full_prefill", "donor_ssd_restore", "other_tenant", "after_cancel_restore"])
    benchmark = dict(modelID=base["modelID"], openRouterID=base["openRouterID"], weightHash=base["expectedWeightHash"],
                     modelType=base["modelType"], servingModelType="SyntheticModel", backend="paged",
                     cacheMode="ssd_complete", keyMode="persistent" if spec.get("keyAccessGroup") else "ephemeral",
                     mtpEnabled=False, checkpointPartition="production", strictFsync=False,
                     productionKVGrantBytes=1024, physicalMemoryBytes=8192, activationReserveBytes=2048,
                     outputTokens=base["outputTokens"], requestedLiveKVQuantization=base["liveKVQuantization"],
                     requestedCheckpointQuantization=base["checkpointQuantization"],
                     liveKVQuantization=base["liveKVQuantization"], checkpointQuantization=base["checkpointQuantization"],
                     checkpointBackendLayout="synthetic-" + base["checkpointQuantization"],
                     runtimeIdentity=dict(binary_sha256="binary", metallib_sha256="metal", normalization="n",
                                           renderer="r", tokenizer="t"),
                     schedulerConfiguration=dict(batchSize=1, enablePrefixCache=True),
                     executionStorage=dict(paged=True, quantizedGroupCount=0, supportsOrdinaryDecodeChaining=True), rows=[])
    for cell in base["cases"]:
        for pair in range(base.get("pairOffset", 0), base.get("pairOffset", 0) + base["pairs"]):
            for role in roles:
                donor = role in ("novel_donor", "donor", "donor_ssd_restore", "donor_ssd_repeat", "after_cancel_restore")
                restored = role in ("ssd_restore", "ssd_restart_restore", "donor_ssd_restore", "donor_ssd_repeat", "after_cancel_restore")
                output = ("donor" if donor else "fork") + ("-restored" if restored else "-cold")
                benchmark["rows"].append(dict(cell=cell["name"], pair=pair, role=role,
                    promptSHA256="donor-prompt" if donor else "fork-prompt", firstOutputSeconds=2.0,
                    generationTPS=16.0, terminalSeconds=6.0, receiptCompletionSeconds=7.0,
                    quiescenceCompletionSeconds=8.0, stageMilliseconds=10.0,
                    promptTokens=cell["donorTokens"] if donor else cell["forkTokens"],
                    targetTokens=cell["demandedTokens"] if role == "donor" else 0,
                    prefixCacheEnabled=role not in ("cold_fork", "warm_full_prefill"),
                    samplingRequestID=11, samplingTemperature=0, stopTokenCount=0,
                    cacheScopeSHA256=f"scope-{cell['name']}-{pair}",
                    schedulerConfiguration=dict(benchmark["schedulerConfiguration"],
                                                enablePrefixCache=role not in ("cold_fork", "warm_full_prefill")),
                    prefillRanges=[dict(lowerBound=0, upperBound=cell["demandedTokens"],
                                        plannedCap=cell["demandedTokens"], packed=False),
                                   dict(lowerBound=cell["demandedTokens"],
                                        upperBound=cell["donorTokens"] if donor else cell["forkTokens"],
                                        plannedCap=max(cell["donorTokens"], cell["forkTokens"]), packed=False)],
                    prefillChunks=2, packedPrefillChunks=0, preemptions=0, matchedTokens=0, replayTokens=0,
                    restoredTokens=cell["demandedTokens"] if restored else 0,
                    stageDisposition="staged" if restored else "miss_absent", stageConsumptionsDelta=1 if restored else 0,
                    bytesWrittenDelta=6291456 if role == "donor" else 0, filesWrittenDelta=1 if role == "donor" else 0,
                    bytesReadDelta=6291456 if restored else 0, filesReadDelta=1 if restored else 0,
                    completedOutputTokens=base["outputTokens"], outputSHA256=output,
                    checkpointWritesDrained=True, stagedBytesAfterRetirement=0, writeHostBytesAfterRetirement=0,
                    mtp=dict(qualified=True),
                    outputEventCount=2, decodeSteps=63, chainedDecodeSteps=42,
                    memoryAtPrefillCompletion=dict(observationPoint="engine_queue_prefill_completion", callbackCount=1,
                        requestID=11, promptTokens=cell["donorTokens"] if donor else cell["forkTokens"],
                        restoredTokens=cell["demandedTokens"] if restored else 0,
                        backendBytesInUse=120, backendBytesReserved=240, backendBytesCapacity=1000,
                        pagedGeneration="00000000-0000-4000-8000-000000000001",
                        pagedCommittedBytes=600, pagedLiveBytes=120, pagedReservedBytes=240),
                    publicOutput=dict(expectedMarker="ALDER-427" if donor else "BRONZE-913",
                                      containsExpectedMarker=True, tokenIDs=[1] * base["outputTokens"])))
    # Foundation encodes UUIDs in uppercase; Python normally generates lowercase.
    report = dict(runID=spec["runID"].upper(), phase=spec["phase"], processID=pid,
                  startedAt=datetime.datetime.now(datetime.timezone.utc).isoformat(),
                  artifactDirectory=str(Path(base["directory"]).resolve()), workload="synthetic-public-fixture",
                  warmupIterations=base.get("warmupIterations", 1) if spec["phase"] in ("benchmark", "donate") else 0,
                  completedIterations=len(base["cases"]) * base["pairs"], complete=True, benchmark=benchmark,
                  comparisons=[], cancellations=[], donationControlVersion=1, donationControls=[])
    for row in benchmark["rows"]:
        if row["role"] == "donor":
            control = copy.deepcopy(row)
            control.update(role="donation_control", filesWrittenDelta=0, bytesWrittenDelta=0)
            report["donationControls"].append(dict(cell=row["cell"], pair=row["pair"], controlRow=control,
                benchmark=copy.deepcopy(dict(benchmark, rows=[])), warmupIterations=report["warmupIterations"],
                cacheWitness=dict(state="ready", durableMode="ssd_complete", memoryEnabled=False,
                                  maxStageBytes=1048576, manifestAllowanceBytes=1048576, checkpointFiles=0)))
    for cell in base["cases"]:
        for pair in range(base.get("pairOffset", 0), base.get("pairOffset", 0) + base["pairs"]):
            if spec["phase"] != "refuse":
                report["cancellations"].append(dict(cell=cell["name"], pair=pair, cancellationIssued=True,
                    cancelledTerminalObserved=True, outputTokensBeforeTerminal=1, stageDisposition="staged",
                    restoredTokens=cell["demandedTokens"], stagedBytesAfterRetirement=0, writeHostBytesAfterRetirement=0,
                    filesWrittenDelta=0, bytesWrittenDelta=0,
                    memoryAfterRetirement=dict(kvBytesInUse=0, kvBytesReserved=0)))
            if spec["phase"] in ("benchmark", "donate"):
                report["comparisons"].append(dict(cell=cell["name"], pair=pair, coldMatchesRestored=False,
                    repeatedRestoreMatches=True, ttftReductionPercent=0, generationTPSChangePercent=0,
                    checkpointFileBytesWritten=6291456, restoredTokens=cell["demandedTokens"], actualSharedTokens=cell["sharedTokens"]))
    for key in ("checkpointRoot", "keyNamespaceID", "keyAccessGroup"):
        if key in spec:
            report[key] = spec[key].upper() if key == "keyNamespaceID" else spec[key]
    if spec.get("keyAccessGroup"):
        report["authenticatedArtifacts"] = [dict(position=1024, backendLayout=benchmark["checkpointBackendLayout"],
                                                  encryptedFileBytes=6291456, encodedTensorBytes=5242880)]
    if producer is not None:
        report["producerProcessID"] = producer["processID"]
    return report


def synthetic_records(pairs=1):
    jobs = runner.plan_runs(dict(base_spec(), pairs=pairs), HERE / "unused-output", ["never-executed"])
    return [dict(profile=job["profile"], step=job["step"], phase=job["spec"]["phase"],
                 status="complete", report=synthetic_report(job["spec"], 21 + index)) for index, job in enumerate(jobs)]


class PlanningTests(unittest.TestCase):
    def test_profiles_preserve_base_and_override_only_requested_fields(self):
        base = base_spec()
        original = copy.deepcopy(base)
        base.update(pairs=2, pairOffset=1, warmupIterations=3, liveKVQuantization="k8v8")
        updated = runner.validate_base(base, pairs=1, warmups=0)
        jobs = runner.plan_runs(updated, HERE / "unused-output", ["launcher", "argument with spaces"], True)
        self.assertEqual(len(jobs), 3)
        for job, (_, live, checkpoint) in zip(jobs, runner.PROFILES):
            benchmark = job["spec"]["benchmark"]
            self.assertEqual((benchmark["pairs"], benchmark["warmupIterations"]), (1, 0))
            self.assertEqual((benchmark["liveKVQuantization"], benchmark["checkpointQuantization"]), (live, checkpoint))
            self.assertEqual(benchmark["kvBackend"], original["kvBackend"])
            self.assertEqual(benchmark["cases"], original["cases"])
            self.assertFalse(benchmark["captureTokenDiagnostics"])
            self.assertNotIn("checkpointRoot", job["spec"])
            self.assertEqual(job["spec"]["phase"], "benchmark")
        self.assertEqual(base["warmupIterations"], 3)
        jobs[0]["spec"]["benchmark"]["cases"][0]["name"] = "mutated"
        self.assertEqual(jobs[1]["spec"]["benchmark"]["cases"][0]["name"], "shared")

    def test_restart_phases_have_fresh_profile_namespace_and_shared_producer(self):
        jobs = runner.plan_runs(base_spec(), HERE / "unused-output", ["launcher"], access_group="TEAM.test", refusal=True)
        self.assertEqual([job["spec"]["phase"] for job in jobs], ["donate", "restore", "refuse", "restore"] * 2)
        self.assertEqual(len({job["spec"]["runID"] for job in jobs}), 1)
        self.assertNotEqual(jobs[0]["spec"]["keyNamespaceID"], jobs[4]["spec"]["keyNamespaceID"])
        for batch in (jobs[:4], jobs[4:]):
            self.assertEqual(len({job["spec"]["checkpointRoot"] for job in batch}), 1)
            uuid.UUID(batch[0]["spec"]["keyNamespaceID"])
            for job in batch[1:]:
                self.assertEqual(job["spec"]["producerReportPath"], batch[0]["spec"]["benchmark"]["outputPath"])
                self.assertTrue(Path(job["spec"]["checkpointRoot"]).is_absolute())
        self.assertEqual(jobs[3]["step"], "restore_after_refusal")

    def test_counterbounds_and_diagnostics_rejected(self):
        for changes in (dict(pairs=0), dict(pairs=True), dict(pairs=5, pairOffset=1),
                        dict(outputTokens=31), dict(warmupIterations=6), dict(captureTokenDiagnostics=True)):
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                runner.validate_base(dict(base_spec(), **changes))

    def test_environment_drops_implicit_overrides_and_paths(self):
        inherited = dict(HOME="/home/test", PATH="/usr/bin", TMPDIR="/tmp/test", LANG="C",
                         DARKBLOOM_MEM_CAP_FRACTION="0.1", MLX_DEVICE="cpu", SWIFT_EXEC="unsafe",
                         DYLD_FRAMEWORK_PATH="unsafe", DYLD_LIBRARY_PATH="unsafe", PYTHONPATH="unsafe")
        with patch.dict(os.environ, inherited, clear=True):
            env = runner.clean_environment("/spec.json")
            self.assertEqual(set(env), {"HOME", "PATH", "TMPDIR", "LANG", "DARKBLOOM_CHECKPOINT_STORAGE_BENCHMARK",
                                       "DARKBLOOM_PREFIX_EXCLUSIVE_GPU", "DARKBLOOM_CHECKPOINT_STORAGE_SPEC"})
            explicit = runner.clean_environment("/spec.json", ["/explicit/frameworks"], ["/explicit/libraries"])
            self.assertEqual(explicit["DYLD_FRAMEWORK_PATH"], "/explicit/frameworks")
            self.assertEqual(explicit["DYLD_LIBRARY_PATH"], "/explicit/libraries")


class SummaryTests(unittest.TestCase):
    def test_median_of_paired_ratios_not_ratio_of_aggregate_medians(self):
        native, candidate = synthetic_records(pairs=2)
        left = [row for row in native["report"]["benchmark"]["rows"] if row["role"] == "cold_fork"]
        right = [row for row in candidate["report"]["benchmark"]["rows"] if row["role"] == "cold_fork"]
        left[0]["firstOutputSeconds"], left[1]["firstOutputSeconds"] = 2, 8
        right[0]["firstOutputSeconds"], right[1]["firstOutputSeconds"] = 1, 16
        left[1]["generationTPS"], right[1]["generationTPS"] = None, None
        right[0]["generationTPS"] = 32
        role = next(role for role in compare_reports(native, candidate)["roles"] if role["role"] == "cold_fork")
        self.assertEqual(role["medianCandidateOverNative"]["firstOutputSeconds"], dict(median=1.25, samples=2))
        self.assertEqual(role["medianCandidateOverNative"]["generationTPS"], dict(median=2, samples=1))

    def test_null_generation_metric_and_separate_role_medians(self):
        records = synthetic_records()
        for record in records:
            rows = record["report"]["benchmark"]["rows"]
            rows[0].update(generationTPS=None, outputEventCount=1)
            rows[1]["firstOutputSeconds"] = 100
        summary = summarize(records)
        cold = next(group for group in summary["roleMedians"] if group["profile"] == runner.PROFILES[0][0] and group["role"] == "cold_fork")
        self.assertEqual(cold["metrics"]["generationTPS"], dict(median=None, samples=0))
        self.assertEqual(cold["metrics"]["firstOutputSeconds"]["median"], 2)
        paired = next(role for role in summary["pairedComparisons"][0]["roles"] if role["role"] == "cold_fork")
        self.assertIsNone(paired["pairs"][0]["candidateOverNative"]["generationTPS"])
        self.assertIsNone(paired["pairs"][0]["candidateOverNative"]["bytesWrittenDelta"])
        self.assertEqual(paired["medianCandidateOverNative"]["firstOutputSeconds"]["median"], 1)

    def test_exact_runtime_and_control_identity_guard(self):
        mutations = [("runtimeIdentity", dict(binary_sha256="binary", metallib_sha256="different")),
                     ("runtimeIdentity", None), ("schedulerConfiguration", dict(batchSize=2)),
                     ("mtpEnabled", True), ("checkpointPartition", "other"), ("backend", "contiguous"),
                     ("weightHash", "different"), ("servingModelType", "other"), ("executionStorage", dict(paged=False))]
        for key, value in mutations:
            with self.subTest(field=key):
                native, candidate = synthetic_records()
                candidate["report"]["benchmark"][key] = value
                result = compare_reports(native, candidate)
                self.assertEqual(result["status"], "incompatible_controls")
                self.assertIn(key, result["mismatches"])
                self.assertNotIn("roles", result)

    def test_prompt_cell_pair_guard_and_duplicates_never_cross_pair(self):
        for key, value in (("promptSHA256", "other"), ("cell", "other"), ("pair", 4)):
            with self.subTest(field=key):
                native, candidate = synthetic_records()
                candidate["report"]["benchmark"]["rows"][0][key] = value
                roles = compare_reports(native, candidate)["roles"]
                self.assertNotIn("cold_fork", [role["role"] for role in roles])
        native, candidate = synthetic_records()
        candidate["report"]["benchmark"]["rows"].append(copy.deepcopy(candidate["report"]["benchmark"]["rows"][0]))
        self.assertNotIn("cold_fork", [role["role"] for role in compare_reports(native, candidate)["roles"]])

    def test_quality_divergence_is_an_observation_not_a_failure(self):
        native, candidate = synthetic_records()
        candidate["report"]["benchmark"]["rows"][0]["publicOutput"].update(tokenIDs=[1, 9], containsExpectedMarker=False)
        result = compare_reports(native, candidate)
        observation = next(role for role in result["roles"] if role["role"] == "cold_fork")["pairs"][0]["qualityObservation"]
        self.assertEqual(result["status"], "paired")
        self.assertFalse(observation["tokenIDsEqual"])
        self.assertEqual(observation["firstDivergence"], dict(index=1, nativeToken=1, candidateToken=9))
        self.assertFalse(observation["candidateContainsExpectedMarker"])

    def test_failed_or_incomplete_reports_never_enter_metrics(self):
        for failure in ("process", "report"):
            native, candidate = synthetic_records()
            if failure == "process":
                candidate["status"] = "process_failed"
            else:
                candidate["report"]["complete"] = False
            summary = summarize([native, candidate])
            self.assertNotIn("report", summary["runs"][1])
            self.assertTrue(all(group["profile"] == runner.PROFILES[0][0] for group in summary["roleMedians"]))
            self.assertEqual(summary["pairedComparisons"][0]["status"], "complete_reports_unavailable")

    def test_donation_control_timings_never_enter_performance_roles(self):
        records = synthetic_records()
        for record in records:
            control = record["report"]["donationControls"][0]["controlRow"]
            control.update(firstOutputSeconds=9999, generationTPS=9999, terminalSeconds=9999)
        summary = summarize(records)
        self.assertEqual(len(summary["roleMedians"]), 18)
        for group in summary["roleMedians"]:
            self.assertNotEqual(group["role"], "donation_control")
            self.assertEqual(group["rows"], 1)
            self.assertEqual(group["metrics"]["firstOutputSeconds"], dict(median=2, samples=1))
        self.assertEqual(len(summary["pairedComparisons"][0]["roles"]), 9)
        self.assertNotIn("donation_control", [role["role"] for role in summary["pairedComparisons"][0]["roles"]])

    def test_memory_metrics_use_only_prefill_backend_and_paged_counters(self):
        summary = summarize(synthetic_records())
        expected = {"memoryAtPrefillCompletion." + field: value for field, value in (
            ("backendBytesInUse", 120), ("backendBytesReserved", 240), ("backendBytesCapacity", 1000),
            ("pagedCommittedBytes", 600), ("pagedLiveBytes", 120), ("pagedReservedBytes", 240))}
        for group in summary["roleMedians"]:
            memory_metrics = {field: value for field, value in group["metrics"].items() if field.startswith("memory")}
            self.assertEqual(memory_metrics, {field: dict(median=value, samples=1) for field, value in expected.items()})
        for role in summary["pairedComparisons"][0]["roles"]:
            ratios = role["pairs"][0]["candidateOverNative"]
            self.assertEqual({field: value for field, value in ratios.items() if field.startswith("memory")},
                             {field: 1 for field in expected})

    def test_old_or_invalid_versions_are_masked_even_when_labelled_complete(self):
        for version in (None, 0, True, 1.0, "1", 2):
            for both in (False, True):
                with self.subTest(version=version, both=both):
                    native, candidate = synthetic_records()
                    for record in (native, candidate) if both else (candidate,):
                        if version is None:
                            del record["report"]["donationControlVersion"]
                        else:
                            record["report"]["donationControlVersion"] = version
                    comparison = compare_reports(native, candidate)
                    self.assertEqual(comparison["status"], "incompatible_controls")
                    self.assertIn("donationControlVersion", comparison["mismatches"])
                    self.assertNotIn("roles", comparison)
                    summary = summarize([native, candidate])
                    self.assertNotIn("report", summary["runs"][1])
                    self.assertEqual(len(summary["roleMedians"]), 0 if both else 9)
                    self.assertEqual(summary["pairedComparisons"][0]["status"], "complete_reports_unavailable")
        for version in (True, 1.0):
            with self.subTest(equal_copy_version=version):
                native, candidate = synthetic_records()
                invalid = copy.deepcopy(candidate)
                invalid["report"]["donationControlVersion"] = version
                summary = summarize([native, candidate, invalid])
                self.assertIn("report", summary["runs"][1])
                self.assertNotIn("report", summary["runs"][2])
                self.assertEqual(len(summary["roleMedians"]), 18)
                self.assertTrue(all(group["rows"] == 1 for group in summary["roleMedians"]))


class ReportEvidenceTests(unittest.TestCase):
    def evidence(self, phase="benchmark", base=None):
        jobs = runner.plan_runs(base or base_spec(), HERE / "unused-output", ["never-executed"],
                                access_group="TEAM.test" if phase != "benchmark" else None, refusal=phase == "refuse")
        spec = next(job["spec"] for job in jobs if job["spec"]["phase"] == phase)
        producer = synthetic_report(jobs[0]["spec"]) if phase in ("restore", "refuse") else None
        return spec, synthetic_report(spec, 22, producer), producer

    def test_exact_phase_coverage_accepts_multiple_cells_and_offset_pairs(self):
        base = dict(base_spec(), pairs=2, pairOffset=2)
        base["cases"].append(dict(base["cases"][0], name="second"))
        for phase, count in (("benchmark", 9), ("donate", 9), ("restore", 6), ("refuse", 1)):
            with self.subTest(phase=phase):
                spec, report, producer = self.evidence(phase, base)
                self.assertEqual(len(report["benchmark"]["rows"]), count * 4)
                self.assertEqual(len(report["donationControls"]), 4 if phase in ("benchmark", "donate") else 0)
                self.assertIsNone(runner.report_problem(report, spec, producer))

    def test_matched_control_accepts_novel_donor_output_divergence(self):
        for phase in ("benchmark", "donate"):
            with self.subTest(phase=phase):
                spec, report, producer = self.evidence(phase)
                novel = next(row for row in report["benchmark"]["rows"] if row["role"] == "novel_donor")
                donor = next(row for row in report["benchmark"]["rows"] if row["role"] == "donor")
                control = report["donationControls"][0]
                novel["outputSHA256"] = "diagnostic-with-different-prefill-geometry"
                self.assertEqual(novel["targetTokens"], 0)
                self.assertGreater(control["controlRow"]["targetTokens"], 0)
                self.assertEqual(control["controlRow"]["outputSHA256"], donor["outputSHA256"])
                self.assertEqual(control["benchmark"]["rows"], [])
                self.assertNotIn(control["controlRow"], report["benchmark"]["rows"])
                self.assertIsNone(runner.report_problem(report, spec, producer))

    def test_every_phase_requires_integer_donation_control_version_one(self):
        for phase in ("benchmark", "donate", "restore", "refuse"):
            spec, original, producer = self.evidence(phase)
            for version in (None, 0, True, 1.0, "1", 2):
                with self.subTest(phase=phase, version=version):
                    report = copy.deepcopy(original)
                    if version is None:
                        del report["donationControlVersion"]
                    else:
                        report["donationControlVersion"] = version
                    self.assertIn("donationControlVersion", runner.report_problem(report, spec, producer))
                    self.assertIn("donationControlVersion", runner.report_evidence_problem(report, spec, producer))

    def test_every_phase_requires_a_donation_controls_array(self):
        for phase in ("benchmark", "donate", "restore", "refuse"):
            spec, original, producer = self.evidence(phase)
            for value in (None, {}, "controls"):
                with self.subTest(phase=phase, value=value):
                    report = copy.deepcopy(original)
                    report["donationControls"] = value
                    self.assertIn("donation controls", runner.report_evidence_problem(report, spec, producer))
            report = copy.deepcopy(original)
            del report["donationControls"]
            self.assertIn("donation controls", runner.report_problem(report, spec, producer))

    def test_donation_controls_require_exact_cell_pair_and_row_identity(self):
        base = dict(base_spec(), pairs=2, pairOffset=2)
        base["cases"].append(dict(base["cases"][0], name="second"))
        for phase in ("benchmark", "donate"):
            spec, original, producer = self.evidence(phase, base)
            for change in ("missing", "missing_cell", "duplicate", "wrong_cell", "wrong_pair", "bool_pair",
                           "invalid_object", "row_missing", "row_cell", "row_pair", "row_bool_pair", "row_role"):
                with self.subTest(phase=phase, change=change):
                    report = copy.deepcopy(original)
                    controls = report["donationControls"]
                    if change == "missing":
                        controls.pop()
                    elif change == "missing_cell":
                        report["donationControls"] = [control for control in controls if control["cell"] != "second"]
                    elif change == "duplicate":
                        controls.append(copy.deepcopy(controls[0]))
                    elif change == "invalid_object":
                        controls[0] = None
                    elif change == "row_missing":
                        del controls[0]["controlRow"]
                    elif change.startswith("row_"):
                        field, value = {"row_cell": ("cell", "other"), "row_pair": ("pair", 4),
                                        "row_bool_pair": ("pair", True), "row_role": ("role", "donor")}[change]
                        controls[0]["controlRow"][field] = value
                    else:
                        field, value = {"wrong_cell": ("cell", "other"), "wrong_pair": ("pair", 4),
                                        "bool_pair": ("pair", True)}[change]
                        controls[0][field] = value
                    self.assertIsNotNone(runner.report_evidence_problem(report, spec, producer))
        for phase in ("restore", "refuse"):
            spec, report, producer = self.evidence(phase)
            report["donationControls"] = copy.deepcopy(producer["donationControls"])
            self.assertIsNotNone(runner.report_evidence_problem(report, spec, producer))

    def test_referenced_donor_requires_versioned_matched_evidence(self):
        for phase in ("restore", "refuse"):
            spec, report, original = self.evidence(phase)
            for change in ("version_missing", "version_zero", "missing", "duplicate", "wrong_key", "output", "cache"):
                with self.subTest(phase=phase, change=change):
                    producer = copy.deepcopy(original)
                    if change == "version_missing":
                        del producer["donationControlVersion"]
                    elif change == "version_zero":
                        producer["donationControlVersion"] = 0
                    elif change == "missing":
                        producer["donationControls"] = []
                    elif change == "duplicate":
                        producer["donationControls"] *= 2
                    elif change == "wrong_key":
                        producer["donationControls"][0]["pair"] = 4
                    elif change == "output":
                        producer["donationControls"][0]["controlRow"]["outputSHA256"] = "different-full-output"
                    else:
                        producer["donationControls"][0]["cacheWitness"]["checkpointFiles"] = 1
                    self.assertIn("invalid donor report", runner.report_problem(report, spec, producer))
                    self.assertIn("invalid donor report", runner.report_evidence_problem(report, spec, producer))

    def test_control_and_donor_require_identical_full_output_prompt_scope_and_target(self):
        spec, original, producer = self.evidence()
        for field, value in (("outputSHA256", "different-complete-output"), ("promptSHA256", "different-prompt"),
                             ("cacheScopeSHA256", "different-scope"), ("targetTokens", 1025)):
            for side in ("control", "donor"):
                with self.subTest(field=field, side=side):
                    report = copy.deepcopy(original)
                    row = (report["donationControls"][0]["controlRow"] if side == "control" else
                           next(row for row in report["benchmark"]["rows"] if row["role"] == "donor"))
                    row[field] = value
                    self.assertIn(field, runner.report_problem(report, spec, producer))
        report = copy.deepcopy(original)
        control = report["donationControls"][0]["controlRow"]
        donor = next(row for row in report["benchmark"]["rows"] if row["role"] == "donor")
        control["targetTokens"] = donor["targetTokens"] = 1025
        self.assertIn("targetTokens", runner.report_problem(report, spec, producer))

    def test_matched_donation_request_fields_are_required_and_strict(self):
        invalid = {"targetTokens": (None, 0, -1, True, 1024.0), "promptTokens": (None, 0, -1, True, 2048.0),
                   "prefixCacheEnabled": (None, False, 1), "samplingRequestID": (None, 12, True, 11.0),
                   "samplingTemperature": (None, 0.1, False, "0"), "stopTokenCount": (None, 1, False, 0.0),
                   "schedulerConfiguration": (None, {}, dict(batchSize=2, enablePrefixCache=True),
                                              dict(batchSize=1, enablePrefixCache=False)),
                   "promptSHA256": (None, "", " "), "outputSHA256": (None, "", " "),
                   "cacheScopeSHA256": (None, "", " ")}
        spec, original, producer = self.evidence()
        for side in ("control", "donor"):
            for field, values in invalid.items():
                for value in values:
                    with self.subTest(side=side, field=field, value=value):
                        report = copy.deepcopy(original)
                        row = (report["donationControls"][0]["controlRow"] if side == "control" else
                               next(row for row in report["benchmark"]["rows"] if row["role"] == "donor"))
                        if value is None:
                            del row[field]
                        else:
                            row[field] = value
                        self.assertIsNotNone(runner.report_problem(report, spec, producer))

    def test_matched_actual_prompt_counts_can_exceed_floors_and_caps_can_be_omitted(self):
        spec, report, producer = self.evidence()
        control = report["donationControls"][0]["controlRow"]
        donor = next(row for row in report["benchmark"]["rows"] if row["role"] == "donor")
        for row in (control, donor):
            row["promptTokens"] += 17
            row["prefillRanges"][-1]["upperBound"] = row["promptTokens"]
            row["samplingTemperature"] = 0.0
            for interval in row["prefillRanges"]:
                del interval["plannedCap"]
        self.assertGreater(donor["promptTokens"], spec["benchmark"]["cases"][0]["donorTokens"])
        self.assertIsNone(runner.report_problem(report, spec, producer))
        control["promptTokens"] += 1
        control["prefillRanges"][-1]["upperBound"] += 1
        self.assertIn("promptTokens", runner.report_problem(report, spec, producer))

    def test_equal_chunk_counts_do_not_prove_identical_prefill_partition(self):
        spec, original, producer = self.evidence()
        for side in ("control", "donor"):
            for change in ("boundary", "cap"):
                with self.subTest(side=side, change=change):
                    report = copy.deepcopy(original)
                    row = (report["donationControls"][0]["controlRow"] if side == "control" else
                           next(row for row in report["benchmark"]["rows"] if row["role"] == "donor"))
                    if change == "boundary":
                        row["prefillRanges"][0].update(upperBound=1025, plannedCap=2048)
                        row["prefillRanges"][1]["lowerBound"] = 1025
                    else:
                        row["prefillRanges"][0]["plannedCap"] += 1
                    self.assertEqual(row["prefillChunks"], len(row["prefillRanges"]))
                    self.assertIn("prefillRanges", runner.report_problem(report, spec, producer))

    def test_identical_traces_still_require_contiguous_in_range_unpacked_coverage(self):
        spec, original, producer = self.evidence()
        first, last = original["donationControls"][0]["controlRow"]["prefillRanges"]
        traces = [None, [], {}, [None, last], [dict(first, lowerBound=-1), last],
                  [dict(first, lowerBound=1), last], [first, dict(last, lowerBound=1025)],
                  [first, dict(last, lowerBound=1023)], [first, dict(last, upperBound=2049)],
                  [first, dict(last, upperBound=2047)], [dict(first, upperBound=0), last],
                  [dict(first, lowerBound=0.0), last], [dict(first, upperBound=True), last],
                  [dict(first, packed=True), last], [dict(first, packed=0), last]]
        for missing in ("lowerBound", "upperBound", "packed"):
            interval = dict(first)
            del interval[missing]
            traces.append([interval, last])
        for value in (None, 0, -1, 1023, True, 1024.0, "1024"):
            traces.append([dict(first, plannedCap=value), last])
        for trace in traces:
            with self.subTest(trace=trace):
                report = copy.deepcopy(original)
                control = report["donationControls"][0]["controlRow"]
                donor = next(row for row in report["benchmark"]["rows"] if row["role"] == "donor")
                control["prefillRanges"] = copy.deepcopy(trace)
                donor["prefillRanges"] = copy.deepcopy(trace)
                self.assertIsNotNone(runner.report_problem(report, spec, producer))

    def test_trace_counts_preemptions_and_packed_chunks_are_strict(self):
        spec, original, producer = self.evidence()
        for side in ("control", "donor"):
            for field, values in (("prefillChunks", (None, 0, 1, 3, True, 2.0)),
                                  ("preemptions", (None, 1, -1, False, 0.0)),
                                  ("packedPrefillChunks", (None, 1, -1, False, 0.0))):
                for value in values:
                    with self.subTest(side=side, field=field, value=value):
                        report = copy.deepcopy(original)
                        row = (report["donationControls"][0]["controlRow"] if side == "control" else
                               next(row for row in report["benchmark"]["rows"] if row["role"] == "donor"))
                        if value is None:
                            del row[field]
                        else:
                            row[field] = value
                        self.assertIsNotNone(runner.report_problem(report, spec, producer))

    def test_control_requires_real_cache_state_caps_and_no_artifacts(self):
        spec, original, producer = self.evidence()
        changes = {"state": "disabled", "durableMode": "memory", "memoryEnabled": True,
                   "maxStageBytes": 2097152, "manifestAllowanceBytes": 0, "checkpointFiles": 1}
        for field, value in changes.items():
            for missing in (False, True):
                with self.subTest(field=field, missing=missing):
                    report = copy.deepcopy(original)
                    witness = report["donationControls"][0]["cacheWitness"]
                    if missing:
                        del witness[field]
                    else:
                        witness[field] = value
                    self.assertIn("cache witness", runner.report_problem(report, spec, producer))
        for witness in (None, {}, "ready", dict(original["donationControls"][0]["cacheWitness"], memoryEnabled=0),
                        dict(original["donationControls"][0]["cacheWitness"], checkpointFiles=False),
                        dict(original["donationControls"][0]["cacheWitness"], maxStageBytes=1048576.0)):
            with self.subTest(witness=witness):
                report = copy.deepcopy(original)
                report["donationControls"][0]["cacheWitness"] = witness
                self.assertIn("cache witness", runner.report_problem(report, spec, producer))

    def test_matched_control_and_treatment_require_complete_retirement_and_correct_io(self):
        spec, original, producer = self.evidence()
        zero_fields = ("filesReadDelta", "bytesReadDelta", "restoredTokens", "matchedTokens", "replayTokens",
                       "stageConsumptionsDelta", "stagedBytesAfterRetirement", "writeHostBytesAfterRetirement")
        changes = [{field: value} for field in zero_fields for value in (None, 1, -1, False)]
        changes += [dict(completedOutputTokens=value) for value in (None, 0, 63, 65, True, 64.0)]
        changes += [dict(checkpointWritesDrained=False), dict(mtp=None), dict(mtp=dict(qualified=False))]
        for side in ("control", "donor"):
            writes = [{field: value} for field in ("filesWrittenDelta", "bytesWrittenDelta")
                      for value in ((None, 1, -1, False) if side == "control" else (None, 0, -1, True))]
            for change in changes + writes:
                with self.subTest(side=side, change=change):
                    report = copy.deepcopy(original)
                    row = (report["donationControls"][0]["controlRow"] if side == "control" else
                           next(row for row in report["benchmark"]["rows"] if row["role"] == "donor"))
                    row.update(change)
                    self.assertIsNotNone(runner.report_problem(report, spec, producer))

    def test_control_metadata_must_match_main_and_keep_rows_empty(self):
        spec, original, producer = self.evidence("donate")
        fields = ("modelID", "openRouterID", "weightHash", "modelType", "servingModelType", "backend",
                  "runtimeIdentity", "cacheMode", "keyMode", "mtpEnabled", "checkpointPartition", "strictFsync",
                  "productionKVGrantBytes", "physicalMemoryBytes", "activationReserveBytes", "outputTokens",
                  "schedulerConfiguration", "requestedLiveKVQuantization", "requestedCheckpointQuantization",
                  "liveKVQuantization", "checkpointQuantization", "checkpointBackendLayout", "executionStorage")
        for field in fields:
            for missing in (False, True):
                with self.subTest(field=field, missing=missing):
                    report = copy.deepcopy(original)
                    metadata = report["donationControls"][0]["benchmark"]
                    if missing:
                        del metadata[field]
                    else:
                        metadata[field] = "different"
                    self.assertIn(field, runner.report_problem(report, spec, producer))
        report = copy.deepcopy(original)
        report["donationControls"][0]["benchmark"]["backendFallback"] = "fallback"
        self.assertIn("backendFallback", runner.report_problem(report, spec, producer))
        for identity in (None, dict(name="other")):
            with self.subTest(assistantIdentity=identity):
                report = copy.deepcopy(original)
                report["benchmark"]["assistantIdentity"] = dict(name="assistant")
                if identity is not None:
                    report["donationControls"][0]["benchmark"]["assistantIdentity"] = identity
                self.assertIn("assistantIdentity", runner.report_problem(report, spec, producer))
        report = copy.deepcopy(original)
        report["benchmark"]["assistantIdentity"] = dict(name="assistant")
        report["donationControls"][0]["benchmark"]["assistantIdentity"] = dict(name="assistant")
        self.assertIsNone(runner.report_problem(report, spec, producer))
        for rows in (None, {}, original["benchmark"]["rows"]):
            with self.subTest(rows=rows):
                report = copy.deepcopy(original)
                if rows is None:
                    del report["donationControls"][0]["benchmark"]["rows"]
                else:
                    report["donationControls"][0]["benchmark"]["rows"] = rows
                self.assertIn("row-empty", runner.report_problem(report, spec, producer))
        for value in (None, 0, 2, True, 1.0):
            with self.subTest(warmups=value):
                report = copy.deepcopy(original)
                report["donationControls"][0]["warmupIterations"] = value
                self.assertIn("warmupIterations", runner.report_problem(report, spec, producer))

    def test_artifact_directory_accepts_equivalent_symlink_paths(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            target = root / "model"
            target.mkdir()
            alias = root / "model-alias"
            alias.symlink_to(target, target_is_directory=True)
            for requested, reported in ((target, alias), (alias, target)):
                with self.subTest(requested=requested, reported=reported):
                    base = dict(base_spec(), directory=str(requested))
                    spec, report, producer = self.evidence(base=base)
                    report["artifactDirectory"] = str(reported)
                    self.assertIsNone(runner.report_problem(report, spec, producer))

    def test_artifact_directory_rejects_distinct_or_nonabsolute_paths(self):
        spec, original, producer = self.evidence()
        for directory in (None, "", "local/model", "/different/model"):
            with self.subTest(directory=directory):
                report = copy.deepcopy(original)
                report["artifactDirectory"] = directory
                expected = ("report artifact directory differs from requested model" if directory
                            else "missing actual model/runtime/backend/storage identity")
                self.assertEqual(runner.report_problem(report, spec, producer), expected)

    def test_artifact_directory_resolution_errors_remain_invalid(self):
        spec, report, producer = self.evidence()
        for error in (OSError("unresolvable"), RuntimeError("symlink loop")):
            for resolving_expected in (False, True):
                with self.subTest(error=type(error).__name__, resolving_expected=resolving_expected):
                    results = [Path(report["artifactDirectory"]), error] if resolving_expected else [error]
                    with patch.object(runner.Path, "resolve", side_effect=results):
                        self.assertEqual(runner.report_problem(report, spec, producer),
                                         "report artifact directory cannot be resolved")

    def test_missing_duplicate_unknown_and_wrong_pair_rows_rejected(self):
        for phase in ("benchmark", "donate", "restore", "refuse"):
            for change in ("missing", "duplicate", "unknown_role", "wrong_pair", "wrong_cell", "single_row"):
                if phase == "refuse" and change == "single_row":
                    continue
                with self.subTest(phase=phase, change=change):
                    spec, report, producer = self.evidence(phase)
                    rows = report["benchmark"]["rows"]
                    if change == "missing":
                        rows.pop()
                    elif change == "duplicate":
                        rows.append(copy.deepcopy(rows[0]))
                    elif change == "single_row":
                        report["benchmark"]["rows"] = rows[:1]
                    else:
                        rows[0][{"unknown_role": "role", "wrong_pair": "pair", "wrong_cell": "cell"}[change]] = (
                            4 if change == "wrong_pair" else "unknown")
                    self.assertIsNotNone(runner.report_problem(report, spec, producer))

    def test_missing_entire_cell_rejected_despite_complete_iteration_counter(self):
        base = base_spec()
        base["cases"].append(dict(base["cases"][0], name="second"))
        spec, report, producer = self.evidence(base=base)
        report["benchmark"]["rows"] = [row for row in report["benchmark"]["rows"] if row["cell"] != "second"]
        self.assertIsNotNone(runner.report_problem(report, spec, producer))

    def test_ssd_roles_require_actual_staging_reads_and_live_backend_memory(self):
        for phase in ("benchmark", "restore"):
            spec, original, producer = self.evidence(phase)
            for role in (row["role"] for row in original["benchmark"]["rows"] if "ssd" in row["role"] or row["role"] == "after_cancel_restore"):
                for change in (dict(filesReadDelta=0), dict(bytesReadDelta=0), dict(stageDisposition="miss_absent"),
                               dict(stageConsumptionsDelta=0), dict(restoredTokens=0), dict(restoredTokens=2048),
                               dict(memoryAtPrefillCompletion=dict(backendBytesInUse=0))):
                    with self.subTest(phase=phase, role=role, change=change):
                        report = copy.deepcopy(original)
                        next(row for row in report["benchmark"]["rows"] if row["role"] == role).update(change)
                        self.assertIsNotNone(runner.report_problem(report, spec, producer))

    def test_ssd_memory_requires_exact_prefill_event_and_row_linkage(self):
        invalid = {"observationPoint": (None, "first_output", ""), "callbackCount": (None, 0, 2, True, 1.0),
                   "requestID": (None, 0, 12, True, 11.0), "promptTokens": (None, 0, 2047, True, 2048.0),
                   "restoredTokens": (None, 0, 1023, True, 1024.0)}
        for phase in ("benchmark", "donate", "restore"):
            spec, original, producer = self.evidence(phase)
            roles = [row["role"] for row in original["benchmark"]["rows"]
                     if "ssd" in row["role"] or row["role"] == "after_cancel_restore"]
            for role in roles:
                for field, values in invalid.items():
                    for value in values:
                        with self.subTest(phase=phase, role=role, field=field, value=value):
                            report = copy.deepcopy(original)
                            memory = next(row for row in report["benchmark"]["rows"]
                                          if row["role"] == role)["memoryAtPrefillCompletion"]
                            if value is None:
                                del memory[field]
                            else:
                                memory[field] = value
                            self.assertIsNotNone(runner.report_problem(report, spec, producer))
                for request_id in (None, 12, True, 11.0):
                    with self.subTest(phase=phase, role=role, samplingRequestID=request_id):
                        report = copy.deepcopy(original)
                        row = next(row for row in report["benchmark"]["rows"] if row["role"] == role)
                        if request_id is None:
                            del row["samplingRequestID"]
                        else:
                            row["samplingRequestID"] = request_id
                            row["memoryAtPrefillCompletion"]["requestID"] = request_id
                        self.assertIsNotNone(runner.report_problem(report, spec, producer))

    def test_ssd_prefill_memory_requires_backend_counters_and_rejects_stale_gauges(self):
        invalid = {"backendBytesInUse": (None, 0, -1, True, 120.0),
                   "backendBytesReserved": (None, -1, False, 240.0),
                   "backendBytesCapacity": (None, 0, -1, True, 1000.0),
                   "pagedCommittedBytes": (None, -1, False, 600.0),
                   "pagedLiveBytes": (None, -1, False, 120.0),
                   "pagedReservedBytes": (None, -1, False, 240.0),
                   "pagedGeneration": (None, "", "not-a-uuid", 11, True)}
        for phase in ("benchmark", "donate", "restore"):
            spec, original, producer = self.evidence(phase)
            for field, values in invalid.items():
                for value in values:
                    with self.subTest(phase=phase, field=field, value=value):
                        report = copy.deepcopy(original)
                        row = next(row for row in report["benchmark"]["rows"] if "ssd" in row["role"])
                        memory = row["memoryAtPrefillCompletion"]
                        if value is None and field.startswith("backend"):
                            del memory[field]
                        else:
                            memory[field] = value
                        self.assertIsNotNone(runner.report_problem(report, spec, producer))
            for field in ("kvBytesInUse", "kvBytesReserved", "kvBytesCapacity"):
                with self.subTest(phase=phase, forbidden=field):
                    report = copy.deepcopy(original)
                    row = next(row for row in report["benchmark"]["rows"] if "ssd" in row["role"])
                    row["memoryAtPrefillCompletion"][field] = 0
                    self.assertIsNotNone(runner.report_problem(report, spec, producer))

    def test_old_memory_snapshot_cannot_replace_prefill_completion_evidence(self):
        for phase in ("benchmark", "donate", "restore"):
            spec, original, producer = self.evidence(phase)
            roles = [row["role"] for row in original["benchmark"]["rows"]
                     if "ssd" in row["role"] or row["role"] == "after_cancel_restore"]
            for role in roles:
                for missing in (True, False):
                    with self.subTest(phase=phase, role=role, old_field_only=missing):
                        report = copy.deepcopy(original)
                        row = next(row for row in report["benchmark"]["rows"] if row["role"] == role)
                        row["memoryAtFirstOutput"] = dict(backendBytesInUse=1000, backendBytesReserved=0,
                                                         backendBytesCapacity=2000)
                        if missing:
                            del row["memoryAtPrefillCompletion"]
                        else:
                            row["memoryAtPrefillCompletion"] = None
                        self.assertIsNotNone(runner.report_problem(report, spec, producer))

    def test_ssd_prefill_memory_allows_absent_paging_and_zero_reservations(self):
        for phase in ("benchmark", "donate", "restore"):
            spec, report, producer = self.evidence(phase)
            for row in report["benchmark"]["rows"]:
                memory = row["memoryAtPrefillCompletion"]
                memory["backendBytesReserved"] = 0
                for field in ("pagedGeneration", "pagedCommittedBytes", "pagedLiveBytes", "pagedReservedBytes"):
                    del memory[field]
            self.assertIsNone(runner.report_problem(report, spec, producer))

    def test_every_row_requires_exact_output_and_complete_retirement(self):
        spec, original, producer = self.evidence()
        for role in (row["role"] for row in original["benchmark"]["rows"]):
            for change in (dict(completedOutputTokens=63), dict(checkpointWritesDrained=False),
                           dict(stagedBytesAfterRetirement=1), dict(writeHostBytesAfterRetirement=1), dict(mtp=dict(qualified=False))):
                with self.subTest(role=role, change=change):
                    report = copy.deepcopy(original)
                    next(row for row in report["benchmark"]["rows"] if row["role"] == role).update(change)
                    self.assertIsNotNone(runner.report_problem(report, spec, producer))

    def test_donor_writes_and_cold_control_zero_io_are_required(self):
        spec, original, producer = self.evidence()
        for role in (row["role"] for row in original["benchmark"]["rows"]):
            fields = ["filesWrittenDelta", "bytesWrittenDelta"]
            if role in ("cold_fork", "warm_full_prefill", "novel_donor", "donor", "other_tenant"):
                fields += ["restoredTokens", "stageConsumptionsDelta", "filesReadDelta", "bytesReadDelta"]
            for field in fields:
                with self.subTest(role=role, field=field):
                    report = copy.deepcopy(original)
                    next(row for row in report["benchmark"]["rows"] if row["role"] == role)[field] = (
                        0 if role == "donor" and field in ("filesWrittenDelta", "bytesWrittenDelta") else 1)
                    self.assertIsNotNone(runner.report_problem(report, spec, producer))

    def test_cancellation_coverage_and_retirement_witness_required(self):
        for phase in ("benchmark", "donate", "restore"):
            spec, original, producer = self.evidence(phase)
            for change in ("missing", "duplicate", "wrong_pair", dict(cancellationIssued=False), dict(cancelledTerminalObserved=False),
                           dict(stageDisposition="miss_absent"), dict(restoredTokens=0), dict(stagedBytesAfterRetirement=1),
                           dict(writeHostBytesAfterRetirement=1), dict(memoryAfterRetirement=dict(kvBytesInUse=1, kvBytesReserved=0)),
                           dict(memoryAfterRetirement=dict(kvBytesInUse=0, kvBytesReserved=1))):
                with self.subTest(phase=phase, change=change):
                    report = copy.deepcopy(original)
                    if change == "missing":
                        report["cancellations"] = []
                    elif change == "duplicate":
                        report["cancellations"] *= 2
                    elif change == "wrong_pair":
                        report["cancellations"][0]["pair"] = 4
                    else:
                        report["cancellations"][0].update(change)
                    self.assertIsNotNone(runner.report_problem(report, spec, producer))
        spec, report, producer = self.evidence("refuse")
        report["cancellations"] = copy.deepcopy(producer["cancellations"])
        self.assertIsNotNone(runner.report_problem(report, spec, producer))

    def test_cancellation_requires_positive_observed_output_tokens(self):
        for phase in ("benchmark", "donate", "restore"):
            spec, original, producer = self.evidence(phase)
            for token_count in (0, -1, True, 1.5, "1", None):
                with self.subTest(phase=phase, token_count=token_count):
                    report = copy.deepcopy(original)
                    report["cancellations"][0]["outputTokensBeforeTerminal"] = token_count
                    self.assertIsNotNone(runner.report_problem(report, spec, producer))
            with self.subTest(phase=phase, missing=True):
                report = copy.deepcopy(original)
                del report["cancellations"][0]["outputTokensBeforeTerminal"]
                self.assertIsNotNone(runner.report_problem(report, spec, producer))

    def test_cancellation_cannot_publish_checkpoint_writes(self):
        for phase in ("benchmark", "donate", "restore"):
            spec, original, producer = self.evidence(phase)
            for field in ("filesWrittenDelta", "bytesWrittenDelta"):
                for value in (None, True, -1, 1):
                    with self.subTest(phase=phase, field=field, value=value):
                        report = copy.deepcopy(original)
                        report["cancellations"][0][field] = value
                        self.assertIsNotNone(runner.report_problem(report, spec, producer))

    def test_persistent_artifacts_need_positive_encoded_and_encrypted_bytes_and_layout(self):
        for phase in ("donate", "restore", "refuse"):
            spec, original, producer = self.evidence(phase)
            for change in ("missing", "empty", dict(encodedTensorBytes=0), dict(encryptedFileBytes=0), dict(backendLayout="other")):
                with self.subTest(phase=phase, change=change):
                    report = copy.deepcopy(original)
                    if change == "missing":
                        del report["authenticatedArtifacts"]
                    elif change == "empty":
                        report["authenticatedArtifacts"] = []
                    else:
                        report["authenticatedArtifacts"][0].update(change)
                    self.assertIsNotNone(runner.report_problem(report, spec, producer))

    def test_refusal_allows_read_attempts_but_requires_cap_exercising_producer(self):
        spec, report, producer = self.evidence("refuse")
        report["benchmark"]["rows"][0].update(filesReadDelta=1, bytesReadDelta=32, stageDisposition="skipped_capacity")
        self.assertIsNone(runner.report_problem(report, spec, producer))
        for size in (2 << 20, (2 << 20) - 1):
            source = copy.deepcopy(producer)
            source["authenticatedArtifacts"].append(dict(source["authenticatedArtifacts"][0], encryptedFileBytes=size))
            self.assertIsNotNone(runner.report_problem(report, spec, source))
        for change in (dict(restoredTokens=1), dict(stageConsumptionsDelta=1), dict(stageDisposition="staged"), dict(bytesWrittenDelta=1)):
            invalid = copy.deepcopy(report)
            invalid["benchmark"]["rows"][0].update(change)
            self.assertIsNotNone(runner.report_problem(invalid, spec, producer))

    def test_same_prompt_and_same_profile_output_hashes_not_cold_lossy_equality(self):
        spec, original, producer = self.evidence()
        self.assertIsNone(runner.report_problem(original, spec, producer))
        for role in ("warm_full_prefill", "other_tenant", "donor_ssd_repeat", "after_cancel_restore"):
            with self.subTest(role=role):
                report = copy.deepcopy(original)
                next(row for row in report["benchmark"]["rows"] if row["role"] == role)["outputSHA256"] = "mismatch"
                self.assertIsNotNone(runner.report_problem(report, spec, producer))
        for role in (row["role"] for row in original["benchmark"]["rows"]):
            with self.subTest(prompt_role=role):
                report = copy.deepcopy(original)
                next(row for row in report["benchmark"]["rows"] if row["role"] == role)["promptSHA256"] = "mismatch"
                self.assertIsNotNone(runner.report_problem(report, spec, producer))

    def test_restart_output_and_prompt_link_to_corresponding_producer_rows(self):
        spec, original, producer = self.evidence("restore")
        for role, field in (("ssd_restart_restore", "outputSHA256"), ("ssd_restart_restore", "promptSHA256"),
                            ("donor_ssd_restore", "outputSHA256"), ("donor_ssd_restore", "promptSHA256")):
            with self.subTest(role=role, field=field):
                source = copy.deepcopy(producer)
                source_role = "ssd_restore" if role == "ssd_restart_restore" else role
                next(row for row in source["benchmark"]["rows"] if row["role"] == source_role)[field] = "changed"
                self.assertIsNotNone(runner.report_problem(original, spec, source))

    def test_restart_allows_equal_second_timestamps_but_not_earlier_start(self):
        spec, report, producer = self.evidence("restore")
        producer["startedAt"] = report["startedAt"] = "2026-10-09T12:00:00Z"
        self.assertNotEqual(report["processID"], producer["processID"])
        self.assertIsNone(runner.report_problem(report, spec, producer))
        report["startedAt"] = "2026-10-09T11:59:59Z"
        self.assertIsNotNone(runner.report_problem(report, spec, producer))


class ExecutionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix=".unittest-", dir=HERE)
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.base_path = self.directory / "base.json"
        runner.write_json(self.base_path, base_spec())
        self.output = self.directory / "result"

    def invoke(self, *extra):
        with contextlib.redirect_stdout(io.StringIO()) as output:
            result = runner.main(["--spec", str(self.base_path), "--output-dir", str(self.output), "--root", str(HERE), *extra])
        return result, output.getvalue()

    def test_dry_run_launches_nothing_and_writes_nothing(self):
        with patch.object(runner.subprocess, "run", side_effect=AssertionError("must not launch")):
            result, text = self.invoke("--dry-run", "--reverse-profile-order")
        self.assertEqual(result, 0)
        self.assertFalse(self.output.exists())
        jobs = json.loads(text)
        self.assertEqual(jobs[0]["profile"], runner.PROFILES[1][0])
        self.assertEqual(jobs[0]["command"], ["swift", "test", "--package-path", str(HERE / "provider-swift"),
                                            "--skip-build", "--disable-automatic-resolution", "--filter", "ModelCheckpointStorageLiveTests"])

    def test_invalid_cli_modes_create_nothing(self):
        for extra in (("--exercise-read-refusal",), ("--test-command-json", '"not argv"'),
                      ("--framework-path", "/frameworks")):
            with self.subTest(extra=extra), contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as raised:
                self.invoke(*extra)
            self.assertEqual(raised.exception.code, 2)
            self.assertFalse(self.output.exists())

    def test_real_cpu_subprocesses_restart_refuse_recover_sequentially(self):
        launcher = """
import json, os, pathlib, sys
sys.path.insert(0, sys.argv[1])
from test_checkpoint_storage import synthetic_report
assert 'DARKBLOOM_TEST_UNSAFE' not in os.environ
spec = json.loads(pathlib.Path(os.environ['DARKBLOOM_CHECKPOINT_STORAGE_SPEC']).read_text())
producer = json.loads(pathlib.Path(spec['producerReportPath']).read_text()) if 'producerReportPath' in spec else None
report = synthetic_report(spec, os.getpid(), producer)
pathlib.Path(spec['benchmark']['outputPath']).write_text(json.dumps(report))
print('stdout ' + spec['phase'])
print('stderr ' + spec['phase'], file=sys.stderr)
"""
        with patch.dict(os.environ, DARKBLOOM_TEST_UNSAFE="must-not-leak"):
            result, _ = self.invoke("--persistent-access-group", "TEAM.test", "--exercise-read-refusal",
                                    "--test-command-json", json.dumps([sys.executable, "-B", "-c", launcher, str(HERE)]))
        self.assertEqual(result, 0)
        summary = json.loads((self.output / "summary.json").read_text())
        self.assertEqual(len(summary["runs"]), 8)
        for run in summary["runs"]:
            self.assertEqual(run["status"], "complete")
            self.assertIn("stdout " + run["phase"], Path(run["stdoutLog"]).read_text())
            self.assertIn("stderr " + run["phase"], Path(run["stderrLog"]).read_text())
            self.assertTrue(Path(run["report"]["checkpointRoot"]).is_dir())
        self.assertNotEqual(summary["runs"][0]["report"]["processID"], summary["runs"][1]["report"]["processID"])
        self.assertEqual({group["step"] for group in summary["roleMedians"]}, {"donate", "restore", "refuse", "restore_after_refusal"})

    def test_failed_donor_skips_dependents_and_records_absent_reports(self):
        result, _ = self.invoke("--persistent-access-group", "TEAM.test", "--test-command-json",
                                json.dumps([sys.executable, "-B", "-c", "raise SystemExit(7)"]))
        self.assertEqual(result, 1)
        summary = json.loads((self.output / "summary.json").read_text())
        self.assertEqual([run["status"] for run in summary["runs"]], ["process_failed", "skipped"] * 2)
        self.assertEqual(summary["roleMedians"], [])
        self.assertTrue(all("report" not in run for run in summary["runs"]))

    def test_zero_exit_without_report_is_not_success_and_output_cannot_be_reused(self):
        command = json.dumps([sys.executable, "-B", "-c", "pass"])
        result, _ = self.invoke("--test-command-json", command)
        self.assertEqual(result, 1)
        summary = json.loads((self.output / "summary.json").read_text())
        self.assertEqual([run["status"] for run in summary["runs"]], ["report_absent"] * 2)
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            self.invoke("--test-command-json", command)

    def test_zero_exit_with_incomplete_role_coverage_is_explicitly_invalid(self):
        launcher = """
import json, os, pathlib, sys
sys.path.insert(0, sys.argv[1])
from test_checkpoint_storage import synthetic_report
spec = json.loads(pathlib.Path(os.environ['DARKBLOOM_CHECKPOINT_STORAGE_SPEC']).read_text())
report = synthetic_report(spec, os.getpid())
report['benchmark']['rows'] = report['benchmark']['rows'][:1]
pathlib.Path(spec['benchmark']['outputPath']).write_text(json.dumps(report))
"""
        result, _ = self.invoke("--test-command-json", json.dumps([sys.executable, "-B", "-c", launcher, str(HERE)]))
        self.assertEqual(result, 1)
        summary = json.loads((self.output / "summary.json").read_text())
        self.assertEqual(summary["roleMedians"], [])
        for run in summary["runs"]:
            self.assertEqual(run["status"], "report_invalid")
            self.assertIn("missing expected", run["error"])
            self.assertNotIn("report", run)
            self.assertEqual(len(json.loads(Path(run["reportPath"]).read_text())["benchmark"]["rows"]), 1)

    def test_report_identity_completion_and_restart_pid_checked(self):
        jobs = runner.plan_runs(base_spec(), self.output, ["never-executed"], access_group="TEAM.test")
        donor = synthetic_report(jobs[0]["spec"])
        self.assertIsNone(runner.report_problem(donor, jobs[0]["spec"]))
        restored = synthetic_report(jobs[1]["spec"], 22, donor)
        self.assertIsNone(runner.report_problem(restored, jobs[1]["spec"], donor))
        for changes in (dict(complete=False), dict(failure="failed"), dict(completedIterations=0), dict(runID=str(uuid.uuid4()))):
            with self.subTest(changes=changes):
                self.assertIsNotNone(runner.report_problem(dict(donor, **changes), jobs[0]["spec"]))
        restored["processID"] = donor["processID"]
        self.assertIsNotNone(runner.report_problem(restored, jobs[1]["spec"], donor))


if __name__ == "__main__":
    unittest.main()
