# Gemma EP adjacent temporary ledger

Source only, based on the actual full-model EP16/112 pass. No compilation, fixture execution, model, GPU, remote action or applied-workspace mutation by the author. This is a follow-on admission candidate, not a measured memory saving or performance result. `overlay.json` binds eight Runtime overlays and their actual qualified preimages, plus fourteen unchanged proof sources. No Package, SDK, vendor, MAIN, numerical kernel, wire or state-owner source changes.

The ordinary/default API retains the full 30-layer additive EP ledger. Only the private `GemmaExpertFullCorrectness` entry chooses `adjacentSynchronousV1`, with the same policy passed to its resource owner and both actual probe/request operations. It accepts only the final concrete `Gemma4ExpertWire`, not an arbitrary exchange callback. P32/C16/O2 and all current environment/workload refusals remain. C64/C128 are explicitly refused by this new policy even though the shared one-layer primitive supports them.

The candidate keeps two adjacent sets of the 19 added EP arrays, named `window0:ep:*` and `window1:ep:*`. All original 30-layer trunk activations, complete KV/window/rollback/probe state, selected weights, persistent casts, source staging, controls, 32 MiB native +32 MiB host transport allowance, and report/host evidence charges are preserved. Each remaining array still receives its actual allocator upper bound independently. At C16 the logical difference is:

`28 × 128 × (9 × 2816 × 4 + 3 × 704 × 4 + 7 × 4) = 393,709,568 bytes`.

The scalar guard adds 4,096 host bytes for the two operation trackers and policy metadata. The original 6/4/2 GiB floors, every check call, deadline, cache-zero requirement and owner phase inequality remain. This reduces conservative admission terms, not actual model weights or a measured RSS/allocator peak.

## Why two slots, with the exact existing fence

1. The unchanged SDK `Gemma4ExpertParallelModel.forward` calls decoder layers serially (lines 76–100), without storing the borrowed hook. `Gemma4Text.callAsExpertParallel` applies the original `weightedExpertSum` after the hook (lines 1411–1432); the dense branch, normalization, residual and scalar output remain lazy afterward. Consequently **one slot is insufficient**: the previous layer's expert rows/reassembly can remain reachable while the next layer begins.
2. The runtime hook already calls `eval(input, globalIDs, weights); try check()` before constructing the next local expert graph. These actual input/router roots depend on the preceding layer's weighted/residual output. In this direct inference entry there is no outer `grad`/`vmap`/compiled model transformation. The pinned MLX `eval` uses `eval_impl(..., false).wait()` (`transforms.cpp:364–378`); evaluated non-tracer nodes detach (`306–307`). `array::detach` clears graph inputs on the shared ArrayDesc (`array.cpp:117–130`, `array.h:27–28`), so retaining a Swift alias does not preserve the old dependency graph. Returned current-layer arrays themselves remain owned normally.
3. Input eval alone is not the entire backend lifetime proof. Every actual concrete Wire exchange performs completed controls/data and consumed ACKs. The unchanged `CollectivePointToPoint.complete` evaluates, synchronizes the CPU communication stream, and synchronizes the model GPU **including completion handlers** (lines 103–110). Thus the previous layer's graph/backend references have completed before this hook returns. Empty-assignment ranks still perform the completed controls. The Metal backend uses command buffers with unretained references (`device.cpp:325,561`) and tracks its internal temporaries through completion handlers (`473–485`), rather than granting permission to free buffers early.
4. A new hook-local `autoreleasepool` drains completed Objective-C/backend temporaries at that existing synchronous boundary. The returned lazy reassembly graph escapes the pool normally and stays charged in one of the two slots. No eval, stream synchronization, forward, tensor copy, route, reduction or transport operation is added or removed. By induction, at hook N entry only N−1's added EP graph can remain; while hook N works both slots are charged; its existing completed exchange removes older completed work before N+1.
5. A scalar guard enforces exact frame/layer sequence, successful input-eval check, successful concrete exchange completion, and return. Reentry, skipped/replayed layers/frames, missing fences or any thrown path poison it. Both complete probe/request sequences are required before report publication. The tracker retains no array, callback, owner or group. Native faults still take precedence in the unchanged enclosing `MLX.withError` handlers; any hook throw reaches the same failed CBv2 transaction before commit. Final-layer pending output is evaluated with all state roots by the unchanged `CBv2OwnedRequestState.run` (lines 84–106) before any next frame or commit.

This proof applies only to these pinned direct-call sources and the concrete completed Wire. It does not infer completion from an ACK alone, lower the full trunk ledger, clear the allocator cache between layers, or discount any retained state. A different asynchronous/device-only adapter must keep the default ledger until separately proved. Cache/OS residency can still prevent admission or require more actual memory than the logical delta suggests.

## Source and qualification commands

Root should inspect `runtime-and-consumer.patch` and the exact preimages before applying only the eight Runtime rows to its disposable build workspace. The existing target discovers the new Runtime file; no target or dependency rebuild is intentionally requested beyond the affected module/product. `check_source.py` verifies small pins, the unchanged owner check body, complete original trunk-budget body, exact hook-body inverse, and Python syntax. It does not run fixtures or compile.

```sh
cd /Users/developer/DarkbloomDev/cluster-research/gemma4-full-model-ep-temporary-liveness-20260920
python3 -B check_source.py
```

When root grants the compiler slot, use the existing bounded owned runner, fresh output directory/regular logs, and jobs2:

```sh
swiftc -swift-version 6 -warnings-as-errors -j 2 Runtime/Gemma4ExpertTemporaryWindow.swift Tests/TemporaryWindowChecks.swift -o QUALIFICATION_DIR/temporary-window-checks
QUALIFICATION_DIR/temporary-window-checks
```

There are **16 meaningful Foundation groups**: complete probe/request sequences, invalid purpose counts, layer/frame skips/replay, reentry, input-eval and exchange ordering, duplicate fences, incomplete/failed completion, and host charge. These are CPU control-contract checks, not proof of GPU memory retirement. The native `--check-local BOUND_JOB` keeps every original control and adds default-vs-adjacent exact trunk/state/cast/weight/staging comparisons, nil-policy encoding preservation, independent logical byte arithmetic, allocator rounding and >16-frame refusals.

Then rebuild only `GemmaExpertFullCorrectness` through the existing root build wrapper. Retain the old binary, source receipt and every existing cohort. Run actual `--check-local`, `--describe` and accepted/refused argument controls before a fresh bound physical case. The expected description now declares the exact temporary policy; its EP resource report is `gemma4_full_expert_correctness_resources_v2` with 43 additive terms and the explicit policy string. `Comparison/expert_report.py` is the small **strict successor** reader: it accepts only that new policy, the two exact slot ledgers and extra host charge. It must be composed into a fresh physical source namespace with the newly built binary/source pins and prospective descriptions; do not overwrite the old validator or re-label old reports. All numerical, process, EOF, resource, journal and alias validators stay in place.

First repeat the already accepted P32/C16/O2 full reference and EP16/112 pair with both full rows/all90 states independently on both ranks. Inspect actual MLX active/peak and OS free evidence, clean native exit/group/journal/alias retirement, and the actual reduced rounded ledger. Only then try a freshly admitted more balanced ownership, such as24/104, with the same unmodified floors. No automatic fit claim follows from the logical reduction. Larger C64/C128 full-model work remains separate: final-layer narrowing/route shape, peak temporaries, host/wire bounds and exact numerical comparison must all be extended together.
