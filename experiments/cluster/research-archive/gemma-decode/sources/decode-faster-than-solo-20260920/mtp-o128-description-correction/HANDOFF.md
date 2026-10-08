# Describe only admitted O128 targets

Actual v2 metadata failed because `Gemma4BenchmarkInput.description()` unconditionally derived full, stage0 and stage1 budgets. The new O128 resource gate correctly rejects stage budgets. The full BF16 request was already valid: input construction calls `Gemma4ForwardRequest.make(... observedResidualDType:job.dtype)`, and that method sets the profile dtype from this value. The F32 values in the budget are conservative allocation ceilings, not a substituted request profile.

One source file changes: O16 retains the original three diagnostic targets; O128 describes only the actual validated full job target. No budget, dtype, profile, model, owner, resource floor or generation path changes. `compose.py` checks the exact inverse, actual description loop/derive arguments and dtype construction chain. The failed v2 metadata/native1/reaped witness is pinned.

Nine Foundation controls compile the exact new selection expression extracted from the runtime file and the real `Gemma4ForwardTarget` enum. Only the two job fields consumed by that expression are represented in a pure fixture struct; no MLX/model/resource APIs are mocked. The checks cover three O16 modes, both admitted O128 prompts, both forbidden O128 stage modes and127/129 refusals through the unchanged actual output-envelope helper. These source controls do not replace actual complete `--describe` integration.

Root source check: `python3 -B compose.py`. Guarded apply: `python3 -B compose.py --apply --output /Users/developer/DarkbloomDev/cluster-research/decode-faster-than-solo-20260920/build/o128-description-composition-1`. Exact122 files remain. Receipt fields add `outputDescriptionPredecessor`, `outputDescriptionCorrectionManifestSHA256`, `outputDescriptionCorrectionIntegrationSHA256` over actual9c764084.

Root Foundation command (output in a fresh qualification directory):

```sh
swiftc -swift-version 6 -warnings-as-errors -j 2 -parse-as-library Tests/Gemma4ForwardTarget.swift /Users/developer/DarkbloomDev/cluster-research/gemma4-execution-20260920/build/workspace/libs/darkbloom-cluster/Sources/DarkbloomClusterRuntime/Gemma4BenchmarkOutputEnvelope.swift Tests/SelectionChecks.swift -o /ABSOLUTE/NEW/qualification/description-checks
```

Then execute that owned CPU child. The author did not compile or run it. After the actual new native build, run `--describe` for P128/O128 and P4096/O128 full jobs and require exactly one `full` target; O16 must retain `full,stage0,stage1`. Full O128 must exit0/reap normally before model work. Actual O128 stage jobs must continue to fail at job admission. Current local/remote metadata harnesses do not require three target rows; the fresh v3 source binding changes only lineage/namespace and adds explicit target-set validation to the ordinary description reader.
