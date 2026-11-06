# Selected shared-runtime source staging

This is a MOVE-ready **source proposal**, not an integrated or compiler-validated package. The main repository, original 425-source JACCL workspace and all native binaries are untouched. No MLX dependency source, payload, build cache or executable is copied. The payload-cache revision and generation additions are not included yet.

`move-list.json` is the exact source/target/pin/declaration list: 52 Swift files and 107 top-level declarations, including 42 byte-identical whole-file moves, 8 selected top-level extractions and 2 member-method splits. `proposed/libs/darkbloom-cluster/Package.swift` is the ordinary SwiftPM library scaffold, with the existing five MLX products and no Python bootstrap. All runtime types remain internal. Native compiler validation and the public owner/worker facade remain the next reviewed increment.

The selected closure contains actual verified stage preparation/materialization, compact stage Session and owned CBv2 state, Plan/metadata/descriptor/storage validation, Collective/point-to-point transport, admitted JACCL configuration, reusable resident request lifecycle/step callbacks, and memory observation. Actual Qwen model code remains in MLXLLM. It does not contain benchmark Main/Options parsers, check bodies, full-model comparators or synthetic inference loops.

## Exact mixed seams staged

| Original | Selected shared declarations / change |
|---|---|
| Options.swift | ProbeError and existing diagnostic log only; no Options/CLI type |
| ModelLoading.swift | constructQwenModel and sha256 only; no loadModel dispatcher or LoadedModel |
| ModelPartition.swift | InferenceModelFamily and modelParameterLayout only; no generic partition/reduction dispatcher |
| QwenMoEPartition.swift | qwenPartitionInteger only; no MoE partition implementation |
| QwenPartitionPlan.swift | QwenPartitionKind only, required by prepared checkpoint policy |
| QwenLayerStageComparison.swift | QwenStageMemoryObservation only |
| QwenDenseObservedSourceBridge.swift | observedQwenDenseSource only; unwired compact-constructor bridge stays outside |
| QwenResidentJACCLConfiguration.swift | actual configuration/admission type only; its co-located check function stays outside |
| CBv2RequestGeometry.swift | move actual model-derived geometry; extract the exact init(loaded: LoadedModel,...) convenience body into experimental compatibility |
| LocalCorrectnessStorage.swift | move exact constants and validateByteCounts; extract exact generic partition validate/add bodies into experimental compatibility |

The two compatibility extensions are under `proposed/experiments/cluster/inference/SharedRuntimeCompatibility`. They retain byte-identical method bodies; imports/extension envelopes are new. They are **not** silently added to either build: internal type access must be resolved by the selected test/diagnostic adapter arrangement first. Their presence does not claim cross-module compilation.

`source_closure.py` and `stage_proposal.py` are source-only mechanical review aids. The former indexes top-level declarations, computes lexical references and includes same-type extensions; it deliberately stops Options and output side effects while deriving the base closure. The latter stages just the selected declarations and exact two method removals. No overload/typecheck/interpolation completeness claim is made. The larger unmodified resident entrypoint closure is separately visible in `lexical-closure.json`: 132 source files before resolving Options. Replacing Options with an unchecked miniature struct would lose CLI/admission restrictions and is not proposed.

## Required experiment adapters before the move is applied

* The remaining experiment imports cannot directly see internal moved types. `experiment-consumers.json` enumerates concrete remaining files and symbol references. It is a discovery list, not an excuse to mark all 107 declarations public.
* Runtime unit checks (`QwenLayerStagePlanCheck`, Session/schedule/storage/descriptor/JACCL checks and their fixtures) should become package tests with `@testable import DarkbloomClusterRuntime`. Existing standalone public test runners need an explicit mapped test entry. Preserve the old adapter-verify record semantics while choosing this mapping; do not quietly delete that mode or execute package tests as a subprocess from the product.
* Diagnostic operations which actually execute models need a narrow opt-in facade returning CPU metadata/results, not LoadedModel, Module, MLXArray, mutable Session or unvalidated Plan values. Existing `runQwenLongPrefillResident{Rank,Solo}Cohort` cannot move unchanged into the minimal library because their admission calls Options-based long/solo/reference/rank CLI validators. Keep those wrappers outside until the same closed typed admission is extracted; preserve the legacy one-shot loopback rule and current registered9B restrictions.
* The product-generation path is smaller: pipeline's typed `runQwenLayerStageGenerationRequest(loaded:plan:agreement:collective:onCommittedToken:check:)` has no Options dependency. Its separately pinned seven contracts, four driver files and readiness factory can become an additive overlay. Add a private resident load owner and public value-only controller around this path after root reviews the exact move list. A live resource admission/retirement implementation is still mandatory; no positive caller number/hash becomes permission.

## Next concrete build step after review

Stage only these 52 files and the package manifest into a root-owned integration workspace with the existing pinned `libs/mlx-swift` and `libs/mlx-swift-lm` paths. Compile `DarkbloomClusterRuntime` first to validate the mechanical closure; do not wire ProviderCore or claim a working worker yet. Then apply the agreed check/admission adapters, overlay the finalized generation driver, and add the thin native worker and provider owner wrapper. The existing provider fake-owner tests remain valuable, but do not establish actual backend readiness.

For real JACCL, the worker build must still use macOS26.2 SDK/deployment for **Cmlx as well as Swift** and source-matched metallib. The macOS14 library/provider build can compile the same sources with the JACCL stub; that is not a usable physical backend. Use a separate worker build directory and the already-proven explicit `--triple arm64-apple-macosx26.2 -Xcc -target -Xcc arm64-apple-macosx26.2` flags. The package scaffold does not change this policy.
