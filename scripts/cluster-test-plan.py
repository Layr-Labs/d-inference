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
  run LANE SHARD     run the selections of one shard, each in its own process
  audit              check the plan against the sources and the workflow
"""

import argparse
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
WORKFLOW = ROOT / ".github/workflows/ci.yml"
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
    # Its CPU path is the longest suite, so it has a shard of its own.
    Selection("base-batch-session", "blocking", 1, suites=("QwenTensorParallelBatchSessionTests",)),
    Selection("base", "blocking", 2),
    Selection("qwen-tp-batch-gpu", "blocking", 3, {"QWEN_TP_BATCH_GPU": "1"}, tests=(
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
    Selection("qwen-tp-batch-gpu-paged", "blocking", 3, {"QWEN_TP_BATCH_GPU": "1", "QWEN_TP_BATCH_KV": "paged"}, tests=(
        "cohortSurvivorKeepsOnlyItsOwnRows",
        "routedExpertCapacityOneAndTwoKeepExactPagedLogitsAndHistory",
        "capacityOneAndTwoKeepExactPagedLogitsAndHistory",
        "pagesGrowMidDecodeWithoutChangingAByte",
        "promptLayerSubmissionKeepsEveryBit",
    )),
    Selection("qwen-tp-mtp-gpu", "blocking", 3, {"QWEN_TP_MTP_GPU": "1"}, tests=QWEN_TP_MTP_GPU_TESTS),
    Selection("qwen-tp-aqv-gpu", "blocking", 3, {"QWEN_TP_AQV_GPU": "1"}, tests=(
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
    Selection("qwen-tp-moe-gpu", "blocking", 3, {"QWEN_TP_MOE_GPU": "1", "QWEN_TP_MOE_GPU_DIAG": "1"}, tests=(
        "packedSharedExpertCollectiveIsBitIdenticalOnTwoGPURanks",
        "packedRunsRepeatAndShortPromptsOnTwoGPURanks",
    )),
    Selection("qwen-tp-share-probe-gpu", "blocking", 3, {"QWEN_TP_SHARE_PROBE_GPU": "1"}, tests=(
        "eachRankTimesItsShareAloneAndReleasesItsRequest",
        "aRefusalOrAFailureGivesNoProbeAndKeepsNothing",
    )),
    Selection("glm53-prefix-ssd", "blocking", 3, {"GLM53_PREFIX_SSD": "1"}, tests=(
        "aServingStageRestoresFromTheSSDExactly",
        "aServingStageRestoresFromABalancedRecord",
    )),
    Selection("glm53-paged-kv", "blocking", 2, {"GLM53_PAGED_KV": "1"}, tests=(
        "pagedRequestsDecideAndHoldWhatContiguousOnesDo",
        "pagedMediaRequestsDecideAndHoldWhatContiguousOnesDo",
    )),
    Selection("glm53-row-invariance", "blocking", 2, {"GLM53_ROW_INVARIANCE": "1"}, tests=(
        "roundsAreEachRequestsOwnRound",
    )),
    Selection("glm53-depth-invariance", "blocking", 2, {"GLM53_DEPTH_INVARIANCE": "1"}, tests=(
        "prefillIsTheSameWithAndWithoutTheSwitch",
        "unpaddedLastRoundsStayOneRowWindows",
    )),
    Selection("glm53-window-census", "blocking", 2, {"GLM53_WINDOW_CENSUS": "1"}, tests=(
        "sublayerCensus",
        "projectionRowCensus",
    )),
    Selection("tf32-off", "blocking", 2, {"MLX_ENABLE_TF32": "0"}, tests=(
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
        return PACKAGE, [str(NESTED_SUITE), *swift_arguments(selection)]
    directory = PACKAGE / "Tests" / selection.runner
    if (directory / "run.py").is_file():
        return ROOT, ["python3", str(directory / "run.py"), "--output", str(output / selection.runner)]
    return ROOT, ["bash", str(directory / "run.sh")]


# Variables the runtime tests read to change what they run; no selection
# inherits one from the runner.
TEST_SWITCH_PREFIXES = ("QWEN_TP_", "GLM53_", "DARKBLOOM_PAGED_BENCH", "PREFIX_RECORD_")


def environment(selection):
    switches = {name for other in SELECTIONS for name in other.environment}
    values = {name: value for name, value in os.environ.items()
              if name not in switches and not name.startswith(TEST_SWITCH_PREFIXES)}
    return {**values, **PROCESS_ENVIRONMENT, **selection.environment}


def shards(lane):
    return sorted({selection.shard for selection in SELECTIONS if selection.lane == lane})


def run(lane, shard):
    selected = [selection for selection in SELECTIONS if selection.lane == lane and selection.shard == shard]
    if not selected:
        raise ValueError(f"No selections in {lane} shard {shard}")
    output = Path(tempfile.mkdtemp(prefix="cluster-runner-output-"))
    rows = []
    for selection in selected:
        cwd, argv = command(selection, output)
        print(f"::group::{selection.name}", flush=True)
        started = time.monotonic()
        status = subprocess.run(argv, cwd=cwd, env=environment(selection)).returncode
        seconds = time.monotonic() - started
        print("::endgroup::", flush=True)
        rows.append((selection.name, status, seconds))
        if status:
            level = "warning" if lane == "nonblocking" else "error"
            print(f"::{level}::{selection.name} failed with exit status {status}", flush=True)
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
