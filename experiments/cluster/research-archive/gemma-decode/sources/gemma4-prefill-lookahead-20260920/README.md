# Gemma bounded prefill lookahead candidate

Source only. Seven benchmark replacements and two additions build in the existing `GemmaResidentBenchmark` target. No Package, vendor, ordinary owner, Gemma model/attention/expert math, state, decode, lease, deadline, alias, or installed serving changes. `originals/` retains the exact preimages. Input and Budget include the reviewed cut-admission successor (cuts6/7/8/10, chunks64/128). `integration.json` binds these files and the unchanged common Qwen primitives. This draft has not been compiled or executed by its author; Python source syntax parsing is the only performed check.

`prefillPolicy` is an optional job string. Omission preserves the old serial scope, reserve and wire operation order. Explicit `serial` or `oneChunkLookahead` is included in the bilateral scope. Full reference accepts only serial. Both stages must use the same policy; the receiver uses its existing sequential request/state/transport path. These are private benchmark modes, with no new public capability.

The producer reuses `QwenGenerationPrefillWindow` and `QwenGenerationPrefillAllowance`. Its sequence is prepare k → completed native send k → release original and transport boundary wrappers → prepare at most k+1 → consume k's exact CPU ticket and captured frontier. It never starts a second send while a consumed ACK is pending. Local state advances through the same synchronous `Gemma4OwnedForwardSession` calls and transaction/evaluation path. No evaluation, synchronization, forward or background operation is added. Every failure poisons the existing wire and cancels the prepared slot; original outer MLX error precedence, absolute lifetime and owner cleanup remain authoritative. Decode and request retirement require a drained window.

An F32-ceiling boundary adds `chunkSize * 2816 * 4` logical native bytes on rank0 only when another prompt chunk exists, independently rounded by the actual allocator. A new named term plus the same logical host bytes and65,536 bytes of bounded bookkeeping are added to the existing reserve. Rank1 reserves65,536 host bytes; a single-chunk producer also reserves only bookkeeping. C64 has720,896 extra logical native +786,432 host bytes; C128 has1,441,792 +1,507,328. All original selected weights, casts, snapshots, state, workspace and boundary terms remain. The existing live owner reads these enlarged totals at its load/request/retirement checks. This is a named operational allowance, not a whole-process peak proof or fit claim. The6/4/2GiB floors, zero swap, AC, pressure1 and zero freed-buffer cache remain unchanged.

Rank0 prefill frame intervals intentionally overlap: the next frame's actual preparation begins and commits before the preceding frame's consumed-ACK completion. Local owner phase intervals remain sequential. Each recorded phase retains its actual local timestamp and captured frame frontier. Token agreements and request timing retain the original clock and arithmetic. `durationIncludesResourceChecksAndSerialTransport` is false for the explicit lookahead policy; checks and bounded P2P operations are still included. No clocks from different processes or hosts are subtracted. Existing P128/C128 measured owner spans (about77ms rank0 and180ms rank1) expose imbalance, but time outside these spans includes checks/waits/transport and is not a measured Thunderbolt cost.

## Root-owned qualification commands

First check every preimage/absence in `integration.json`, preserve the current native artifact, then apply the nine Runtime files only to the disposable root workspace:

```
/Users/developer/DarkbloomDev/cluster-research/gemma4-execution-20260920/build/workspace
```

No automatic apply/build runner is introduced. Root can use the existing bounded compiler wrapper and its actual source receipt. Its exact product command is:

```sh
/usr/bin/swift build --package-path "$work/libs/darkbloom-cluster-worker" \
  --scratch-path "$work/libs/darkbloom-cluster-worker/.build-native-worker" \
  -c release --jobs 2 --disable-automatic-resolution --skip-update \
  --disable-build-manifest-caching --triple arm64-apple-macosx26.2 \
  -Xcc -target -Xcc arm64-apple-macosx26.2 --product GemmaResidentBenchmark
```

Here `$work` is the exact disposable workspace above, not MAIN. Root must keep fresh regular stdout/stderr logs and the existing owned bounded compiler process. The Foundation-only control executable needs these four unchanged runtime files plus the staged test; it does not import MLX or mock any native API:

```sh
/usr/bin/swiftc -swift-version 6 -warnings-as-errors -O -j 2 \
  "$runtime/ClusterRuntimeError.swift" "$runtime/QwenLongPrefillTensorBudget.swift" \
  "$runtime/QwenGenerationPrefillPolicy.swift" "$runtime/QwenGenerationPrefillAllowance.swift" \
  "$draft/Tests/LookaheadControls.swift" -o "$fresh/LookaheadControls"
"$fresh/LookaheadControls"
python3 -B -m unittest discover -s "$draft/Tests" -p 'test_overlap_clocks.py' -v
```

`$runtime` is `$work/libs/darkbloom-cluster/Sources/DarkbloomClusterRuntime`; `$draft` is this directory; `$fresh` must be a new root-owned output directory. Expected controls:14 Foundation groups and10 Python methods. They are staged, unexecuted. Foundation checks exercise real single-slot transitions, stale captured frontiers, unsent credit, duplicate consumption/cancel and actual allowance arithmetic. Python controls exercise permitted/forbidden local interval overlap, a second prepared chunk, decode drain, summary refusal and additional native/host charging.

After actual native build, late-bind its SHA into a concrete valid job. `Tests/make_policy_jobs.py JOB FRESH_DIRECTORY` prepares seven pure argument cases (five accept/two refuse). Run each through the actual product's `--check-arguments` and `--describe` entry; full lookahead and unknown policy must refuse. Verify no group/model/sidecar is created. Compare serial/lookahead target descriptions to the exact added reserves above. No guessed native SHA appears in this draft.

For hardware, reuse root's existing `run_case.py`, package, cancellation, canonical inherited lease and315s parent/300s native fence. Fresh jobs/run paths are mandatory. First candidate is P128/C64/O16 with capture enabled and one admitted existing cut; P256/C128 has the same two-chunk opportunity but needs separate actual admission. P128/C128 is a single-chunk negative speedup control, not a useful overlap benchmark. Larger shapes remain individually gated. All three modes/policies must use identical prompt bytes, chunk, cut, dtype, epoch, four request IDs, output count, native build and capture setting; only mode/output path/policy may differ.

Keep one matched solo/full plus serial stage0/stage1 in `SERIAL_CASE`, and lookahead stage0/stage1 in a distinct `LOOKAHEAD_CASE`. Set explicit `serial` on all three serial jobs, `oneChunkLookahead` on both lookahead jobs. Once all five processes have retired:

```sh
python3 -B "$draft/compare_results_overlap.py" SERIAL_CASE LOOKAHEAD_CASE
```

The comparator is a small policy-aware derivative of the qualified retained-evidence v2 helper. It retains exact launch/job/SSH/terminal/native-stdout joins, process/lease/alias release, strict stage-specific stderr, raw OS resource replay, complete cohorts and same-process timing math. It adds actual reservation deltas and single-slot phase-order checks, compares all generated IDs and each request's complete final row plus union of90 state components against the solo source, and refuses capture=false. It writes create-only `comparison-overlap.json`; older comparisons/evidence are unchanged. Five roles total one warmup plus three measured requests each. Timings remain capture-cohort observations, not model-only throughput, representative workload results or encrypted RDMA qualification. Current transport is checksummed plaintext JACCL/RDMA.

Transport's separate suffix-maximum loading-staging proposal touches this same Owner's existing live-read calculation. It is deliberately not silently folded into this freeze: root must verify and compose that exact reviewed delta separately. The lookahead changes to Owner are limited to initializer forwarding and the optional allowance receipt. No floor or load-staging discount is introduced here.
