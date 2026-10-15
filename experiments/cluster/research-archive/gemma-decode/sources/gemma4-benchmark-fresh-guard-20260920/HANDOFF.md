# Invocation-local fresh guard observation

This is a separate unexecuted overlay on frozen guard instrumentation `84352102855784c7137546371eda5c77be427dee881a5f407d7b3c0cdf3d549c`. The instrumentation must be independently qualified first. No compiler, Foundation fixture, native/GPU, model, remote, or MAIN operation was performed. Four overrides and two additions are listed with exact preimages in `source-inputs.json`; do not apply them against the earlier uninstrumented native source.

The change shares one fresh environment/OS observation within a **single existing logical guard invocation**. It does not lower any memory floor, change a budget formula, pace checks, retain a timed cache, or remove call sites. The original entry → owner → entry sequence and eight outer native-fault checks remain. Direct entry and resource-owner checks still run at all of their existing construction/loading/probe/request/retirement boundaries and now use independent one-use observations.

## Actual lifetime and source boundary

`Runtime.checked` creates a private observation holder, calls the original two outer guards around the original owner guard, finishes the scope, and closes it in `defer`. There is no model, transport, native evaluation, async boundary, or unrelated call in that scope. The object is never a property of the model, wire, session, resource owner, or timer. The entry and owner receive it only as a synchronous parameter. A standalone check creates and closes its own one-use holder.

The holder accepts no supplied OS observation or reader callback. Its only first-read path is the existing `QwenResidentResourceEnvironment.observe`, which performs the same live AC, low-power, thermal, and initial actual-free/pressure/swap checks. Existing `require` callers still perform the same one fresh observation and discard it. The holder returns that same immutable observation on the remaining two guard uses. Every use revalidates the existing `QwenDenseStageLoadPolicy.requireInitial`, exact expected deadline, current monotonic time, and scope order. Entry/owner retain their separate exact pressure-level-1 checks; owner retains its one fresh allocator sample and every reserve inequality.

The pure invocation contract requires entry → owner → entry, or exactly one standalone entry/owner. Its deadline is immutable. A snapshot must have started after this scope was created. It cannot be from a previous invocation, future time, reversed interval, expired lifetime, or stale observation. Both scope age and observation age use the unchanged policy's 1,000,000,000 ns maximum; the scope never refreshes or retries after exceeding it. Success requires the complete ordered consumer sequence and a final age/deadline check. Read/validation failures poison and clear the holder, and close/deinit clears it again. Reuse after closure fails before any observation is accepted.

This deliberately selects one observation instant instead of six close successive instants. It does not claim that OS values are identical throughout a guard or that sampled floors prove a whole-process peak bound. The important boundary is that no observation crosses model/transport work or another logical check. The external parent continues its independent live samples and absolute process fence unchanged.

## Thrown paths and authority

- Pending native faults are checked at the same original positions before entering the environment/owner work and after it. The holder is constructed without throwing before those checks; it performs no read until the original entry guard reaches its environment point.
- A power/OS reader failure closes the holder and rethrows that original error. There is no fallback observation, stale-value acceptance, retry, or successful return. The existing outer native-error/cleanup paths remain authoritative.
- Phase, loading-progress, allocator, and budget failures remain inside the original owner catch, which marks the owner failed and poisons progress. The entire budget calculation, inequalities, observations, and final owner deadline check are byte-exact; source controls compare this block directly.
- The last outer native-fault checks still run before successful scope completion. A new final age/deadline refusal can fail a guard that took too long; it cannot turn an old refusal into success. Closing during unwinding does not throw or replace the primary error.

All constructor/load/request/retirement methods after `construction` in the owner are byte-exact. Collective/state/forward code, checksums, ACKs, wire bounds, native completion fences, numerical arithmetic, jobs, and supervisors are not overridden. Existing 6/4/2 GiB constants and every selected/unread/host/copy/scratch/state/workspace term remain unchanged. The existing instrumentation's 32 KiB host allowance covers the fixed holder, one scalar OS value and its bounded ISO timestamp, and temporary copies. The new Foundation control checks worst-case metric encoding/storage plus 2 KiB and the actual invocation value size against that existing allowance; no budget reduction is applied.

## Qualification

`Tests/check_source.py` verifies exact ancestry/pins, the unchanged owner budget/phase bodies, unchanged native-fault/eval/sync counts, the ordered model-free scope, the sole real reader, and the environment-reader inverse. It launches no probes or fixtures.

Nine staged Foundation groups cover ordered use, standalone scopes, skipped/duplicate/extra consumers, partial/unwound scopes, original deadline binding, stale/future/cross-invocation snapshots, invalid configuration and overflow-safe bounds, final expiry, and the existing host allowance. They test the real pure invocation contract, not fabricated resource grants. They do not execute the actual IOPower/Mach reader or prove native callback attachment; that remains a source and native qualification requirement.

Root's owned CPU runner can use these exact inputs, in a fresh `Build` directory:

```sh
python3 -B Tests/check_source.py
xcrun swiftc -swift-version 6 -warnings-as-errors -j 2 \
  /Users/developer/DarkbloomDev/cluster-research/gemma4-benchmark-guard-metrics-20260920/Runtime/Gemma4BenchmarkGuardMetrics.swift \
  Runtime/Gemma4BenchmarkGuardInvocation.swift Tests/GuardInvocationChecks.swift \
  -o Build/GuardInvocationChecks
Build/GuardInvocationChecks
```

Apply the six entries only after their preimages match the already-applied metrics source, then incrementally build the existing `GemmaResidentBenchmark` target. No Package change or alternate owner is required. Late-bind its actual native and description in fresh physical jobs. Preserve all old binaries/results. First run the same P128/C64/cut8/O16 solo, serial pair, and lookahead pair with complete final-row/state capture and the existing physical comparator. Require the new `guardObservationPolicy` marker, successful original cleanup and OS guards, identical IDs/rows/states, and valid metrics with no overflow. In timed request intervals, successful logical guards should now have one OS snapshot each, two entry guards, one owner guard, three environment-validation scopes, one allocator observation, and eight outer native-fault checks. Wire send/receive counts must be unchanged. Only measured actual results can establish the timing effect; nothing here qualifies throughput or long prompts.
