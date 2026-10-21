# Checkpoint Storage Comparison

> Last updated: 2026-10-11

Offline, sequential process runner for `ModelCheckpointStorageLiveTests`. This
folder contains tooling, not measured results. A parent/operator owns all builds,
signing and exclusive GPU scheduling. Python uses only the standard library.

## Input And Commands

Prepare an existing local model and a prebuilt test executable. The base JSON is
the standalone `ModelPrefixBenchmarkSpecification`, not the enclosing run spec.
For example, replace the local path, model identifiers/type and verified hash:

```json
{
  "modelID": "<catalog-model-id>",
  "openRouterID": "<public-model-id>",
  "directory": "/absolute/local/model",
  "expectedWeightHash": "<verified-local-weight-hash>",
  "modelType": "<config.json-model_type>",
  "outputPath": "/unused-overwritten-by-runner.json",
  "pairs": 3,
  "outputTokens": 128,
  "pairOffset": 0,
  "warmupIterations": 1,
  "captureTokenDiagnostics": false,
  "kvBackend": "auto",
  "cases": [
    {"name": "shared-4k", "donorTokens": 6144, "sharedTokens": 4096,
     "forkTokens": 6144, "demandedTokens": 4096}
  ]
}
```

From this folder, inspect the plan before authorizing a model run:

```sh
python3 -B checkpoint_storage.py --spec /absolute/base.json \
  --output-dir /absolute/existing-parent/new-run --dry-run
python3 -B checkpoint_storage.py --spec /absolute/base.json \
  --output-dir /absolute/existing-parent/new-run
```

The output directory must be new; no existing run is overwritten. `--dry-run`
only prints the planned command arrays, paths and run JSON, with no writes or
process launches. Default command, with no shell:

```sh
swift test --package-path <root>/provider-swift --skip-build \
  --disable-automatic-resolution --filter ModelCheckpointStorageLiveTests
```

`--root` defaults to this folder's repository root. The runner never builds,
downloads models or resolves packages itself. The operator must ensure a custom
launcher also stays offline and does not build. Default profiles, in order:

- `native-live_native-checkpoint`
- `native-live_balanced-checkpoint`
- Optional `--include-balanced-live`: `balanced-live_balanced-checkpoint`, the old live/storage pairing.

Only requested live/storage precision and output paths are replaced in each copy
of the base. `--pairs` and `--warmup-iterations` optionally replace those counters;
otherwise input values/defaults apply. Diagnostics must be false. `pairOffset +
pairs <= 5`; output budget is 32...512 tokens. `kvBackend` is unchanged. Repeat
with separate bases using `"contiguous"` and `"paged"` to qualify both storage
codecs on supported models; `"auto"` qualifies only the reported actual backend.
Unsupported profiles, including unsupported MiMo arms, are not fallback passes.

Use a fresh output directory and `--reverse-profile-order` for a counterbalanced
rerun. Profile order is recorded. Fixed sequential order may bias results through
OS/file caches and thermal state; reversing order does not remove all noise.

## Restart And Isolation

Without `--persistent-access-group`, each profile runs only `phase=benchmark`.
Swift owns a unique ephemeral cache root and deletes it. This is **not evidence
of cross-process persistence**, even though profiles use different processes.

Persistent mode requires a real signed launcher with the specified keychain
access-group entitlement and Secure Enclave support. There is no fallback to
provider/default keys. For a parent-provided signed test launcher:

```sh
python3 -B checkpoint_storage.py --spec /absolute/base.json \
  --output-dir /absolute/existing-parent/new-persistent-run \
  --persistent-access-group TEAMID.isolated-test-group \
  --test-command-json '["/absolute/signed-test-launcher","--parent-owned-argument"]' \
  --exercise-read-refusal
```

Each profile receives its own freshly created `checkpoint-cache` root and UUID
key namespace. A shared run UUID ties its `donate` and separate-process `restore`
reports together. Optional refusal adds `refuse`, then `restore_after_refusal`
(wire phase `restore`); both reference the original donor report. Swift caps the
refusal SSD stage budget at 1 MiB and requires **every** producer encrypted
artifact to exceed 2 MiB, otherwise the control fails to exercise the refusal.
A failed/incomplete donor skips dependent phases; other profiles still run.
Persistent roots and keys are retained even after errors. Later cleanup belongs
to a human/signed harness scoped to the recorded root and UUID namespace. There
is deliberately no global keychain cleanup command. MiMo persistent phases are
currently unsupported by this Swift suite.

Child environments inherit only `HOME`, `PATH`, `TMPDIR`, locale variables, `TZ`
and `__CF_USER_TEXT_ENCODING`. They explicitly set
`DARKBLOOM_CHECKPOINT_STORAGE_BENCHMARK=1`,
`DARKBLOOM_PREFIX_EXCLUSIVE_GPU=1`, and
`DARKBLOOM_CHECKPOINT_STORAGE_SPEC=<absolute-run-JSON-path>`. No implicit
`DARKBLOOM_*`, `MLX_*`, `SWIFT_*`, developer or dynamic-library overrides survive.
Custom launchers may need explicit repeated `--framework-path` / `--library-path`
options for `DYLD_FRAMEWORK_PATH` / `DYLD_LIBRARY_PATH`; neither is inherited.

## Reading Results

`plan.json` records process order/argv/specs. Each process has separate
`*.stdout.log`, `*.stderr.log`, `*-spec.json` and Swift `*-report.json` files.
`summary.json` retains full reports only for successful processes with validated,
complete reports. Failed, absent, invalid and skipped attempts remain explicit;
a zero exit alone is not success. Any unsuccessful attempt makes the runner exit
nonzero. Swift reports are preserved untouched, including partial failure files.
Acceptance requires exact cell/pair/role coverage, fixed output counts, drained
retirement, real SSD reads/live backend memory, and one completed post-output cancellation
witness per cell/pair (none for refusal). Persistent phases additionally require
authenticated artifacts with positive encoded/encrypted bytes and the actual
reported layout. A `complete=true` flag or iteration counter alone is insufficient.
Cancellation witnesses also require zero actual file/byte write deltas; staged
prefill copies cannot be reported as a published checkpoint after cancellation.

Every new report must carry `donationControlVersion: 1`. `donationControls`
contains exactly one witness for each cell/pair in `benchmark` and `donate`, and
is an empty array for `restore` and `refuse`. Referenced donor reports must satisfy
the same versioned evidence contract. The run specification does not need a
version field. Missing/version-zero reports are rejected, even when marked
`complete`; the summary also excludes them from metrics and paired comparisons.

Each cell/pair has exactly these roles; `pairOffset` is respected:

| Phase | Roles |
| --- | --- |
| `benchmark`, `donate` | `cold_fork`, `warm_full_prefill`, `novel_donor`, `donor`, `ssd_restore`, `donor_ssd_restore`, `donor_ssd_repeat`, `other_tenant`, `after_cancel_restore` |
| `restore` | `ssd_restart_restore`, `cold_fork`, `warm_full_prefill`, `donor_ssd_restore`, `other_tenant`, `after_cancel_restore` |
| `refuse` | `read_budget_refusal` |

### Matched Donation Evidence

The separate `donationControls` objects are correctness evidence, not additional
performance roles. Each contains `cell`, `pair`, `controlRow`, `benchmark`,
`cacheWitness`, and `warmupIterations`. `controlRow` is an existing
`ModelPrefixBenchmarkRow` with role `donation_control`; it is never inserted into
`benchmark.rows`, so the 9/6/1 role matrix above is unchanged.

- Control and donor use the same positive `targetTokens`, equal to the cell's `demandedTokens`, and the same actual rendered `promptTokens`, `promptSHA256`, full `outputSHA256`, and nonempty `cacheScopeSHA256`. Actual prompt counts can exceed specification floors. Both use `prefixCacheEnabled: true`, `samplingRequestID: 11`, `samplingTemperature: 0`, and `stopTokenCount: 0`; both complete the full requested output budget without EOS truncation.
- Both carry identical, nonempty `prefillRanges`: ordered contiguous `[lowerBound, upperBound)` intervals covering `[0, promptTokens)`, with `packed: false`. A present `plannedCap` is a positive integer at least the interval width. Trace length equals `prefillChunks`; `preemptions` and `packedPrefillChunks` are zero. Equal chunk counts alone are not matched geometry.
- Control reads, writes, restored/matched/replay tokens, stage consumptions, and retained staging/write-host bytes are all zero. The donor likewise has no reads, restored/matched/replay tokens, stage consumptions or retained bytes, but has positive actual file and byte writes. Both have drained checkpoint writes and qualified MTP evidence.
- `cacheWitness` reports the actual isolated control cache: `state: "ready"`, `durableMode: "ssd_complete"`, `memoryEnabled: false`, `maxStageBytes: 1048576`, `manifestAllowanceBytes: 1048576`, and `checkpointFiles: 0`. It is not inferred from zero IO counters. In persistent mode the control uses a separate isolated root with the same persistent key namespace; the actual root path is not part of the proof.
- Control `benchmark` metadata deliberately has `rows: []`. All normal model/runtime/backend/scheduler/key-mode controls, requested and actual live/checkpoint precision, checkpoint layout, `executionStorage`, and optional `assistantIdentity` match the main benchmark. Both rows' nonempty `schedulerConfiguration` also matches the main metadata. Control warmup count equals the main report's actual warmup count. The metadata object is not checked against the performance role matrix.

`novel_donor` remains a target-zero diagnostic. Its original output comparison
with the positive-target donor was invalid because their prefill geometry was
confounded; those two outputs may differ. Only the matched control/donor pair
establishes donation output equivalence. Archived reports remain unmodified:
earlier successful versions must be read with their archived validator/source,
not retrointerpreted as passing this version-1 contract.

### Prefill Memory Evidence

SSD restore roles require `memoryAtPrefillCompletion` captured by the existing
`request.onPrefillCompleted` callback on the real engine queue, before
detokenization, public output emission, and retirement. The witness must have
`observationPoint: "engine_queue_prefill_completion"`, `callbackCount: 1`, and
`requestID: 11` equal to the row's `samplingRequestID`. Its `promptTokens` and
`restoredTokens` must equal that row's counts. `backendBytesInUse` and
`backendBytesCapacity` are positive integers; `backendBytesReserved` is a
nonnegative integer. Optional `pagedGeneration` is a UUID, and optional
`pagedCommittedBytes`, `pagedLiveBytes`, and `pagedReservedBytes` are nonnegative
integer counters. No `kvBytesInUse`, `kvBytesReserved`, or `kvBytesCapacity`
published gauges belong in this observation. `memoryAfterRetirement` and its
existing zero-state requirements are unchanged. A former first-output snapshot
does not satisfy this gate, and there is no old-field fallback or version bump
within this unshipped version-1 contract.

Each benchmark/donate or restore phase measures one successful fork restore.
Repeated successful reads and post-cancellation recovery use the original donor
prompt at its deepest existing frontier: repeating
the fork can legitimately donate a deeper suffix via `localRepeat`, even with
target zero, which would mutate the archive under comparison. Thus
`repeatedRestoreMatches` compares `donor_ssd_restore` with `donor_ssd_repeat`, and
`after_cancel_restore` matches `donor_ssd_restore`, not the fork. A restarted
fork matches producer `ssd_restore`; a restarted donor matches producer
`donor_ssd_restore`. Cold and lossy-restored outputs need not match.

- Role medians stay separate by profile, phase/step and role. `cold_fork` is a cache-disabled full-prefill control after warmups, not cold model-load latency. `warm_full_prefill` is repeated cache-disabled full prefill with a hot model/compiler, **not an in-memory prefix hit**. The fixture has `memoryEnabled=false`.
- `donor`, `novel_donor`, fork `ssd_restore`, donor `donor_ssd_restore` / `donor_ssd_repeat`, restart `ssd_restart_restore`, and recovery/control rows are never pooled together. Excluded warmups are not synthesized as samples.
- Paired ratios are **candidate / native-checkpoint baseline**, then median over matched observations within each role. Matching requires identical cell, pair, role and `promptSHA256`, plus exact actual model/weight, runtime binary/metallib/renderer, backend, scheduler, MTP, partition and other control identities. Duplicate/unknown/missing role rows invalidate the report; unmatched cross-profile prompt hashes are not paired. Intentional checkpoint precision/layout differences are allowed; the optional old balanced-live arm also intentionally changes live storage.
- Null metrics stay null, including generation TPS when only one output event exists. Zero denominators yield null ratios. Sample counts accompany medians; there are no acceptance thresholds, statistical significance claims, saturation claims or unexecuted TTFT/TPS preservation claims.
- Disk bytes are **observed encrypted writes**. `memoryAtPrefillCompletion` is real engine-queue backend state at the prefill event, before detokenization and retirement, not first-emission state or a process-peak/total-memory measurement. Summaries include only its backend in-use/reserved/capacity and numeric paged counters, not stale published KV gauges or a disk-to-RAM compression ratio. TTFT includes this queue callback's observation overhead in each arm. `supportsOrdinaryDecodeChaining` is capability only; actual `decodeSteps` / `chainedDecodeSteps` remain reported separately.
- Cross-profile token equality, first divergence (zero-based token index) and marker booleans are only quality observations, never quality pass/fail or a quality guarantee. Prompts are public synthetic shipping records (`ALDER-427`, `BRONZE-913`), generated through Swift production normalization with fixed date `2026-10-09`. Requested prompt counts are floors; actual counts/hashes are in reports. Generation uses the fixed output budget, empty stop tokens and exact `.length` completion checks.

## CPU Checks

These do not invoke Swift, build, use a GPU, access a model or make online calls:

```sh
python3 -B -m unittest discover -s . -p 'test_*.py' -v
python3 -B checkpoint_storage.py --help
```

Tests use synthetic reports and short Python-only subprocesses. Temporary files
are created and removed only beneath this folder; persistent-mode tests exercise
the orchestration contract, not signing, Secure Enclave or real checkpoint IO.
