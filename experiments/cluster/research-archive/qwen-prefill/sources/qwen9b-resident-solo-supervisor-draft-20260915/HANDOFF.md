# Resident solo9B parent

This is a new private derivative of the aligned full-reference supervisor. It
owns one native process on the48GB Mac for a single verified model load, one
warmup and three measured P8192/C512/O128 requests. No remote or model execution
was performed while preparing this package. MAIN and installed defaults remain
unchanged. Root owns review, deployment, resource admission and the physical run.

Native8952b0f260502b06f7dbe7eb9e0cbef1b41564001570ad52a3c2739a247252d3
compiled first attempt in231.237seconds. Its actual model-free mode passed15
accepted and24 rejected cases in1.086seconds with empty stderr. All3290 source
and9502 dependency files stayed unchanged. The build includes actual native
GDN/fused-projection observation only for warmup; no kernel/model mode has run.

The bundle is `qwen9b-resident-solo-generation-build-20260915/bundle`, three
files plus bundle.json. Bundle SHA:
`71617e2747ea993ad9012966997a7676442b9f0229c52989a2cebe2a21906cb7`.
Build manifest SHA:
`796b0d89409e63445dc4baec18bc0e3baa989f82b1fe516f1a8fe79f33e4ceb9`.
The native minimum macOS is26.2. The source-matched metallib/paged source remain
2129f613…bdd2 and4ad3ff17…9149. No external non-system dylib is needed.

## Exact reused behavior

`worker_processes.py`, `worker_contract.py`, the resource gate, strict JSON/file
helpers and existing profile/request fingerprint routines are copied byte-exact.
`lineage.json` binds13 retained helper files. `runtime.patch` shows the two
adaptations: bound solo argv/expected-ID input and two-record solo result wiring
around the original `serve` cleanup structure. `solo_contract.py` admits the
new CPU-only result schema; it is not another model implementation or oracle.

The process gets its300-second native alarm, with the same315-second parent
deadline and bounded stream/process-group cleanup. Resource sampling retains
the unchanged six-GiB actual-free, zero-swap, AC and pressure rules. Native code
acquires the canonical device gate itself; the parent must not hold that lock
while launching. Source/input snapshots are rechecked after actual process
cleanup. The parent does not equate a response record with exit or EOF.

The validator binds all four fresh request IDs/fingerprints, the original pinned
prompt and128 expected tokens, Plan/arithmetic/source identity, warm1/measure3,
all143 forwards/frontier8319, four actual reported retirements and model release.
It requires warmup native GDN counts384/3048,24 fused modules and no fallback,
and refuses claimed measurement instrumentation, full-row/state capture or MTP.
It independently recomputes every timing interval,8192-prefill and127-decode
rate, timestamp order and non-overlap. Timestamps are compared only within the
native process clock, never to the Python parent clock.

`throughputMeasurementValid=false` and independent numerical flags remain
conservative inherited qualification fields. A completed parent means the
strict timing/token/cleanup contract passed; root still reviews raw durations
and samples before publishing a comparison. This does not independently prove
unrecorded full BF16 rows/state or globally optimal solo policy. The solo clock
includes fresh state, finite argmax and actual per-forward validation, while
the cluster controller clock also includes transport/recording overhead.

## Local checks

Ten methods passed with five actual Python children in1.257seconds. They cover
strict argv/identities/geometry, warmup branch requirements,128-token/frontier
guards, timing/rate/order rejection, actual two records+EOF, missing/extra output,
nonzero exit, and a stalled child fenced under the inherited timeout.
`cpu-check-1` preserves the first fixture refusal: a0.25-second float was rejected
by the unchanged integer1...315 constructor before a stalled child launched.
The fixture was corrected to1second; no runtime guard changed. That first
receipt's predeclared five-child count is explicitly corrected to four in its
qualification-correction.json. All five children ran in the final passing check.

## Root deployment and run

On the48GB Mac, use a fresh root:
`/Users/developer/DarkbloomDev/qwen9b-resident-solo-generation-20260915`.
Copy the complete bundle into `native/`, this package into `supervisor/`, and
the two pinned input files into `inputs/`. Keep directories private and verify
all manifest members; no configuration switch, SSH owner launch, network alias
or model copy is required. `job.json` binds the actual existing model at
`/Users/developer/DarkbloomDev/models/Qwen3.5-9B`, cut4 reference identity, native and
input pins. Root must create only the empty `runs/` parent; `cohort-1` must not
exist. All previous physical evidence remains separate.

The intended host is developer@192.0.2.223 using the existing reviewed development
key and known_hosts. Root must observe no competing owner/native process and
an available empty canonical device gate, then verify current resource state.
Do not clear an unknown journal or override a resource refusal. Do not run this
alongside a compiler, transfer or another physical timing test.

After the complete deployment is verified, run on48 with the job/launcher hashes
from the final manifest and deployment.json:

```sh
/usr/bin/python3 -B /Users/developer/DarkbloomDev/qwen9b-resident-solo-generation-20260915/supervisor/run_solo.py \
  --job /Users/developer/DarkbloomDev/qwen9b-resident-solo-generation-20260915/supervisor/job.json \
  --job-sha256 JOB_SHA256 --launcher-sha256 LAUNCHER_MANIFEST_SHA256
```

Retain `terminal.json`, `owner.json`, all `resources.jsonl`, and native stdout/
stderr with exact EOF/exit status. Root must recheck actual process absence and
canonical empty gate after the run. On failure, retain all partial evidence and
nonzero status; the parent owns its child group cleanup. It does not prove
independent reaping of arbitrary descendants or constitute an administrative
recovery tool. Report all three measured durations and median, excluding warmup.
The older441.68-TPS output-one result remains a different workload.

Independent source review is pending. The package is runnable after root review
and deployment checks; actual optimized-path warmup and performance are pending.
