#!/usr/bin/env python3
"""Which CI process runs each darkbloom-cluster test, and the runner for one job shard.

The runtime target (`DarkbloomClusterRuntimeTests`) runs in selections, each in
a process of its own (docs/developer/test.md): the base selections run every
test that needs no switch, and each opt-in selection runs only the tests one
environment switch enables. Every selection goes through
scripts/run-nested-suite.sh, which fails on zero executed tests and on any
skip. The base selections pass `--skip` for exactly the switched tests, so a
test that skips there has a gate this plan does not name. `audit` checks that
the plan names exactly the gated tests in the sources and every focused
runner under libs/darkbloom-cluster/Tests.

Lanes: `blocking` (Cluster Runtime Tests), `nonblocking` (Cluster GPU Tests,
reported but not failing the workflow) and `focused` (Cluster Focused Checks,
the model-free runner scripts).

Subcommands:
  run LANE SHARD     run the selections of one shard, each in its own process:
                     the shard's groups at the same time, then the others alone
  audit              check the plan against the sources and the workflow
"""

import argparse
import importlib.util
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time


ROOT = Path(__file__).resolve().parent.parent
PACKAGE = ROOT / "libs/darkbloom-cluster"
RUNTIME_TESTS = PACKAGE / "Tests/DarkbloomClusterRuntimeTests"
WORKFLOW = ROOT / ".github/workflows/provider-tests.yml"
NESTED_SUITE = ROOT / "scripts/run-nested-suite.sh"
MODULE = "DarkbloomClusterRuntimeTests"
LANES = ("blocking", "nonblocking", "focused")
# Every cluster process starts with this switch (ClusterQuantizedRowRouting);
# MLX reads it once per process.
PROCESS_ENVIRONMENT = {"MLX_QMV_BATCH_INVARIANT": "1"}


@dataclass(frozen=True)
class Selection:
    name: str
    lane: str
    shard: int
    environment: dict = field(default_factory=dict)
    # Opt-in: the gated test functions the environment enables.
    tests: tuple = ()
    # Base: these suites only, or every suite no other base selection takes.
    suites: tuple | None = None
    # Focused: a runner script under libs/darkbloom-cluster/Tests.
    runner: str | None = None
    # The shard runs its groups at the same time, each group's selections one
    # after another in plan order; the selections with no group then run one
    # at a time, alone on the Mac.
    group: int | None = None

    @property
    def base(self):
        return not self.tests and self.runner is None


QWEN_TP_MTP_GPU_TESTS = (
    "oneResidentAssistantSurvivesCreditJoinsRectanglesAndResumedSpeculation",
    "nineBRatioAssistantSurvivesCreditJoinsRectanglesAndResumedSpeculation",
    "finalNativeWindowStillPublishesEveryAcceptedTokenUnderSeparateCredits",
    "concurrentRoundsKeepIndependentCreditsAndSurviveCohortRetirement",
    "eligibleCohortCoexistsWithOrdinaryHistoryAndLogprobLanes",
    "concurrentFinalWindowsDrainWithoutFurtherNativeWork",
    "failedConcurrentDraftPublishesNothingAndRetainsAllRowsForCheckedRetirement",
    "staggeredRowsVerifyAsOneCohortAndMatchTheirSoloRuns",
    "aheadRowStopsCleanlyAndItsCohortContinues",
    "batchedCohortDraftsMatchRowByRowDraftsWithOneHeadCallPerStep",
    "exactDraftRowsEqualTheirSoloRunsAndThePlainTargetAtEveryWidth",
    "unequalHistoriesAndKeepsDiscardRejectedSuffixesAndResumeBatchDecode",
    "capturedGreedyChoicesAndContinuationMatchOrdinaryTargetColumns",
    "oneProductOverManyRowsChangesQuantizedArithmetic",
    "sharedWindowCallsKeepEveryRowsQuantizedArithmetic",
    "everyRectangleRowEqualsItsOwnSingleRequestWindowBitwise",
    "capturedCohortCannotBePartiallyFinalizedAndFaultRetiresAllRows",
    "graphConstructionFailurePoisonsAllBoundRowsAndReturnsTheirStorage",
    "laterDraftStepsForManyRowsEqualEachRowAlone",
    "windowPositionsEqualPlainDecodeStepsBitwise",
    "shortSettledWindowsEqualTheirPlainStepsBitwise",
    "fusedResidualStepsKeepEveryOutputBitwise",
    "decodeRowsEqualTheirSoloStepsBitwise",
    "cohortHeadRowsKeepEachRowsOwnProduct",
    "exactDraftProjectionsKeepEachRowsOwnProductAtQwen27Shapes",
    "realAssistantAndTargetRoundsSettleBeforePublicationAndRetireAfterFault",
    "boundedHistoryFlushKeepsTargetVerifiedOutputs",
    "promptHistoryFlushesKeepDraftsAndBoundTheBacklog",
    "capturedWindowsAllocateNoSecondHistory",
    "actualHybridShardsCommitAndRetireCapturedWindows",
    "pairedPrefixPreservesHybridSpeculationAndRejectsFailedDonors",
    "pipelinedDraftsEmitTheSameTokensAndCollectives",
    "oneRankFailingMidChainFailsBothAndRetires",
    "deferredRangeCheckKeepsTheWindowAndItsHistory",
    "wholeAndLayeredWindowsAreBitwise",
    "anAssistedHybridPromptMergesFramesAndSpeculatesAlikeOnGPU",
)

# The Gemma 4 suites: 592 of the base tests' 970 s (run 41992571131, job
# 127128309712). They run in a process of their own, so the family still
# shares one process; `audit` checks that every Gemma suite is listed.
GEMMA_SUITES = (
    "Gemma4BatchArithmeticAgreementTests", "Gemma4BatchDecodeTests", "Gemma4StagePagedSyntheticTests",
    "Gemma4TensorParallelPrefixTests", "Gemma4TensorParallelRuntimeTests", "Gemma4TensorParallelTests",
    "GemmaPrefillArithmeticTests", "GemmaPrefixChunkTests", "ResidentAdmissionGemma4Tests",
)

SELECTIONS = (
    # Blocking shard 1 runs `base` alone, then the share probe alone. The
    # probe times its share against a 1.5 s budget, so it never runs on a Mac
    # just after the concurrent GPU groups (run 41973436945 failed it there).
    # Shard 2 runs group 1 (the CPU batch-session suite, then the GLM paged-KV,
    # invariance and census, TF32 and Gemma selections) beside group 2 (the
    # Qwen GPU chain and glm53-prefix-ssd). Shard 3 runs the Gemma 4 base
    # suites alone.
    Selection("base-batch-session", "blocking", 2, suites=("QwenTensorParallelBatchSessionTests",), group=1),
    Selection("base", "blocking", 1),
    Selection("base-gemma", "blocking", 3, suites=GEMMA_SUITES),
    Selection("qwen-tp-batch-gpu", "blocking", 2, {"QWEN_TP_BATCH_GPU": "1"}, tests=(
        "bothTilesGiveTheSameBytes",
        "actualHybridShardsPreserveAttentionConvAndSSMRows",
        "nineBRatioDenseShardsBatchExactly",
        "routedExpertShardsBatchExactly",
        "routedExpertNativeMixedSamplingKeepsRowsIndependent",
        "warmHybridPrefixesPreserveConvSSMAndMixedPositions",
        "ssdHybridPrefixesRestoreConvSSMAfterTheTiersReopen",
        "deepRestoresEqualColdPrefillOnBothRanks",
        "mergedStepTemporariesStayWithinTheirCharge",
        "mergedFramesKeepEveryBit",
        "executorRunsThePlannedMergedStep",
    ), group=2),
    Selection("qwen-tp-batch-gpu-paged", "blocking", 2, {"QWEN_TP_BATCH_GPU": "1", "QWEN_TP_BATCH_KV": "paged"}, tests=(
        "cohortSurvivorKeepsOnlyItsOwnRows",
        "routedExpertCapacityOneAndTwoKeepExactPagedLogitsAndHistory",
        "capacityOneAndTwoKeepExactPagedLogitsAndHistory",
        "pagesGrowMidDecodeWithoutChangingAByte",
        "promptLayerSubmissionKeepsEveryBit",
    ), group=2),
    Selection("qwen-tp-mtp-gpu", "blocking", 2, {"QWEN_TP_MTP_GPU": "1"}, tests=QWEN_TP_MTP_GPU_TESTS, group=2),
    Selection("qwen-tp-aqv-gpu", "blocking", 2, {"QWEN_TP_AQV_GPU": "1"}, tests=(
        "declinesWhatItDoesNotCover",
        "agreesWithTheDequantizedProduct",
        "everyVectorEqualsItsOwnSingleVectorCall",
        "everyLayoutGivesTheSameBits",
        "swigluEqualsTwoProjectionsAndTheSwiGLU",
        "swigluEqualsTheCompiledSwiGLUAtEveryGateValue",
        "siluMultiplyEqualsTheUnfusedChain",
        "sigmoidGateEqualsTheUnfusedChain",
        "cachedGatedDeltaScalesEqualFreshOnes",
    ), group=2),
    Selection("qwen-tp-moe-gpu", "blocking", 2, {"QWEN_TP_MOE_GPU": "1", "QWEN_TP_MOE_GPU_DIAG": "1"}, tests=(
        "packedSharedExpertCollectiveIsBitIdenticalOnTwoGPURanks",
        "packedRunsRepeatAndShortPromptsOnTwoGPURanks",
    ), group=2),
    Selection("qwen-tp-share-probe-gpu", "blocking", 1, {"QWEN_TP_SHARE_PROBE_GPU": "1"}, tests=(
        "eachRankTimesItsShareAloneAndReleasesItsRequest",
        "aRefusalOrAFailureGivesNoProbeAndKeepsNothing",
    )),
    Selection("glm53-prefix-ssd", "blocking", 2, {"GLM53_PREFIX_SSD": "1"}, tests=(
        "aServingStageRestoresFromTheSSDExactly",
        "aServingStageRestoresFromABalancedRecord",
    ), group=2),
    Selection("glm53-paged-kv", "blocking", 2, {"GLM53_PAGED_KV": "1"}, tests=(
        "pagedRequestsDecideAndHoldWhatContiguousOnesDo",
        "pagedMediaRequestsDecideAndHoldWhatContiguousOnesDo",
    ), group=1),
    Selection("glm53-row-invariance", "blocking", 2, {"GLM53_ROW_INVARIANCE": "1"}, tests=(
        "roundsAreEachRequestsOwnRound",
    ), group=1),
    Selection("glm53-depth-invariance", "blocking", 2, {"GLM53_DEPTH_INVARIANCE": "1"}, tests=(
        "prefillIsTheSameWithAndWithoutTheSwitch",
        "unpaddedLastRoundsStayOneRowWindows",
    ), group=1),
    Selection("glm53-window-census", "blocking", 2, {"GLM53_WINDOW_CENSUS": "1"}, tests=(
        "sublayerCensus",
        "projectionRowCensus",
    ), group=1),
    Selection("tf32-off", "blocking", 2, {"MLX_ENABLE_TF32": "0"}, tests=(
        "receiverCommitPrecedesProducerPublicationAndMatchesFullCachedForward",
    ), group=1),
    Selection("gemma-tp-diag", "blocking", 2, {"GEMMA_TP_DIAG": "1"}, tests=(
        "diagnosticShardOperationsEqualWholeOperations",
    ), group=1),
    # The two halves of QwenTensorParallelRowsCheck, each alone on a GPU shard.
    # As one test it took 1098 s and decided the run's wall time (run
    # 42268059756); each half prefills about half of its 130k prompt tokens.
    Selection("qwen-tp-real-geometry-gpu", "nonblocking", 1, {"QWEN_TP_REAL_GEOMETRY_GPU": "1"}, tests=(
        "rowsEqualTheirSoloStepsAndWindowPositionsAtRealWidths",
    )),
    Selection("qwen-tp-real-geometry-gpu-segments", "nonblocking", 3, {"QWEN_TP_REAL_GEOMETRY_GPU": "1"}, tests=(
        "rowsAcrossKVSegmentsEqualTheirSoloStepsAtRealWidths",
    )),
    Selection("qwen-tp-mtp-gpu-wide-kernel", "nonblocking", 2, {"QWEN_TP_MTP_GPU": "1"}, tests=(
        "wideKernelRowsEqualEachRowsOwnWindowCall",
    )),
    Selection("qwen-tp-aqv-gpu-fused-kernels", "nonblocking", 2, {"QWEN_TP_AQV_GPU": "1"}, tests=(
        "residualRMSNormEqualsTheUnfusedOps",
        "gatedDeltaConvolutionEqualsTheUnfusedOps",
        "gatedDeltaQKNormEqualsTheUnfusedOps",
        "cpuStreamSumIsBitwiseOnGPU",
        "chainWithCPUHopsIsBitwiseOnGPU",
        "transposedCPUSumWaitsBeforeTheCopyOnGPU",
    )),
    Selection("qwen-tp-batch-gpu-paged-transient", "nonblocking", 2,
              {"QWEN_TP_BATCH_GPU": "1", "QWEN_TP_BATCH_KV": "paged"}, tests=(
        "fullHistoryGatherIsOnePromptFramesTransient",
    )),
    Selection("glm53-depth-invariance-widths", "nonblocking", 2, {"GLM53_DEPTH_INVARIANCE": "1"}, tests=(
        "everyDepthAndKeptPatternIsTheDepthTwoDecode",
        "loadPolicyLanesAreEachRequestAloneAtDepthTwo",
    )),
    Selection("glm53-window-width-census", "nonblocking", 2, {"GLM53_WINDOW_CENSUS": "1"}, tests=(
        "windowWidthCensus",
    )),
    Selection("paged-verify-bench", "nonblocking", 2, {"DARKBLOOM_PAGED_BENCH": "1"}, tests=(
        "verifyAndPrefillAttention",
    )),
    Selection("qwen-tp-aqv-bench", "nonblocking", 2, {"QWEN_TP_AQV_BENCH": "1"}, tests=(
        "throughputAgainstMLXCalls",
    )),
    Selection("qwen-tp-wide-bench", "nonblocking", 2, {"QWEN_TP_WIDE_BENCH": "1"}, tests=(
        "wideKernelVariantThroughput",
    )),
    Selection("prefix-record-encode-bench", "nonblocking", 2, {"PREFIX_RECORD_ENCODE_BENCH": "1"}, tests=(
        "encodingThroughputAtTheBetaShape",
    )),
    *(Selection(f"focused-{name}", "focused", 1, runner=name) for name in (
        "BootstrapChecks", "CapabilityChecks", "CheckpointChecks", "DeadlineChecks", "ExitChecks",
        "GLMImageAdmissionChecks", "LinkControlChecks", "LinkWorkerChecks", "NativePairChecks",
        "ObservabilityChecks", "PlacementChecks", "PrefixPolicyChecks", "PreludeChecks",
        "ProcessChecks", "ProtocolChecks", "QwenMediaChecks", "RemoteChecks", "SSHChecks",
        "SecurityChecks", "StageTransferChecks", "StillImageChecks", "TensorParallelPlanChecks",
    )),
)

# Gated tests that need a model directory, an artifact or its metadata. CI has
# none, so no selection runs them; the base selections skip them by name.
REQUIRES_MODEL = (
    "theRegisteredArtifactReproducesItsPinnedInventory",
    "thePinnedSourceEqualsTheFileBackedSource",
    "theRealModelsPerTokenCharge",
    "aReservationsChargeDoesNotHashTheInventory",
    "eigenLabs8841HeadersMatchExactPinsAndAllStructuralCuts",
    "setupStepsOnTheRealMetadata",
    "packedSharedExpertCollectiveIsBitIdenticalOnTheRealArtifact",
    "cohortRoundPhasesByWidthAndDraftBatching",
    "completeLoadQuoteByWidth",
    "perRankDecodeCompute",
    "exactAndMLXDraftsOnRealPromptsAreLosslessWithTheirAcceptance",
    "routedExpertDecodeStepProfile",
    "oneRowRoundPhasesByOwnerCapacity",
    "cohortRowsEqualTheirSoloRowsOnTheRealArtifact",
    "verifyWindowRoundsByRowCount",
)
REQUIRES_MODEL_SUITES = ("GLM5NextServingMetadataTests", "GLM5NextTensorParallelMediaTowerTests")
# Runners the workflow runs as steps of their own: the release builds in
# Cluster Release Build Checks, the others in shard 2 of Cluster Focused Checks.
METADATA_JOB_RUNNERS = ("GPTOSSStageChecks", "NemotronStageChecks", "PrefillScheduleChecks", "StageMetadataChecks")


def functions_regex(names):
    return f"/(?:{'|'.join(sorted(names))})\\("


def suites_regex(suites):
    return f"^{MODULE}[./](?:{'|'.join(sorted(suites))})(?:[./]|$)"


def switched_regex():
    """Every test a base selection must not run: the switched and model-gated tests."""
    gated = [name for selection in SELECTIONS for name in selection.tests] + list(REQUIRES_MODEL)
    return f"{functions_regex(gated)}|{suites_regex(REQUIRES_MODEL_SUITES)}"


def swift_arguments(selection):
    """The run-nested-suite.sh arguments: the filter, then extra `swift test` arguments."""
    if selection.tests:
        return [functions_regex(selection.tests), "--no-parallel"]
    if selection.suites:
        return [suites_regex(selection.suites), "--skip", switched_regex(), "--no-parallel"]
    others = [suite for other in SELECTIONS if other.base and other.suites for suite in other.suites]
    return [f"^{MODULE}[./]", "--skip", f"{switched_regex()}|{suites_regex(others)}", "--no-parallel"]


def command(selection, output):
    if selection.runner is None:
        filter_regex, *extra = swift_arguments(selection)
        # The groups of a shard share one build. With --skip-build no process
        # writes it, so they skip SwiftPM's lock on .build, which would
        # otherwise run them one after another.
        lock = ["--ignore-lock"] if selection.group is not None else []
        return PACKAGE, [str(NESTED_SUITE), filter_regex, *lock, *extra]
    directory = PACKAGE / "Tests" / selection.runner
    if (directory / "run.py").is_file():
        return ROOT, ["python3", str(directory / "run.py"), "--output", str(output / selection.runner)]
    return ROOT, ["bash", str(directory / "run.sh")]


# Variables the runtime tests read to change what they run; no selection
# inherits one from the runner.
TEST_SWITCH_PREFIXES = ("QWEN_TP_", "GLM53_", "GEMMA_TP_", "DARKBLOOM_PAGED_BENCH", "PREFIX_RECORD_")


def environment(selection):
    switches = {name for other in SELECTIONS for name in other.environment}
    values = {name: value for name, value in os.environ.items()
              if name not in switches and not name.startswith(TEST_SWITCH_PREFIXES)}
    return {**values, **PROCESS_ENVIRONMENT, **selection.environment}


def shards(lane):
    return sorted({selection.shard for selection in SELECTIONS if selection.lane == lane})


def script(name):
    """scripts/<name>.py (dashes as underscores in the module name), loaded by path (scripts/ is not a package)."""
    spec = importlib.util.spec_from_file_location(name.replace("-", "_"), ROOT / f"scripts/{name}.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def lock_retry():
    """scripts/swift_test_lock_retry.py."""
    return script("swift_test_lock_retry")


def mark(event, selection, pid):
    """Report-only: tell scripts/ci-resource-sampler.py, in a sampled job, that
    `selection` starts or ends under pid, so its report names the selection of
    each large process."""
    if not os.environ.get("CI_RESOURCE_SAMPLES"):
        return
    try:
        script("ci-resource-sampler").mark(event, selection.name, pid)
    except Exception as error:  # Report-only: never fail a selection.
        print(f"::warning title=Resource sampler::{type(error).__name__}: {error}", flush=True)


def execute(selection, output, log=None, temporary=None):
    """Run one selection in its own process; return (exit status, seconds).

    A grouped selection (log given) runs beside another group's process. Its
    SwiftPM can find the build database locked by that process's startup; it
    then runs the tests and exits 1. Such a selection runs once more, but only
    when its log proves every test passed (scripts/swift_test_lock_retry.py).
    The first attempt's log stays beside the log, as <log>.attempt-1, and
    prints with it.
    """
    cwd, argv = command(selection, output)
    env = environment(selection)
    if temporary is not None:
        env["TMPDIR"] = str(temporary)
    started = time.monotonic()
    for attempt in (1, 2):
        # subprocess.run, with the child's pid marked for the resource sampler.
        with subprocess.Popen(argv, cwd=cwd, env=env, stdout=log,
                              stderr=subprocess.STDOUT if log is not None else None) as child:
            mark("start", selection, child.pid)
            try:
                status = child.wait()
            except BaseException:
                child.kill()
                raise
            finally:
                mark("end", selection, child.pid)
        if status == 0 or log is None or attempt == 2:
            break
        log.flush()
        path = Path(log.name)
        text = path.read_bytes()
        if not lock_retry().only_locked(text.decode(errors="replace")):
            break
        path.with_name(path.name + ".attempt-1").write_bytes(text)
        log.seek(0)
        log.truncate()
    return status, time.monotonic() - started


def start_gap():
    """Seconds between the starts of a shard's groups (CLUSTER_TEST_START_GAP, default 15).

    Processes that start together on one build meet on SwiftPM's build
    database at startup: shard 2's two groups found it locked in every run of
    runs 42041608780 to 42065297991. Each later group starts this long after
    the one before, as the provider shards' processes do
    (PROVIDER_TEST_START_GAP); the lock-retry guard stays the backstop.
    """
    value = os.environ.get("CLUSTER_TEST_START_GAP") or "15"
    if not re.fullmatch(r"[0-9]+(\.[0-9]+)?", value):
        raise ValueError(f"CLUSTER_TEST_START_GAP must be seconds, got {value!r}")
    return float(value)


def run_group(number, selections, output, delay=0.0):
    """Run one group's selections in plan order, each logging to its own file,
    after `delay` seconds."""
    time.sleep(delay)
    temporary = output / f"group-{number}-tmp"
    temporary.mkdir()
    results = []
    for selection in selections:
        path = output / f"{selection.name}.log"
        with path.open("wb") as log:
            status, seconds = execute(selection, output, log, temporary)
        results.append((selection, status, seconds, path))
    return results


def run(lane, shard):
    selected = [selection for selection in SELECTIONS if selection.lane == lane and selection.shard == shard]
    if not selected:
        raise ValueError(f"No selections in {lane} shard {shard}")
    output = Path(tempfile.mkdtemp(prefix="cluster-runner-output-"))
    groups = {}
    for selection in selected:
        if selection.group is not None:
            groups.setdefault(selection.group, []).append(selection)
    results = {}
    if groups:
        # The groups run at the same time; their logs print afterwards, whole.
        gap = start_gap()
        with ThreadPoolExecutor(max_workers=len(groups)) as pool:
            futures = [pool.submit(run_group, number, members, output, index * gap)
                       for index, (number, members) in enumerate(sorted(groups.items()))]
            finished = [result for future in futures for result in future.result()]
        for selection, status, seconds, path in finished:
            print(f"::group::{selection.name} (group {selection.group})", flush=True)
            first = path.with_name(path.name + ".attempt-1")
            if first.is_file():
                print(f"Attempt 1: every test passed, but SwiftPM's build database was locked; "
                      f"the selection ran once more. Attempt 1's log:", flush=True)
                sys.stdout.buffer.write(first.read_bytes())
                print("Attempt 2's log:", flush=True)
            sys.stdout.buffer.write(path.read_bytes())
            sys.stdout.flush()
            print("::endgroup::", flush=True)
            results[selection.name] = (status, seconds)
    for selection in selected:
        if selection.group is None:
            print(f"::group::{selection.name}", flush=True)
            results[selection.name] = execute(selection, output)
            print("::endgroup::", flush=True)
    rows = [(selection.name, *results[selection.name]) for selection in selected]
    for name, status, _ in rows:
        if status:
            level = "warning" if lane == "nonblocking" else "error"
            print(f"::{level}::{name} failed with exit status {status}", flush=True)
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a") as handle:
            handle.write(f"### Cluster {lane} shard {shard}\n\n| Selection | Result | Seconds |\n|---|---|---|\n")
            for name, status, seconds in rows:
                handle.write(f"| {name} | {'passed' if status == 0 else 'failed'} | {seconds:.0f} |\n")
    return 1 if any(status for _, status, _ in rows) else 0


def gated_in_sources(directory=RUNTIME_TESTS):
    """(gated test functions, gated suites, function names defined more than once)."""
    functions, suites, defined = set(), set(), {}
    attribute = re.compile(r"@(Test|Suite)\(")
    for path in sorted(directory.rglob("*.swift")):
        text = path.read_text()
        for match in re.finditer(r"\bfunc (\w+)\(", text):
            defined[match.group(1)] = defined.get(match.group(1), 0) + 1
        for match in attribute.finditer(text):
            depth, index = 0, match.end() - 1
            while True:
                depth += {"(": 1, ")": -1}.get(text[index], 0)
                if depth == 0:
                    break
                index += 1
            if ".enabled(if:" not in text[match.start():index]:
                continue
            following = text[index + 1:]
            if match.group(1) == "Test":
                functions.add(re.search(r"\bfunc (\w+)\(", following).group(1))
            else:
                suites.add(re.search(r"\b(?:struct|class|enum) (\w+)", following).group(1))
    repeated = {name for name, count in defined.items() if count > 1}
    return functions, suites, repeated


def gemma_suites_in_sources(directory=RUNTIME_TESTS):
    """Top-level test types of the Gemma family: a name with `Gemma` that ends in `Tests`."""
    names = set()
    for path in sorted(directory.rglob("*.swift")):
        names.update(re.findall(r"(?m)^(?:@\w+(?:\([^)]*\))?\s+)*(?:final )?(?:struct|class|enum) (\w*Gemma\w*Tests)\b",
                                path.read_text()))
    return names


def audit():
    errors = []
    planned = [name for selection in SELECTIONS for name in selection.tests]
    for name in sorted({name for name in planned if planned.count(name) > 1}):
        errors.append(f"{name} is in more than one selection")
    named_once = planned + list(REQUIRES_MODEL)
    functions, suites, repeated = gated_in_sources()
    for name in sorted(functions - set(named_once)):
        errors.append(f"Gated test {name} is in no selection or REQUIRES_MODEL")
    for name in sorted(set(named_once) - functions):
        errors.append(f"{name} is planned but is not a gated test in {RUNTIME_TESTS.relative_to(ROOT)}")
    for name in sorted(set(named_once) & repeated):
        errors.append(f"{name} is defined more than once; its name does not select one test")
    if suites != set(REQUIRES_MODEL_SUITES):
        errors.append(f"Gated suites {sorted(suites)} differ from REQUIRES_MODEL_SUITES {sorted(REQUIRES_MODEL_SUITES)}")
    gemma = gemma_suites_in_sources()
    if gemma != set(GEMMA_SUITES):
        errors.append(f"Gemma suites in the sources {sorted(gemma)} differ from GEMMA_SUITES {sorted(GEMMA_SUITES)}")
    names = [selection.name for selection in SELECTIONS]
    if len(names) != len(set(names)) or any(selection.lane not in LANES for selection in SELECTIONS):
        errors.append("Selection names must be unique and every lane known")
    for lane in LANES:
        if shards(lane) != list(range(1, len(shards(lane)) + 1)):
            errors.append(f"{lane} shards are not numbered 1 to N: {shards(lane)}")
    runners = {path.parent.name for pattern in ("*/run.sh", "*/run.py") for path in (PACKAGE / "Tests").glob(pattern)}
    focused = {selection.runner for selection in SELECTIONS if selection.runner}
    if runners != focused | set(METADATA_JOB_RUNNERS) or focused & set(METADATA_JOB_RUNNERS):
        errors.append(f"Runners {sorted(runners)} must each be in exactly one of the focused lane "
                      f"{sorted(focused)} and METADATA_JOB_RUNNERS {sorted(METADATA_JOB_RUNNERS)}")
    workflow = WORKFLOW.read_text()
    for runner in METADATA_JOB_RUNNERS:
        if f"libs/darkbloom-cluster/Tests/{runner}/run." not in workflow:
            errors.append(f"{runner} is not run by the workflow")
    return errors


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    commands = parser.add_subparsers(dest="command", required=True)
    command_parser = commands.add_parser("run")
    command_parser.add_argument("lane", choices=LANES)
    command_parser.add_argument("shard", type=int)
    commands.add_parser("audit")
    args = parser.parse_args()
    if args.command == "run":
        return run(args.lane, args.shard)
    errors = audit()
    for error in errors:
        print(f"::error::{error}")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
