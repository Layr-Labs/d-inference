#!/usr/bin/env python3
"""Which CI process runs each darkbloom-cluster test, and the runner for one job shard.

The runtime target (`DarkbloomClusterRuntimeTests`) runs in selections
(docs/developer/test.md): the base selection runs every test that needs no
switch, and each opt-in selection runs only the tests one environment switch
enables. Every process goes through scripts/run-nested-suite.sh, which fails on
zero executed tests and on any skip. The base processes pass `--skip` for
exactly the switched tests, so a test that skips there has a gate this plan
does not name.

The blocking and focused lanes are split into shards by measured seconds
(`cluster-test-weights.json`, longest first onto the least loaded shard, as
scripts/provider-test-shards.py does). A shard runs one process per selection
it holds. The base selection's units are top-level suites, and single tests of
the suites in SPLIT_SUITES. The last blocking shard runs the base catch-all:
every base test that shards 1 to N-1 do not select, so a new or unweighed
suite always runs. `audit` checks the plan against the sources; `audit-runs`
checks, from each process's report, that every blocking test ran exactly once.

Lanes: `blocking` (Cluster Runtime Tests), `nonblocking` (Cluster GPU Tests,
reported but not failing the workflow) and `focused` (Cluster Focused Checks,
the model-free runner scripts).

Subcommands:
  run LANE SHARD          run the processes of one shard
  audit                   check the plan against the sources and the workflow
  audit-runs LIST REPORTS check the blocking reports against `swift test list`
  weights XUNIT...        print measured seconds per unit from xUnit reports;
                          units they do not cover keep their checked-in seconds
"""

import argparse
from collections import Counter, defaultdict
from dataclasses import dataclass, field
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time
import xml.etree.ElementTree as ElementTree


ROOT = Path(__file__).resolve().parent.parent
PACKAGE = ROOT / "libs/darkbloom-cluster"
RUNTIME_TESTS = PACKAGE / "Tests/DarkbloomClusterRuntimeTests"
WORKFLOW = ROOT / ".github/workflows/ci.yml"
NESTED_SUITE = ROOT / "scripts/run-nested-suite.sh"
MODULE = "DarkbloomClusterRuntimeTests"
LANES = ("blocking", "nonblocking", "focused")
WEIGHTS = ROOT / "scripts/cluster-test-weights.json"
# Shards of the lanes split by measured seconds; ci.yml's matrices match.
SHARD_COUNTS = {"blocking": 12, "focused": 3}
# Base suites whose tests are weighed and placed one by one: each is longer
# than one shard. Every other base unit is a whole top-level suite.
SPLIT_SUITES = ("QwenTensorParallelBatchSessionTests",)
# Measured start-up of one `swift test` process, and the seconds assumed for a
# unit the weights do not list yet.
PROCESS_SECONDS = 8.0
UNWEIGHED_SECONDS = 10.0
# The weight of the base tests no unit names (free functions, XCTest cases).
CATCH_ALL_KEY = "unweighed"
_SPEC = importlib.util.spec_from_file_location("provider_test_shards", ROOT / "scripts/provider-test-shards.py")
provider_shards = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(provider_shards)
# Every cluster process starts with this switch (ClusterQuantizedRowRouting);
# MLX reads it once per process.
PROCESS_ENVIRONMENT = {"MLX_QMV_BATCH_INVARIANT": "1"}


@dataclass(frozen=True)
class Selection:
    name: str
    lane: str
    # Fixed for the nonblocking lane; None where the weights place the work.
    shard: int | None
    environment: dict = field(default_factory=dict)
    # Opt-in: the gated test functions the environment enables.
    tests: tuple = ()
    # Focused: a runner script under libs/darkbloom-cluster/Tests.
    runner: str | None = None

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
)

SELECTIONS = (
    Selection("base", "blocking", None),
    Selection("qwen-tp-batch-gpu", "blocking", None, {"QWEN_TP_BATCH_GPU": "1"}, tests=(
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
    )),
    Selection("qwen-tp-batch-gpu-paged", "blocking", None, {"QWEN_TP_BATCH_GPU": "1", "QWEN_TP_BATCH_KV": "paged"}, tests=(
        "cohortSurvivorKeepsOnlyItsOwnRows",
        "routedExpertCapacityOneAndTwoKeepExactPagedLogitsAndHistory",
        "capacityOneAndTwoKeepExactPagedLogitsAndHistory",
        "pagesGrowMidDecodeWithoutChangingAByte",
        "promptLayerSubmissionKeepsEveryBit",
    )),
    Selection("qwen-tp-mtp-gpu", "blocking", None, {"QWEN_TP_MTP_GPU": "1"}, tests=QWEN_TP_MTP_GPU_TESTS),
    Selection("qwen-tp-aqv-gpu", "blocking", None, {"QWEN_TP_AQV_GPU": "1"}, tests=(
        "declinesWhatItDoesNotCover",
        "agreesWithTheDequantizedProduct",
        "everyVectorEqualsItsOwnSingleVectorCall",
        "everyLayoutGivesTheSameBits",
        "swigluEqualsTwoProjectionsAndTheSwiGLU",
        "swigluEqualsTheCompiledSwiGLUAtEveryGateValue",
        "siluMultiplyEqualsTheUnfusedChain",
        "sigmoidGateEqualsTheUnfusedChain",
        "cachedGatedDeltaScalesEqualFreshOnes",
    )),
    Selection("qwen-tp-moe-gpu", "blocking", None, {"QWEN_TP_MOE_GPU": "1", "QWEN_TP_MOE_GPU_DIAG": "1"}, tests=(
        "packedSharedExpertCollectiveIsBitIdenticalOnTwoGPURanks",
        "packedRunsRepeatAndShortPromptsOnTwoGPURanks",
    )),
    Selection("qwen-tp-share-probe-gpu", "blocking", None, {"QWEN_TP_SHARE_PROBE_GPU": "1"}, tests=(
        "eachRankTimesItsShareAloneAndReleasesItsRequest",
        "aRefusalOrAFailureGivesNoProbeAndKeepsNothing",
    )),
    Selection("glm53-prefix-ssd", "blocking", None, {"GLM53_PREFIX_SSD": "1"}, tests=(
        "aServingStageRestoresFromTheSSDExactly",
        "aServingStageRestoresFromABalancedRecord",
    )),
    Selection("glm53-paged-kv", "blocking", None, {"GLM53_PAGED_KV": "1"}, tests=(
        "pagedRequestsDecideAndHoldWhatContiguousOnesDo",
        "pagedMediaRequestsDecideAndHoldWhatContiguousOnesDo",
    )),
    Selection("glm53-row-invariance", "blocking", None, {"GLM53_ROW_INVARIANCE": "1"}, tests=(
        "roundsAreEachRequestsOwnRound",
    )),
    Selection("glm53-depth-invariance", "blocking", None, {"GLM53_DEPTH_INVARIANCE": "1"}, tests=(
        "prefillIsTheSameWithAndWithoutTheSwitch",
        "unpaddedLastRoundsStayOneRowWindows",
    )),
    Selection("glm53-window-census", "blocking", None, {"GLM53_WINDOW_CENSUS": "1"}, tests=(
        "sublayerCensus",
        "projectionRowCensus",
    )),
    Selection("tf32-off", "blocking", None, {"MLX_ENABLE_TF32": "0"}, tests=(
        "receiverCommitPrecedesProducerPublicationAndMatchesFullCachedForward",
    )),
    Selection("qwen-tp-real-geometry-gpu", "nonblocking", 1, {"QWEN_TP_REAL_GEOMETRY_GPU": "1"}, tests=(
        "rowsEqualTheirSoloStepsAndWindowPositionsAtRealWidths",
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
    *(Selection(f"focused-{name}", "focused", None, runner=name) for name in (
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
# Runners the Cluster Metadata Checks job runs with its retained native build.
METADATA_JOB_RUNNERS = ("GPTOSSStageChecks", "NemotronStageChecks", "PrefillScheduleChecks", "StageMetadataChecks")


def functions_regex(names):
    return f"/(?:{'|'.join(sorted(names))})\\("


def suites_regex(suites):
    return f"^{MODULE}[./](?:{'|'.join(sorted(suites))})(?:[./]|$)"


def switched_regex():
    """Every test a base selection must not run: the switched and model-gated tests."""
    gated = [name for selection in SELECTIONS for name in selection.tests] + list(REQUIRES_MODEL)
    return f"{functions_regex(gated)}|{suites_regex(REQUIRES_MODEL_SUITES)}"


def units_regex(units):
    """Base units: whole top-level suites (`Suite`) and single tests (`Suite/test`)."""
    suites = [unit for unit in units if "/" not in unit]
    tests = defaultdict(list)
    for unit in units:
        if "/" in unit:
            suite, test = unit.split("/", 1)
            tests[suite].append(test)
    parts = [suites_regex(suites)] if suites else []
    parts += [f"^{MODULE}[./]{suite}[./](?:{'|'.join(sorted(names))})\\(" for suite, names in sorted(tests.items())]
    return "|".join(parts)


@dataclass(frozen=True)
class Process:
    """One process of one shard: a selection and the units it runs there."""
    selection: Selection
    shard: int
    # Opt-in: test functions. Base: suites and `Suite/test` units. Focused: ().
    units: tuple = ()
    # The last blocking shard's base process: every base unit no other shard selects.
    catch_all: bool = False
    # The base units of shards 1 to N-1, which the catch-all skips.
    others: tuple = ()

    @property
    def name(self):
        return self.selection.name


def load_weights():
    weights = json.loads(WEIGHTS.read_text())
    for key, seconds in weights.items():
        if not re.fullmatch(r"[A-Za-z0-9-]+(/\w+){0,2}", key) or not isinstance(seconds, (int, float)) or seconds < 0:
            raise ValueError(f"Invalid cluster test weight: {key!r}: {seconds!r}")
    return weights


def unit_key(selection, unit=None):
    return selection.name if unit is None else f"{selection.name}/{unit}"


def base_units(weights):
    """The weighed base units: `Suite`, or `Suite/test` for SPLIT_SUITES."""
    base = next(selection for selection in SELECTIONS if selection.base and selection.lane == "blocking")
    prefix = unit_key(base) + "/"
    units = [key[len(prefix):] for key in weights if key.startswith(prefix)]
    return base, [unit for unit in units if unit != CATCH_ALL_KEY
                  and ("/" in unit) == (unit.split("/", 1)[0] in SPLIT_SUITES)]


def assign(shards, items, fixed=()):
    """Place (seconds, selection, unit) longest first onto the least loaded shard.

    Returns, per shard, {selection name: units}. A selection's first unit on a
    shard also costs one process start-up. `fixed` is (shard index, selection,
    seconds) placed before the rest.
    """
    loads = [0.0] * shards
    placed = [defaultdict(list) for _ in range(shards)]
    for index, selection, seconds in fixed:
        loads[index] += PROCESS_SECONDS + seconds
        placed[index].setdefault(selection.name, [])
    for seconds, selection, unit in sorted(items, key=lambda item: (-item[0], item[1].name, str(item[2]))):
        cost = lambda index: seconds + (0 if selection.name in placed[index] else PROCESS_SECONDS)
        index = min(range(shards), key=lambda index: (loads[index] + cost(index), index))
        loads[index] += cost(index)
        placed[index][selection.name].append(unit)
    return placed, loads


def processes(lane, weights=None):
    """Every process of the lane, in shard order."""
    if lane == "nonblocking":
        return [Process(selection, selection.shard, selection.tests)
                for selection in SELECTIONS if selection.lane == lane]
    weights = load_weights() if weights is None else weights
    shards = SHARD_COUNTS[lane]
    selections = [selection for selection in SELECTIONS if selection.lane == lane]
    if lane == "focused":
        items = [(weights.get(unit_key(selection), UNWEIGHED_SECONDS), selection, None) for selection in selections]
        placed, _ = assign(shards, items)
        named = {selection.name: selection for selection in selections}
        return [Process(named[name], index + 1) for index in range(shards) for name in placed[index]]
    base, units = base_units(weights)
    items = [(weights.get(unit_key(selection, test), UNWEIGHED_SECONDS), selection, test)
             for selection in selections if selection.tests for test in selection.tests]
    items += [(weights[unit_key(base, unit)], base, unit) for unit in units]
    catch_all_seconds = weights.get(unit_key(base, CATCH_ALL_KEY), 0.0)
    placed, _ = assign(shards, items, fixed=[(shards - 1, base, catch_all_seconds)])
    others = tuple(sorted(unit for index in range(shards - 1) for unit in placed[index].get(base.name, ())))
    named = {selection.name: selection for selection in selections}
    result = []
    for index in range(shards):
        for name, assigned in placed[index].items():
            if name == base.name and index == shards - 1:
                result.append(Process(base, index + 1, catch_all=True, others=others))
            else:
                result.append(Process(named[name], index + 1, tuple(sorted(assigned))))
    return result


def swift_arguments(process):
    """The run-nested-suite.sh arguments: the filter, then extra `swift test` arguments."""
    selection = process.selection
    if selection.tests:
        return [functions_regex(process.units), "--no-parallel"]
    if not process.catch_all:
        return [units_regex(process.units), "--skip", switched_regex(), "--no-parallel"]
    skip = switched_regex() + (f"|{units_regex(process.others)}" if process.others else "")
    return [f"^{MODULE}[./]", "--skip", skip, "--no-parallel"]


def command(process, output, xunit=None):
    selection = process.selection
    if selection.runner is None:
        arguments = swift_arguments(process)
        if xunit is not None:
            arguments[-1:-1] = ["--xunit-output", str(xunit)]
        return PACKAGE, [str(NESTED_SUITE), *arguments]
    directory = PACKAGE / "Tests" / selection.runner
    if (directory / "run.py").is_file():
        return ROOT, ["python3", str(directory / "run.py"), "--output", str(output / selection.runner)]
    return ROOT, ["bash", str(directory / "run.sh")]


def planned(test_ids, process):
    """The listed tests this process's filter and skip select."""
    filter_regex, *extra = swift_arguments(process)
    skip = extra[extra.index("--skip") + 1] if "--skip" in extra else None
    return [test_id for test_id in test_ids
            if re.search(filter_regex, test_id) and not (skip and re.search(skip, test_id))]


# Variables the runtime tests read to change what they run; no selection
# inherits one from the runner.
TEST_SWITCH_PREFIXES = ("QWEN_TP_", "GLM53_", "DARKBLOOM_PAGED_BENCH", "PREFIX_RECORD_")


def environment(selection):
    switches = {name for other in SELECTIONS for name in other.environment}
    values = {name: value for name, value in os.environ.items()
              if name not in switches and not name.startswith(TEST_SWITCH_PREFIXES)}
    return {**values, **PROCESS_ENVIRONMENT, **selection.environment}


def shards(lane):
    if lane in SHARD_COUNTS:
        return list(range(1, SHARD_COUNTS[lane] + 1))
    return sorted({selection.shard for selection in SELECTIONS if selection.lane == lane})


def stream(argv, cwd, env, log):
    """Run argv, echo its output to the job log and keep a copy in `log`."""
    with open(log, "w") as copy, subprocess.Popen(argv, cwd=cwd, env=env, stdout=subprocess.PIPE,
                                                 stderr=subprocess.STDOUT, text=True, errors="replace") as child:
        for line in child.stdout:
            sys.stdout.write(line)
            sys.stdout.flush()
            copy.write(line)
        return child.wait()


def run(lane, shard):
    selected = [process for process in processes(lane) if process.shard == shard]
    if not selected:
        raise ValueError(f"No processes in {lane} shard {shard}")
    output = Path(tempfile.mkdtemp(prefix="cluster-runner-output-"))
    # Blocking reports feed audit-runs: each process's executed counts and the
    # shard's `swift test list`, from the same build.
    report_dir = os.environ.get("CLUSTER_TEST_REPORT_DIR") if lane == "blocking" else None
    reports = Path(report_dir) if report_dir else None
    listed = None
    if reports:
        reports.mkdir(parents=True, exist_ok=True)
        listing = subprocess.run(["swift", "test", "list", "--skip-build"], cwd=PACKAGE,
                                 stdout=subprocess.PIPE, text=True, check=True).stdout
        listed = provider_shards.listed_tests(listing)
        (reports / f"tests-{shard}.txt").write_text("\n".join(listed) + "\n")
    rows = []
    for process in selected:
        report_name = f"{lane}-{shard}-{process.name}"
        if listed is not None and process.selection.base and not process.catch_all and not planned(listed, process):
            # Only base units the weights name and the sources no longer have;
            # the catch-all and the audit still require every listed test once.
            # An opt-in process always runs: its tests come from the plan.
            print(f"::notice::{process.name} selects no listed test in shard {shard}; refresh the weights", flush=True)
            (reports / f"{report_name}.json").write_text(json.dumps(
                {"shard": shard, "process": process.name, "swift_testing": 0, "xctest": 0}))
            continue
        xunit = reports / f"{report_name}.xml" if reports else None
        cwd, argv = command(process, output, xunit)
        print(f"::group::{process.name}", flush=True)
        started = time.monotonic()
        log = output / f"{report_name}.log"
        status = stream(argv, cwd, environment(process.selection), log)
        seconds = time.monotonic() - started
        print("::endgroup::", flush=True)
        if reports:
            try:
                counted = provider_shards.counts(log.read_text(errors="replace"))
            except ValueError as error:
                print(f"::error::{process.name}: {error}", flush=True)
                counted, status = {"swift_testing": 0, "xctest": 0}, status or 1
            (reports / f"{report_name}.json").write_text(json.dumps(
                {"shard": shard, "process": process.name, **counted}))
        rows.append((process.name, status, seconds))
        if status:
            level = "warning" if lane == "nonblocking" else "error"
            print(f"::{level}::{process.name} failed with exit status {status}", flush=True)
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a") as handle:
            handle.write(f"### Cluster {lane} shard {shard}\n\n| Selection | Result | Seconds |\n|---|---|---|\n")
            for name, status, seconds in rows:
                handle.write(f"| {name} | {'passed' if status == 0 else 'failed'} | {seconds:.0f} |\n")
    return 1 if any(status for _, status, _ in rows) else 0


def blocking_expected(test_ids):
    """Listed tests the blocking lane must run: all but the model-gated ones and the nonblocking lane's."""
    nonblocking = [name for selection in SELECTIONS if selection.lane == "nonblocking" for name in selection.tests]
    excluded = f"{functions_regex([*REQUIRES_MODEL, *nonblocking])}|{suites_regex(REQUIRES_MODEL_SUITES)}"
    return [test_id for test_id in test_ids if test_id.startswith(f"{MODULE}.") and not re.search(excluded, test_id)]


def audit_runs(test_ids, reports, weights=None):
    """Return error lines; empty when every blocking test ran in exactly one process."""
    errors = []
    plan = {(process.shard, process.name): process for process in processes("blocking", weights)}
    got = [(report["shard"], report["process"]) for report in reports]
    if sorted(got) != sorted(plan):
        errors.append(f"Expected one report per process {sorted(plan)}, got {sorted(got)}")
    seen = []
    for report in reports:
        process = plan.get((report["shard"], report["process"]))
        if process is None:
            continue
        selected = planned(test_ids, process)
        seen.extend(selected)
        ran = report["swift_testing"] + report["xctest"]
        print(f"shard {process.shard} {process.name}: planned {len(selected)}, executed {ran}")
        if ran != len(selected):
            errors.append(f"Shard {process.shard} {process.name} executed {ran} tests but selects {len(selected)}")
    duplicates = sorted(test_id for test_id, count in Counter(seen).items() if count > 1)
    if duplicates:
        errors.append(f"{len(duplicates)} tests are selected by more than one process, first {duplicates[0]}")
    expected = blocking_expected(test_ids)
    missing = sorted(set(expected) - set(seen))
    if missing:
        errors.append(f"{len(missing)} listed tests run in no blocking process, first {missing[0]}")
    extra = sorted(set(seen) - set(expected))
    if extra:
        errors.append(f"{len(extra)} selected tests are model-gated or nonblocking, first {extra[0]}")
    print(f"blocking lane: {len(set(seen))} of {len(expected)} expected tests selected")
    return errors


def measured_weights(paths, weights):
    """Seconds per unit from the processes' xUnit reports (`<lane>-<shard>-<process>*.xml`)."""
    selections = {selection.name: selection for selection in SELECTIONS}
    seconds = defaultdict(float)
    for path in paths:
        name = re.fullmatch(r"blocking-\d+-([a-z0-9-]+?)(?:-swift-testing)?\.xml", path.name)
        selection = selections.get(name.group(1)) if name else None
        if selection is None:
            continue
        for case in ElementTree.parse(path).getroot().iter("testcase"):
            classname = case.get("classname", "")
            if not classname.startswith(f"{MODULE}."):
                continue
            path = classname.removeprefix(f"{MODULE}.")
            suite = path.split("/")[0].split(".")[0]
            test = re.match(r"\w+", case.get("name", ""))
            if not suite or not test:
                continue
            if selection.tests:
                key = unit_key(selection, test.group(0))
            elif suite in SPLIT_SUITES:
                if path != suite:
                    continue  # A nested suite's test runs in the catch-all.
                key = unit_key(selection, f"{suite}/{test.group(0)}")
            else:
                key = unit_key(selection, suite)
            seconds[key] += float(case.get("time") or 0)
    measured = {key: round(value, 3) for key, value in seconds.items()}
    return dict(sorted({**weights, **measured}.items()))


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
    names = [selection.name for selection in SELECTIONS]
    if len(names) != len(set(names)) or any(selection.lane not in LANES for selection in SELECTIONS):
        errors.append("Selection names must be unique and every lane known")
    for selection in SELECTIONS:
        if (selection.shard is None) != (selection.lane in SHARD_COUNTS):
            errors.append(f"{selection.name}: only the {sorted(set(LANES) - set(SHARD_COUNTS))} lane fixes shards")
    if [selection.name for selection in SELECTIONS if selection.base] != ["base"]:
        errors.append("The blocking lane must have exactly one base selection, `base`")
    for lane in LANES:
        if shards(lane) != list(range(1, len(shards(lane)) + 1)):
            errors.append(f"{lane} shards are not numbered 1 to N: {shards(lane)}")
        used = sorted({process.shard for process in processes(lane)})
        if used != shards(lane):
            errors.append(f"{lane} shards {shards(lane)} must each run a process, got {used}")
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
    command_parser = commands.add_parser("audit-runs")
    command_parser.add_argument("list", type=Path)
    command_parser.add_argument("reports", type=Path)
    command_parser = commands.add_parser("weights")
    command_parser.add_argument("xunit", type=Path, nargs="+")
    args = parser.parse_args()
    if args.command == "run":
        return run(args.lane, args.shard)
    if args.command == "weights":
        json.dump(measured_weights(args.xunit, load_weights()), sys.stdout, indent=0, sort_keys=True)
        print()
        return 0
    if args.command == "audit-runs":
        reports = [json.loads(path.read_text()) for path in sorted(args.reports.glob("*/blocking-*.json"))]
        errors = audit_runs(provider_shards.listed_tests(args.list.read_text()), reports)
    else:
        errors = audit()
    for error in errors:
        print(f"::error::{error}")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
