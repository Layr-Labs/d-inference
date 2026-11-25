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
the model-free runner scripts). No lane runs a benchmark or a census that only
prints: CI is not a benchmark. Those gated tests are in `RUN_BY_HAND`, with the
switch that runs each one by hand.

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
import shutil
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
    # Base, with `suites`: only these test functions of the suites. The base
    # selection of the same suites without `functions` runs all the others,
    # so a new test of the suites runs there.
    functions: tuple = ()
    # Focused: a runner script under libs/darkbloom-cluster/Tests, or, with
    # `script`, only the runner's name.
    runner: str | None = None
    # Focused, provider side: the runner's script, relative to the repository.
    script: str | None = None
    # The shard runs its groups at the same time, each group's selections one
    # after another in plan order; the selections with no group then run one
    # at a time, alone on the Mac. A focused runner script (run.sh) compiles
    # first, beside the shard's other runner scripts (`build_phase`), and its
    # checks then run alone in that order.
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

# The Gemma 4 suites: 823 s in run 44654386274 (2026-11-20), in which
# Gemma4TensorParallelTests (388 s) ran alone on shard 4 and the others
# (435 s) alone on shard 5. `audit` checks that every Gemma suite is listed, that
# each has exactly one base selection of whole Gemma suites (that selection skips
# the tests a selection of its functions names), and that a selection
# of Gemma suites holds no other suite.
GEMMA_SUITES = (
    "Gemma4BatchArithmeticAgreementTests", "Gemma4BatchDecodeTests", "Gemma4NativeContextTests",
    "Gemma4StagePagedSyntheticTests", "Gemma4TensorParallelPrefixTests", "Gemma4TensorParallelRuntimeTests",
    "Gemma4TensorParallelTests", "GemmaPrefillArithmeticTests", "GemmaPrefixChunkTests", "ResidentAdmissionGemma4Tests",
)
GEMMA_TENSOR_PARALLEL_SUITES = ("Gemma4TensorParallelTests",)
# The suite's split-sum oracle over three quantization tables: 200 of the
# suite's 388 s. It runs in a process of its own; the suite's other tests run
# in base-gemma-tensor-parallel.
GEMMA_TENSOR_PARALLEL_ORACLE_TESTS = ("tensorParallelRanksEqualTheSplitSumOracleBitwise",)
GEMMA_RUNTIME_SUITES = ("Gemma4TensorParallelRuntimeTests",)
GEMMA_PREFIX_SUITES = ("Gemma4TensorParallelPrefixTests",)
GEMMA_BATCH_DECODE_SUITES = ("Gemma4BatchDecodeTests",)
# The Gemma suites with a selection of their own; base-gemma runs the others.
GEMMA_OWN_SELECTION_SUITES = (GEMMA_TENSOR_PARALLEL_SUITES + GEMMA_RUNTIME_SUITES + GEMMA_PREFIX_SUITES
                              + GEMMA_BATCH_DECODE_SUITES)
# CPU suites of other families that left `base` (469 s alone on shard 1 before they left) for
# CPU groups: the Qwen tensor-parallel wavefront and MTP session suites (86 s
# in runs 44924815069 and 44927907327), on shard 2, and the MiMo
# tensor-parallel suites (101 to 104 s), on shard 5. Their switched tests
# still run only in their switch's selection.
QWEN_TP_CPU_SUITES = ("QwenTensorParallelAssistedPromptWavefrontTests", "QwenTensorParallelMTPSessionTests")
MIMO_TP_SUITES = ("MiMoTensorParallelFloat32PartialTests", "MiMoTensorParallelResidentTests",
                  "MiMoTensorParallelSpeculativeTests", "MiMoTensorParallelTests")
BATCH_SESSION_SUITES = ("QwenTensorParallelBatchSessionTests",)
# The batch-session suite's warm and balanced SSD prefix tier tests: 297 s
# in dev run 44670152270, 353 to 422 s on Darkbloom (runs 44909381968,
# 44912466550, 44914459288: warm 217 to 261 s, SSD 136 to 161 s). Each runs in
# a process of its own, on shards 3 and 6; the partition test runs in
# base-batch-session-partitions, the two history tests below in
# base-batch-session-histories and the suite's other tests in base-batch-session.
BATCH_SESSION_WARM_PREFIX_TIER_TESTS = ("warmAttentionPrefixesPreserveMixedHistoriesAndRetirement",)
BATCH_SESSION_SSD_PREFIX_TIER_TESTS = ("ssdBalancedRecordsAdoptOnBothRanksWithAnExactBand",)
# The suite's two longest other tests (99 to 107 and 88 to 93 s in those runs),
# in a process of their own on shard 7: base-batch-session ran 368 to 393 s.
BATCH_SESSION_HISTORY_TESTS = (
    "actualShardsBatchIndependentHistoriesWithoutMultiplyingCollectives",
    "controlWordsInTheSelectionSumKeepTokensAndLogprobs",
)
# The suite's tenant-partition test (89 to 96 s), in a process of its own on shard 7.
BATCH_SESSION_PARTITION_TESTS = ("partitionedPrefixesNeverCrossTenantsAndADisabledRequestKeepsNothing",)
# Small base suites (32 to 46 s) that left `base` for shard 4 to shorten shard 1.
SHARD_4_BASE_SUITES = ("GLM5NextTensorParallelPrefillPlanTests", "GPTOSSBatchForwardTests",
                       "QwenTensorParallelMediaAdmissionTests")
# The three longest base suites without a model's memory (synthetic Qwen 3.5
# stage KV and the SSD prefix record codec: 72 and 89 s in runs 44895671420 and
# 44898503457), run on shard 5 after the Gemma batch decode suite. Shard 1
# ran `base`, the probe and qwen-tp-aqv-gpu one after another for 411 and
# 469 s, the longest shard in both runs.
SHARD_5_BASE_SUITES = ("CBv2PagedGrowthSyntheticTests", "CBv2PagedQuantizedStageTests", "PrefixDiskEncodingTests")

SELECTIONS = (
    # Every shard's test step is planned to stay under about 300 s on a
    # 4-vCPU Darkbloom runner. Seconds below are each process's wall time in
    # runs 44924815069 and 44927907327 (2026-11-21) unless they name other
    # runs; in those runs shards 1, 4 and 5 ran 267 to 395 s and the others
    # 169 to 243 s.
    # Shard 1 runs one process at a time: `base` (108 to 145 s), then the
    # share probe, then base-gemma-runtime (92 to 109 s). The probe times its
    # share against a 1.5 s budget, so it runs right after `base` and never on
    # a Mac just after the concurrent GPU groups (run 41973436945 failed it
    # there).
    # Shards 2, 3, 6 and 7 each run a GPU group beside a CPU group that starts
    # with a batch-session selection. Shard 2: qwen-tp-batch-gpu (182 s) and
    # tf32-off, beside base-batch-session (155 s), then base-qwen-tp-cpu.
    # Shard 3: qwen-tp-batch-gpu-paged, the MoE, GLM prefix-SSD and paged-KV
    # (35 to 54 s), row and depth invariance and Gemma diagnostic selections,
    # beside the warm prefix tier test (179 to 217 s). Shard 6:
    # qwen-tp-mtp-gpu (179 s), beside the SSD prefix tier test (112 s), then
    # base-gemma-prefix (75 to 87 s). Shard 7: the batch GPU prefix depth test
    # (80 s), then qwen-tp-aqv-gpu (128 to 161 s), beside the suite's two
    # history tests (148 s), then its partition test.
    # Shards 4 and 5 each run two groups of base selections (below).
    Selection("base-batch-session", "blocking", 2, suites=BATCH_SESSION_SUITES, group=2),
    Selection("base-batch-session-warm-prefix-tier", "blocking", 3, suites=BATCH_SESSION_SUITES,
              functions=BATCH_SESSION_WARM_PREFIX_TIER_TESTS, group=2),
    Selection("base-batch-session-ssd-prefix-tier", "blocking", 6, suites=BATCH_SESSION_SUITES,
              functions=BATCH_SESSION_SSD_PREFIX_TIER_TESTS, group=2),
    Selection("base-batch-session-histories", "blocking", 7, suites=BATCH_SESSION_SUITES,
              functions=BATCH_SESSION_HISTORY_TESTS, group=2),
    Selection("base", "blocking", 1),
    Selection("qwen-tp-share-probe-gpu", "blocking", 1, {"QWEN_TP_SHARE_PROBE_GPU": "1"}, tests=(
        "eachRankTimesItsShareAloneAndReleasesItsRequest",
        "aRefusalOrAFailureGivesNoProbeAndKeepsNothing",
    )),
    # Shards 4 and 5: model-free base suites, nearly all on the CPU, where each
    # process keeps about one vCPU busy (busy vCPUs 0.83 on average while
    # Gemma4TensorParallelTests ran alone, run 44654386274). Each shard runs
    # two groups at the same time: shard 4 the oracle (195 to 247 s), beside
    # the rest of Gemma4TensorParallelTests (183 to 231 s), then base-shard-4
    # (32 to 46 s); shard 5 the Gemma batch decode suite (146 s), then
    # base-shard-5 (65 to 67 s), beside the other Gemma suites (123 to 125 s),
    # then the MiMo tensor-parallel suites. The base selections of the other
    # shards ran here, where shards 4 and 5 ran 316 to 395 s.
    Selection("base-gemma-tensor-parallel-oracle", "blocking", 4, suites=GEMMA_TENSOR_PARALLEL_SUITES,
              functions=GEMMA_TENSOR_PARALLEL_ORACLE_TESTS, group=1),
    Selection("base-gemma-runtime", "blocking", 1, suites=GEMMA_RUNTIME_SUITES),
    Selection("base-gemma-tensor-parallel", "blocking", 4, suites=GEMMA_TENSOR_PARALLEL_SUITES, group=2),
    Selection("base-gemma-prefix", "blocking", 6, suites=GEMMA_PREFIX_SUITES, group=2),
    Selection("base-shard-4", "blocking", 4, suites=SHARD_4_BASE_SUITES, group=2),
    Selection("base-gemma-batch-decode", "blocking", 5, suites=GEMMA_BATCH_DECODE_SUITES, group=1),
    Selection("base-qwen-tp-cpu", "blocking", 2, suites=QWEN_TP_CPU_SUITES, group=2),
    Selection("base-shard-5", "blocking", 5, suites=SHARD_5_BASE_SUITES, group=1),
    Selection("base-gemma", "blocking", 5,
              suites=tuple(suite for suite in GEMMA_SUITES if suite not in GEMMA_OWN_SELECTION_SUITES), group=2),
    Selection("base-mimo-tp", "blocking", 5, suites=MIMO_TP_SUITES, group=2),
    Selection("base-batch-session-partitions", "blocking", 7, suites=BATCH_SESSION_SUITES,
              functions=BATCH_SESSION_PARTITION_TESTS, group=2),
    Selection("qwen-tp-batch-gpu", "blocking", 2, {"QWEN_TP_BATCH_GPU": "1"}, tests=(
        "bothTilesGiveTheSameBytes",
        "actualHybridShardsPreserveAttentionConvAndSSMRows",
        "nineBRatioDenseShardsBatchExactly",
        "routedExpertShardsBatchExactly",
        "routedExpertNativeMixedSamplingKeepsRowsIndependent",
        "warmHybridPrefixesPreserveConvSSMAndMixedPositions",
        "ssdHybridPrefixesRestoreConvSSMAfterTheTiersReopen",
        "mergedStepTemporariesStayWithinTheirCharge",
        "mergedFramesKeepEveryBit",
        "executorRunsThePlannedMergedStep",
    ), group=1),
    # The batch GPU switch's one test of QwenTensorParallelPrefixDepthTests,
    # which shares no suite with the tests above.
    Selection("qwen-tp-batch-gpu-prefix-depth", "blocking", 7, {"QWEN_TP_BATCH_GPU": "1"}, tests=(
        "deepRestoresEqualColdPrefillOnBothRanks",
    ), group=1),
    Selection("qwen-tp-batch-gpu-paged", "blocking", 3, {"QWEN_TP_BATCH_GPU": "1", "QWEN_TP_BATCH_KV": "paged"}, tests=(
        "cohortSurvivorKeepsOnlyItsOwnRows",
        "routedExpertCapacityOneAndTwoKeepExactPagedLogitsAndHistory",
        "capacityOneAndTwoKeepExactPagedLogitsAndHistory",
        "pagesGrowMidDecodeWithoutChangingAByte",
        "promptLayerSubmissionKeepsEveryBit",
    ), group=1),
    Selection("qwen-tp-mtp-gpu", "blocking", 6, {"QWEN_TP_MTP_GPU": "1"}, tests=QWEN_TP_MTP_GPU_TESTS, group=1),
    Selection("qwen-tp-aqv-gpu", "blocking", 7, {"QWEN_TP_AQV_GPU": "1"}, tests=(
        "declinesWhatItDoesNotCover",
        "agreesWithTheDequantizedProduct",
        "everyVectorEqualsItsOwnSingleVectorCall",
        "everyLayoutGivesTheSameBits",
        "swigluEqualsTwoProjectionsAndTheSwiGLU",
        "swigluEqualsTheCompiledSwiGLUAtEveryGateValue",
        "siluMultiplyEqualsTheUnfusedChain",
        "sigmoidGateEqualsTheUnfusedChain",
        "cachedGatedDeltaScalesEqualFreshOnes",
    ), group=1),
    Selection("qwen-tp-moe-gpu", "blocking", 3, {"QWEN_TP_MOE_GPU": "1", "QWEN_TP_MOE_GPU_DIAG": "1"}, tests=(
        "packedSharedExpertCollectiveIsBitIdenticalOnTwoGPURanks",
        "packedRunsRepeatAndShortPromptsOnTwoGPURanks",
    ), group=1),
    Selection("glm53-prefix-ssd", "blocking", 3, {"GLM53_PREFIX_SSD": "1"}, tests=(
        "aServingStageRestoresFromTheSSDExactly",
        "aServingStageRestoresFromABalancedRecord",
    ), group=1),
    Selection("glm53-paged-kv", "blocking", 3, {"GLM53_PAGED_KV": "1"}, tests=(
        "pagedRequestsDecideAndHoldWhatContiguousOnesDo",
        "pagedMediaRequestsDecideAndHoldWhatContiguousOnesDo",
    ), group=1),
    Selection("glm53-row-invariance", "blocking", 3, {"GLM53_ROW_INVARIANCE": "1"}, tests=(
        "roundsAreEachRequestsOwnRound",
    ), group=1),
    Selection("glm53-depth-invariance", "blocking", 3, {"GLM53_DEPTH_INVARIANCE": "1"}, tests=(
        "prefillIsTheSameWithAndWithoutTheSwitch",
        "unpaddedLastRoundsStayOneRowWindows",
    ), group=1),
    Selection("tf32-off", "blocking", 2, {"MLX_ENABLE_TF32": "0"}, tests=(
        "receiverCommitPrecedesProducerPublicationAndMatchesFullCachedForward",
    ), group=1),
    Selection("gemma-tp-diag", "blocking", 3, {"GEMMA_TP_DIAG": "1"}, tests=(
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
    # Asserts that windows of two to four rows give one class under the
    # width-invariant switch; the census lines it also prints are the report.
    Selection("glm53-window-width-census", "nonblocking", 2, {"GLM53_WINDOW_CENSUS": "1"}, tests=(
        "windowWidthCensus",
    )),
    *(Selection(f"focused-{name}", "focused", 1, runner=name) for name in (
        "BootstrapChecks", "CapabilityChecks", "CheckpointChecks", "DeadlineChecks", "ExitChecks",
        "GLMImageAdmissionChecks", "LinkControlChecks", "LinkWorkerChecks", "NativePairChecks",
        "ObservabilityChecks", "PlacementChecks", "PrefixPolicyChecks", "PreludeChecks",
        "ProcessChecks", "ProtocolChecks", "QwenMediaChecks", "RemoteChecks", "SSHChecks",
        "SecurityChecks", "StageTransferChecks", "StillImageChecks", "TensorParallelPlanChecks",
    )),
    # The provider-side runners of shard 1 compile beside the runner scripts above.
    *(Selection(f"focused-{name}", "focused", 1, runner=name, script=script) for name, script in (
        ("ClusterPairingChecks", "provider-swift/Tests/ClusterPairingChecks/run.sh"),
        ("ClusterDiagnosticsChecks", "provider-swift/Tests/ClusterDiagnosticsChecks/run.sh"),
        ("ClusterPlacementFlowChecks", "provider-swift/Tests/ClusterPlacementChecks/run-flow.sh"),
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
# Gated tests that CI never runs, with the switch that runs each one by hand:
# benchmarks that time kernels or records, and censuses that print classes and
# assert nothing. CI is not a benchmark, so no selection runs them; the base
# selections skip them by name. docs/developer/test.md has the commands.
RUN_BY_HAND = {
    "verifyAndPrefillAttention": "DARKBLOOM_PAGED_BENCH",
    "throughputAgainstMLXCalls": "QWEN_TP_AQV_BENCH",
    "wideKernelVariantThroughput": "QWEN_TP_WIDE_BENCH",
    "encodingThroughputAtTheBetaShape": "PREFIX_RECORD_ENCODE_BENCH",
    "sublayerCensus": "GLM53_WINDOW_CENSUS",
    "projectionRowCensus": "GLM53_WINDOW_CENSUS",
}
# Runners the workflow runs as steps of their own: the release builds in
# Cluster Release Build Checks, the others in shard 2 of Cluster Focused Checks.
METADATA_JOB_RUNNERS = ("GPTOSSStageChecks", "NemotronStageChecks", "PrefillScheduleChecks", "StageMetadataChecks")


def functions_regex(names):
    return f"/(?:{'|'.join(sorted(names))})\\("


def suites_regex(suites):
    return f"^{MODULE}[./](?:{'|'.join(sorted(suites))})(?:[./]|$)"


def suite_functions_regex(suites, names):
    """The test functions `names` of `suites`, and of no other suite."""
    return f"^{MODULE}[./](?:{'|'.join(sorted(suites))})/(?:{'|'.join(sorted(names))})\\("


def switched_regex():
    """Every test a base selection must not run: the switched, model-gated and by-hand tests."""
    gated = [name for selection in SELECTIONS for name in selection.tests] + list(REQUIRES_MODEL) + list(RUN_BY_HAND)
    return f"{functions_regex(gated)}|{suites_regex(REQUIRES_MODEL_SUITES)}"


def swift_arguments(selection):
    """The run-nested-suite.sh arguments: the filter, then extra `swift test` arguments."""
    if selection.tests:
        return [functions_regex(selection.tests), "--no-parallel"]
    if selection.functions:
        return [suite_functions_regex(selection.suites, selection.functions), "--skip", switched_regex(),
                "--no-parallel"]
    if selection.suites:
        # The tests that a selection of some of these suites' functions takes.
        taken = [suite_functions_regex(other.suites, other.functions) for other in SELECTIONS
                 if other.functions and other.suites == selection.suites]
        return [suites_regex(selection.suites), "--skip", "|".join([switched_regex(), *taken]), "--no-parallel"]
    others = {suite for other in SELECTIONS if other.base and other.suites for suite in other.suites}
    return [f"^{MODULE}[./]", "--skip", f"{switched_regex()}|{suites_regex(others)}", "--no-parallel"]


def command(selection, output):
    if selection.runner is None:
        filter_regex, *extra = swift_arguments(selection)
        # The groups of a shard share one build. With --skip-build no process
        # writes it, so they skip SwiftPM's workspace lock on .build, which
        # would otherwise run them one after another, and plan the build in
        # memory instead of in llbuild's package-structure step, which holds
        # .build/build.db exclusively while it plans: a process that waited 5 s
        # for it found the database locked, ran its tests and exited 1.
        shared_build = ["--ignore-lock", "--disable-build-manifest-caching"] if selection.group is not None else []
        return PACKAGE, [str(NESTED_SUITE), filter_regex, *shared_build, *extra]
    if selection.script is not None:
        return ROOT, ["bash", str(runner_script(selection))]
    directory = PACKAGE / "Tests" / selection.runner
    if (directory / "run.py").is_file():
        return ROOT, ["python3", str(directory / "run.py"), "--output", str(output / selection.runner)]
    return ROOT, ["bash", str(directory / "run.sh")]


# Variables the runtime tests read to change what they run, the `RUN_BY_HAND`
# switches among them; no selection inherits one from the runner.
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


def execute(selection, output, log=None, temporary=None, phase=None):
    """Run one selection in its own process; return (exit status, seconds).

    `phase` runs one phase of a focused runner script (`build` or `run`,
    libs/darkbloom-cluster/Tests/Support/check-phases.sh).
    """
    cwd, argv = command(selection, output)
    env = environment(selection)
    if temporary is not None:
        env["TMPDIR"] = str(temporary)
    if phase is not None:
        env.update(CLUSTER_CHECK_PHASE=phase, CLUSTER_CHECK_STATE=str(build_state(selection, output)))
    started = time.monotonic()
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
    return status, time.monotonic() - started


def start_gap():
    """Seconds between the starts of a shard's groups (CLUSTER_TEST_START_GAP, default 15).

    Each later group starts this long after the one before. The gap was
    added when groups that started together met on SwiftPM's build database
    (shard 2's two groups in every run of runs 42041608780 to 42065297991);
    grouped selections no longer open it (`command`). Unlike the provider
    shards' processes, the groups still start apart: in run 44903571797,
    the one run without the gap, shard 2's CPU group (base-batch-session),
    started beside its GPU group, failed its bitwise batch-against-solo
    check on a host where the GPU group ran 468 s instead of 260 to 308 s.
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


def runner_script(selection):
    """A focused runner's bash script: its `script`, or run.sh under libs/darkbloom-cluster/Tests."""
    return ROOT / selection.script if selection.script is not None else PACKAGE / "Tests" / selection.runner / "run.sh"


def phased(selection):
    """A focused runner's bash script: it compiles in one phase and runs its
    checks in another (Tests/Support/check-phases.sh). A run.py runner runs whole."""
    if selection.script is not None:
        return True
    return selection.runner is not None and not (PACKAGE / "Tests" / selection.runner / "run.py").is_file()


def build_state(selection, output):
    """The file in which a runner's compile phase names its build directory."""
    return output / f"{selection.name}.build-directory"


# The longest compile phases, longest first (seconds on a 4-vCPU Darkbloom Mac,
# run 44670986975: 82, 79, 65, 52, 49, 41). `build_phase` starts them before
# the others, so a Mac with few cores does not end the phase on one of them.
LONGEST_COMPILES = ("focused-ClusterDiagnosticsChecks", "focused-RemoteChecks", "focused-LinkControlChecks",
                    "focused-ProcessChecks", "focused-ClusterPairingChecks", "focused-ClusterPlacementFlowChecks")


def build_phase(selections, output):
    """Compile every runner script of `selections` at the same time, up to one
    per core, each logging to its own file; return {name: (status, seconds, log)}.

    Compiling is most of a runner's time, so the runners compile together;
    their checks, timed ones among them, then run one at a time with nothing
    beside them. A runner whose compile phase fails runs no check; its build
    directory is removed.
    """
    def build(selection):
        path = output / f"{selection.name}.build.log"
        with path.open("wb") as log:
            status, seconds = execute(selection, output, log, phase="build")
        state = build_state(selection, output)
        if status == 0 and not state.is_file():
            with path.open("a") as log:
                log.write(f"{selection.runner} ran without a compile phase (Tests/Support/check-phases.sh)\n")
            status = 1
        if status and state.is_file():
            shutil.rmtree(state.read_text().strip(), ignore_errors=True)
        return selection.name, (status, seconds, path)

    selected = sorted((selection for selection in selections if phased(selection)),
                      key=lambda selection: LONGEST_COMPILES.index(selection.name)
                      if selection.name in LONGEST_COMPILES else len(LONGEST_COMPILES))
    if not selected:
        return {}
    started = time.monotonic()
    with ThreadPoolExecutor(max_workers=min(len(selected), os.cpu_count() or 1)) as pool:
        built = dict(pool.map(build, selected))
    print(f"Compiled {len(selected)} runner scripts at the same time in {time.monotonic() - started:.0f} s "
          f"({sum(seconds for _, seconds, _ in built.values()):.0f} s of compiling in all)", flush=True)
    return built


def run_checks(selection, output, status, seconds, log):
    """Print a runner's compile phase log, then run its checks alone unless
    that phase failed; return (exit status, seconds of the checks)."""
    print(f"Compile phase ({seconds:.0f} s, beside the other runner scripts):", flush=True)
    sys.stdout.buffer.write(log.read_bytes())
    sys.stdout.flush()
    if status:
        print("The compile phase failed, so no check ran.", flush=True)
        return status, 0.0
    print("Checks, alone:", flush=True)
    return execute(selection, output, phase="run")


def run(lane, shard):
    selected = [selection for selection in SELECTIONS if selection.lane == lane and selection.shard == shard]
    if not selected:
        raise ValueError(f"No selections in {lane} shard {shard}")
    output = Path(tempfile.mkdtemp(prefix="cluster-runner-output-"))
    built = build_phase(selected, output)
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
            sys.stdout.buffer.write(path.read_bytes())
            sys.stdout.flush()
            print("::endgroup::", flush=True)
            results[selection.name] = (status, seconds)
    for selection in selected:
        if selection.group is None:
            print(f"::group::{selection.name}", flush=True)
            if selection.name in built:
                results[selection.name] = run_checks(selection, output, *built[selection.name])
            else:
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
            handle.write(f"### Cluster {lane} shard {shard}\n\n| Selection | Result | Seconds | Compile phase seconds |\n"
                         "|---|---|---|---|\n")
            for name, status, seconds in rows:
                compiled = f"{built[name][1]:.0f}" if name in built else "-"
                handle.write(f"| {name} | {'passed' if status == 0 else 'failed'} | {seconds:.0f} | {compiled} |\n")
    return 1 if any(status for _, status, _ in rows) else 0


def closing_paren(text, index):
    """The index just past the `)` that closes the `(` at `index`."""
    depth = 0
    while True:
        depth += {"(": 1, ")": -1}.get(text[index], 0)
        index += 1
        if depth == 0:
            return index


def gated_in_sources(directory=RUNTIME_TESTS):
    """(gated test functions, gated suites, function names defined more than once)."""
    functions, suites, defined = set(), set(), {}
    attribute = re.compile(r"@(Test|Suite)\(")
    for path in sorted(directory.rglob("*.swift")):
        text = path.read_text()
        for match in re.finditer(r"\bfunc (\w+)\(", text):
            defined[match.group(1)] = defined.get(match.group(1), 0) + 1
        for match in attribute.finditer(text):
            index = closing_paren(text, match.end() - 1) - 1
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


def ungated_tests_of(suites, directory=RUNTIME_TESTS):
    """The test functions without an `.enabled(if:` trait in the files that declare `suites`."""
    names = set()
    for path in sorted(directory.rglob("*.swift")):
        text = path.read_text()
        if not any(re.search(rf"\b(?:struct|class|enum) {suite}\b", text) for suite in suites):
            continue
        for match in re.finditer(r"@Test\b", text):
            index = match.end()
            if text.startswith("(", index):
                index = closing_paren(text, index)
                if ".enabled(if:" in text[match.end():index]:
                    continue
            function = re.match(r"\s+func (\w+)\(", text[index:])
            if function:
                names.add(function.group(1))
    return names


def audit_split_suites(repeated):
    """A selection of some functions of base suites: each is an ungated test of
    those suites, named once, and one other base selection runs the rest."""
    errors = []
    split = [selection for selection in SELECTIONS if selection.functions]
    named = [name for selection in split for name in selection.functions]
    for name in sorted({name for name in named if named.count(name) > 1}):
        errors.append(f"{name} is in more than one selection of suite functions")
    for selection in split:
        rest = [other.name for other in SELECTIONS
                if other.base and not other.functions and other.suites == selection.suites]
        if not selection.base or not selection.suites or len(rest) != 1:
            errors.append(f"{selection.name} names suite functions, so it must be a base selection of suites "
                          f"with exactly one base selection of the same suites for their other tests, not {rest}")
        tests = ungated_tests_of(selection.suites or ())
        for name in sorted(set(selection.functions) - tests):
            errors.append(f"{name} ({selection.name}) is not an ungated test of {selection.suites}")
        for name in sorted(set(selection.functions) & repeated):
            errors.append(f"{name} ({selection.name}) is defined more than once; its name does not select one test")
    return errors


def audit_gemma_selections():
    """Every Gemma suite is in exactly one base selection of whole suites (one
    without `functions`); a selection of Gemma suites holds only Gemma suites."""
    errors = []
    for suite in GEMMA_SUITES:
        owners = [selection.name for selection in SELECTIONS
                  if selection.base and selection.suites and suite in selection.suites and not selection.functions]
        if len(owners) != 1:
            errors.append(f"Gemma suite {suite} must be in exactly one base selection of whole suites, not {owners}")
    for selection in SELECTIONS:
        suites = set(selection.suites or ())
        if suites & set(GEMMA_SUITES) and suites - set(GEMMA_SUITES):
            errors.append(f"{selection.name} must hold Gemma suites and nothing else")
    return errors


def audit():
    errors = []
    planned = [name for selection in SELECTIONS for name in selection.tests]
    for name in sorted({name for name in planned if planned.count(name) > 1}):
        errors.append(f"{name} is in more than one selection")
    named_once = planned + list(REQUIRES_MODEL) + list(RUN_BY_HAND)
    for name in sorted(set(planned) & set(REQUIRES_MODEL) | set(planned) & set(RUN_BY_HAND)
                       | set(REQUIRES_MODEL) & set(RUN_BY_HAND)):
        errors.append(f"{name} must be in only one of the selections, REQUIRES_MODEL and RUN_BY_HAND")
    for name, switch in sorted(RUN_BY_HAND.items()):
        if not switch.startswith(TEST_SWITCH_PREFIXES):
            errors.append(f"{name}'s switch {switch} must start with one of TEST_SWITCH_PREFIXES")
    functions, suites, repeated = gated_in_sources()
    for name in sorted(functions - set(named_once)):
        errors.append(f"Gated test {name} is in no selection, REQUIRES_MODEL or RUN_BY_HAND")
    for name in sorted(set(named_once) - functions):
        errors.append(f"{name} is planned but is not a gated test in {RUNTIME_TESTS.relative_to(ROOT)}")
    for name in sorted(set(named_once) & repeated):
        errors.append(f"{name} is defined more than once; its name does not select one test")
    if suites != set(REQUIRES_MODEL_SUITES):
        errors.append(f"Gated suites {sorted(suites)} differ from REQUIRES_MODEL_SUITES {sorted(REQUIRES_MODEL_SUITES)}")
    gemma = gemma_suites_in_sources()
    if gemma != set(GEMMA_SUITES):
        errors.append(f"Gemma suites in the sources {sorted(gemma)} differ from GEMMA_SUITES {sorted(GEMMA_SUITES)}")
    errors += audit_gemma_selections()
    errors += audit_split_suites(repeated)
    names = [selection.name for selection in SELECTIONS]
    if len(names) != len(set(names)) or any(selection.lane not in LANES for selection in SELECTIONS):
        errors.append("Selection names must be unique and every lane known")
    for lane in LANES:
        if shards(lane) != list(range(1, len(shards(lane)) + 1)):
            errors.append(f"{lane} shards are not numbered 1 to N: {shards(lane)}")
    runners = {path.parent.name for pattern in ("*/run.sh", "*/run.py") for path in (PACKAGE / "Tests").glob(pattern)}
    focused = {selection.runner for selection in SELECTIONS if selection.runner and selection.script is None}
    if runners != focused | set(METADATA_JOB_RUNNERS) or focused & set(METADATA_JOB_RUNNERS):
        errors.append(f"Runners {sorted(runners)} must each be in exactly one of the focused lane "
                      f"{sorted(focused)} and METADATA_JOB_RUNNERS {sorted(METADATA_JOB_RUNNERS)}")
    for selection in SELECTIONS:
        if selection.lane == "focused" and phased(selection):
            script = runner_script(selection)
            text = script.read_text() if script.is_file() else ""
            if "/Tests/Support/check-phases.sh" not in text or not re.search(r"(?m)^check_phases compile_checks\b", text):
                errors.append(f"{script.relative_to(ROOT)} must exist, compile in compile_checks and call `check_phases "
                              "compile_checks` (Tests/Support/check-phases.sh): CI compiles it beside the others")
    for name in sorted(set(LONGEST_COMPILES) - set(names)):
        errors.append(f"LONGEST_COMPILES names {name}, which is no selection")
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
