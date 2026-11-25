# Matched resident solo9B generation source candidate

This private candidate implements one verified full-model load, one excluded
warmup and three measured requests at P8192/C512/O128. Every request has fresh
CBv2 KV/recurrent state and must select all128 pinned target IDs. BF16, greedy
selection, empty stops, MTP off, prefix reuse off and the required arithmetic
environment match the balanced cut4/cut16 cohort. No compiler, model, remote
operation, MAIN edit or installed-default change has been performed.

`integration.json` maps12 files onto an owned copy of the current registered
full-reference workspace. The only pre-existing files changed are its private
Main, Package and the dependency's GatedDelta dispatch branch. The original
loader, source admission, memory ledger, CBv2 session, completion/retirement and
native argmax remain exact. `runtime.patch` is the complete source delta.
`base-source-snapshot.json` binds all3281 baseline source files; the build base
is registered-reference source snapshot3 and its aligned-payload loader.

## Request and ownership path

`QwenResidentSoloCLI` delegates registered metadata/Plan/request admission to the
existing full-reference CLI. It admits the pinned prompt and expected target
file, constructs four distinct request IDs, and refuses changes to model,
geometry, stops, source, arithmetic or resource shape. The old full-model
reference's cut4 Plan is only an identity/accounting decomposition; this owner
loads and forwards all32 layers without distributed execution.

The entry acquires the exact shared `ClusterDeviceExclusion` at the system
user's canonical `.darkbloom/cluster-device` path before native initialization.
The gate source is byte-exact MAIN and compiled as a tiny local Foundation
target. The process retains the empty exclusive file descriptor until exit,
including failure. It cannot clear a nonempty owner journal and creates no
second filesystem lock implementation.

The existing registered full loader verifies all927 tensors, materializes the
same BF16 target, and runs its actual allocation/resource checks. The existing
resident lifecycle owns exactly four request scopes and one final model release.
Each request uses the production `CBv2RequestSession`,16 prefill chunks and127
decode forwards. It reuses the finite native argmax helper but never requests a
full vocabulary CPU row or a state snapshot. Every selected token is compared
with the pinned128-ID sequence before its timestamp is retained.

The request finishes through the existing typed completion and `finishGeneration`.
Failure calls the existing `cancel` independently of expired cooperative checks;
the cohort then releases the actual model and verifies its weak reference. A
blocked native call/destructor remains bounded by the process alarm and must be
fenced/reaped by the later physical parent. No CPU lifecycle flag is treated as
standalone native cleanup proof.

## Optimized path evidence

The full model uses the current Qwen35 fused quantized GDN input projections,
native GDN kernel and CBv2 attention implementation. The warmup observer records
which `gatedDeltaUpdate` branch actually runs, its B1/K16/V32/dim128/BF16/FP32
geometry and T512 or T1. It retains no arrays. Successful warmup requires384
native prefill calls,3048 native decode calls, zero operation fallbacks, zero
geometry mismatches and24 actual modules with cached fused input projections.
The complete warmup must also pass the128-ID and native retirement checks.

The observer is removed before the first measured request. With it nil, the
shared branch adds one optional check and performs no counter work, locks,
array copies or profiling. This private source delta must not be promoted as a
general concurrent production observer. The query-block policy must be128 and
is recorded as configured; its dispatch is not independently counted.

`kernel-source-lineage.json` records the three dependency source hashes. The old
lookahead workspace points through a mutable MAIN symlink, so its current byte
equality is **not** claimed as historical009a dependency attestation. This new
build pins its actual dependency closure and qualifies its own warmup path.
No claim of globally best possible solo performance is made from source alone.

## Timing, memory and limits

Request start is sampled after source/arithmetic/resource admission and before
fresh CBv2 state construction. First-token time is after committed state, native
finite argmax and the first expected-ID check. Decode time spans the first to
the128th such token, so its numerator is127. Timing includes existing per-forward
ownership validation and live resource checks. It excludes model loading,
transport, source admission, full-row capture and state capture. These are
same-process DispatchTime values, not HTTP/external receipt measurements.
The cluster controller clock includes transport and its matched recording path;
that boundary difference must be retained in any comparison report.

The unchanged full-reference resource ledger is admitted once for the identical
four-request serial cohort. All four requests must have the same named resource
shape and each repeats actual live checks before fresh allocation. The ledger
continues conservatively reserving its unused diagnostic row allowance, which
also exceeds the bounded CPU token/timestamp/report storage. No allowances or
six-GiB floor are reduced. Freed-buffer cache is disabled before loading. All
four admissions are counted; this standalone benchmark is neither a billed
user session nor an extra uncounted provider admission.

One fixed maximum300-second alarm includes metadata, loading, all requests,
teardown and output. Each request additionally clamps to120 seconds and the
remaining process lifetime. No renewal occurs. Output is two bounded JSONL
records, admitted then completed report, at most128KiB each. Expiry/failure
leaves a nonzero process result; partial output is not a completed cohort.

## Build and checks

Only lightweight source/input checks have run. The Swift fixture is staged but
uncompiled: it checks strict14-pair admission, fresh UUIDs, exact geometry,
expected-ID bounds/hash/JSON failures, arithmetic-before-read, timing order and
127-token decode denominator, counted warmup and poisoned-cohort cleanup. These
CPU checks do not prove actual native retirement or kernel dispatch.

After root accepts the source and grants the exclusive compiler slot:

```sh
cd /Users/developer/DarkbloomDev/cluster-research/qwen9b-resident-solo-generation-draft-20260915
/usr/bin/python3 -B prepare_build.py --prepare
/usr/bin/python3 -B build_check.py --phase build --attempt 1
/usr/bin/python3 -B build_check.py --phase check --attempt 1
```

Preparation verifies the complete baseline and overlay, makes a new APFS clone,
rebases only clone-owned links/cache metadata and refuses external source links.
It never overwrites a prior build. The build uses SwiftPM jobs2, macOS26.2, no
dependency resolution/update and disabled manifest caching. The runner records
the child PID,900-second build/60-second CPU limits, stdout/stderr and unchanged
source/dependency pins. Failed attempts must remain; any corrections get their
own patch and source snapshot before another build.

The new binary must be packaged with the source-matched `mlx.metallib` and
`mlx-swift-lm_MLXLMCommon.bundle/pagedattention.metal` from the existing reference
bundle, verifying their pins and the new executable's LC_BUILD_VERSION26.2.
Metal source is unchanged. Root must verify the new complete bundle and live
resource/process/gate state before any actual run. No binary pin exists yet.

## Physical follow-up, still unqualified

`inputs/request.json` binds the same raw prompt
`ee6caf0be6391e00ec41df930f0fd6351613969622cbb247b1b4bdaf69afe997`
and the existing prospective128-ID sequence from the cut4 timing configuration.
No newly measured candidate output was used to generate expected values.
Use one dedicated48GB Mac process and a fresh output directory. The later
supervisor must retain actual samples, enforce the fixed parent/process bounds,
reap the process, observe the canonical gate and preserve exact EOF/exit status.
No network/bootstrap or IPv4 alias is needed for the solo forward.

The exact native argv is the12 existing registered-reference pairs with mode
`qwen-resident-solo-generation`, plus `--expected-token-ids-file` and
`--expected-token-ids-sha256`. Set registered profile9B, cut4,8192/512/128, empty
stops, timeout300, pinned prompt/expected files, and the packet's first UUID.
Use the unchanged arithmetic environment from the balanced cohort. The next
three fresh UUIDs are generated once during preflight and published before
model loading. Do not count warmup; report all three measured durations and
their median, the128-ID guards, actual dispatch evidence, resource samples and
cleanup. The earlier441.68-TPS O1 baseline remains a different workload.

Root source review and independent source review are pending at this handoff.
Actual compilation, warmup dispatch, full cohort correctness and performance
remain required before calling this an optimized matched solo result.
