# Exact registered selected-stage materialization

Outtree implementation proposal, 2026-09-14. Source review/checks only by the
author; no Swift compilation, model payload read, candidate inspection, native
process or SSH. Root owns integration, compiler, external guard and all native
qualification. The standalone fixture is prospective: 21 accepted/122 rejected.

```text
cluster-inference --mode qwen-dense-stage-load-check \
  --model-dir <absolute registered directory> \
  --registered-dense-profile registered_qwen38_27b \
  --stage-index 0 --timeout-seconds 300
```

The other exact profile is `registered_qwen35_9b`; the other stage index is `1`.
All five pairs are mandatory once, in any order. Stage is canonical 0/1; timeout
is canonical 1...300. No prompt, cut, tracing, transport, repeat, resource ceiling
or reserve override is accepted. Each process owns exactly one selected half:
9B 16/16 or 27B 32/32. Run each half in a separate guarded process. No full model
weight load, forward, state or multi-request permission is added.

## Integration and reuse

`runtime.patch` adds seven small runtime files and replaces only Main plus
VerifiedQwenLayerStageLoading. Main has one early dispatch before ordinary
Options. Existing constructor/readiness dispatch and all 41 adapter calls are
unchanged. Tests are separately supplied under `fixtures/`; they are not native
target sources. `fixture-source-list.json` pins 30 exact pure inputs and the
existing shared retained metadata; it includes the current root `VerifiedCheckpoint`
digest-only no-cache change, SHA `0e3b070d7ed7a7b6d112c786a32456da676057782e1de6240b9c2f894f65936a`.
This proposal does not edit VerifiedCheckpoint or its checksum policy.

The new entry reuses closed constructor metadata admission, one full verified
checkpoint owner and the actual constructor-source builder. The complete source
and both compact inventories use the existing `.sequentialPair` metadata read
plan. A separately rebuilt `.stage0`/`.stage1` requirement binds the selected
budget. Both identities, exact default Plan, actual inventory and allocator bounds
must agree. The pair metadata is not re-labelled or promoted to a loading permit.

The non-owning compact model is inspected and released first; the selected
compact model is constructed once, then loaded. Both run in scoped random state.
The only returned native-owner result is CPU load/resource/memory metadata after
the selected model leaves scope. Full and other metadata models retain their
existing weak retirement checks. A helper failure before it returns still relies
on that helper's local unwind; no claim covers every possible native alias.

The common loader tail is extracted once. Apart from dedenting, its three
`error.check` calls become the provided check and one optional pre-read callback
is inserted. Every read/sanitize/cast/eval/sync/buffer-ownership/update/freeze/
layout/receipt operation and error string remains in order. The legacy wrapper
passes no pre-read callback, samples no new clock/resources, and retains its
existing 6 GiB canonical, 512 MiB host and 8 GiB manifest limits. The optional
callback borrows the nonescaping outer check through `withoutActuallyEscaping`
for the synchronous helper invocation; no callback is stored or exposed.

## Actual resource gate

Only the file-private live gate can authorize its ordered tensor callbacks. A
pure budget or a successful evaluation of synthetic resource records is never
a permit. The gate is constructed once inside the sole selected model's lexical
scope and finishes only after the actual common loop returns with all entries
consumed. Any error poisons it. No failed load can resume or publish success.

Before hashing or native setup, direct Darwin observations enforce the standing
6 GiB actual-free minimum, pressure 0...2 and absolute zero reported swap. The
post-hash/post-constructor gate independently samples again immediately before
the first payload read. Kernel `free_count` includes speculative pages; the
sampler subtracts speculative for actual free and retains raw and adjusted counts.
The SDK declaration is pinned. Host rights are released; failed sysctls, invalid
sizes, inconsistent page arithmetic, backwards/stale observations or missing
data reject. Reclaimable bytes and device recommended working set are diagnostic
only and cannot authorize allocation.

For ordinal `n`, let `R` be the current allocator's bound for all not-yet-read
active tensors plus the small inert allowance, and `H` the selected largest host
tensor (zero once the final tensor was permitted). Require actual free bytes:

```text
max(6 GiB, R + 2*H + 4 GiB)
```

Also require the unchanged allocator limit to cover its observed active/cache
bytes plus `R + H + 2 GiB`, and require every prospective individual buffer bound
to fit the observed device maximum. Bounds come from actual
`Memory.allocationFootprintUpperBound`; no conditional page-size constant is
substituted. The 4/2 GiB and extra host allowance are explicit operational
headroom, not measured scratch or a whole-process safety proof. Allocation/cache
limits are never raised or silently tuned. Partial progress removes only the
already permitted allocation terms; its actual allocations remain observed.

Pressure/swap/actual-free/deadline checks repeat before each tensor and at the
existing settled check positions. At most 4,096 decisions are retained. The
largest selected inventory is 924 entries, so the bounded normal path fits.
The independent parent must still observe resources, fence native timeouts,
retain binary/bundle/source/input evidence and verify process reaping. A native
sample cannot reserve memory against other system activity.

## Output and checks

Success emits one bounded `qwen_dense_stage_load_report` JSONL record (schema 1,
under 8 MiB). It embeds the existing complete load receipt, selected metadata
budget, actual OS/MLX decisions, before/loaded/released MLX observations, and
runtime device/executable/main-bundle observations. Native does not claim to hash
or independently verify its executable or bundle; parent evidence supplies that
binding. Weak model/file release, cleanup synchronization, native error checks,
cache clear, the final 6 GiB/zero-swap screen and deadline gate publication.
Native errors take precedence over a secondary Swift error, with cleanup errors
retained alongside the primary failure.

Source checks passed: exact old prefix/assembly/tail comparisons, isolated Main
dispatch, 59 dependency/retained-metadata pin reads, and ten rejected source
mutations. These are source checks, not compilation or execution of the gate.

The 30-source Foundation fixture reuses public observed-stage fixture builders
and actual production profile, Plan, source/stage, budget and policy validators.
It checks exact roles, coherently rebuilt invalid ownership/dtype/default-Plan
cases, arithmetic boundaries, the absolute 6 GiB floor despite abundant
reclaimable bytes, pressure/swap, stale/inconsistent observations, overflow and
ordered ordinals. Its fake read counter increments only after a pure predicate
returns. It does **not** independently exercise production read ordering, the
private live gate, a partial native materialization or its cleanup. Root's first
native 9B control and separate 27B stage loads must provide that next evidence;
existing tiny/short load fixtures remain the legacy regression route.

No success here establishes tensor-value parity, 8K fit, forward/provider/M3
arithmetic eligibility, physical transfer, resident reuse, or throughput.
