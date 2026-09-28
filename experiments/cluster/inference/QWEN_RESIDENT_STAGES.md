# Resident whole-layer stage cohorts

> Last updated: 2026-09-15 · commit `605651bb9`

The internal resident rank controller loads one verified 9B stage and runs a
bounded sequence of fresh requests on it. It reuses the existing long-prefill
request loop, then releases the stage once at cohort shutdown. The experimental
`qwen-resident-benchmark-worker` CLI now exposes this owner and its solo control
through a bounded JSONL protocol. The [real solo diagnostic cohort](../../../docs/reports/2026-09-15-cluster-resident-solo-baseline.md)
passes. The [two-Mac 4/28 cohort](../../../docs/reports/2026-09-15-cluster-rdma-prefill-baseline.md)
also completed four requests with matching reference digests and clean shutdown.
Its 426.98 internal TPS median is slower than the retained solo control.
Representative performance remains unqualified.
This worker is separate from the Darkbloom serving engine.

## Ownership and request flow

[`runQwenLongPrefillResidentRankCohort`](Sources/ClusterInference/QwenLongPrefillResidentRankOwner.swift)
accepts retained request admissions and an excluded warmup count. The existing
entry owner remains responsible for early arithmetic-environment checks, actual
OS resource admission and the overall deadline. All requests must use the same
source, Plan, arithmetic and resource metadata. Their UUIDs and epochs must be
fresh; repeated token histories are allowed. Admission accepts 1–16 requests,
requires at least one measured request, and refuses phase/owner trace paths.

Before constructing the transport, the
[`QwenLongPrefillResidentCohortAgreement`](Sources/ClusterInference/QwenLongPrefillResidentCohortAgreement.swift)
binds the entire ordered list, raw prompt hashes, source and resource identities,
selected Plan, arithmetic, scheduling and warmup boundary. Its encoded descriptor
is bounded to 16 KiB. After transport setup, both ranks exchange its domain-specific
digest through the existing completed 256-byte send/receive sequence, before the
single stage load. A mismatch throws; the parent must still cancel and reap the
whole cohort because a peer may be waiting for a reply. This establishes shared
intent, while later per-request readiness binds the actual loaded stage.

The file-private owner exposes fixed CPU results only. Each request runs inside
an autorelease scope through the unchanged
[`runQwenLongPrefillRankRequest`](Sources/ClusterInference/QwenLongPrefillRankRequest.swift):
fresh readiness, context and state construction, all frame commits and consumed
acknowledgements, token return, post-stop release, final diagnostics and request
retirement. The next readiness exchange also waits for the peer to finish its
previous request. No allocator cache clear or full-weight readback is added
between requests.

[`QwenLayerStageResidentLifecycle`](Sources/ClusterInference/QwenLayerStageResidentLifecycle.swift)
serializes request callbacks, rejects overlap and identity replay, and prevents
further requests after any failed or invalidated scope. The callback runs outside
the state lock, so reentrant or concurrent calls refuse instead of silently
queuing. Final release is attempted once after active request work unwinds.
The actual owner synchronizes native streams, checks native errors, drops its
loaded stage and checks weak model release before returning a successful cohort
report. Primary and cleanup failures remain separate in diagnostics.

The existing Session layout guard stays in place. Ordinary GDN fusion preserves
registered parameter paths, dtypes and shapes while replacing projection storage
with fused views. The owner retains the original load receipt and permits only
the existing model forward to perform that transformation. This is exclusive
source-level ownership, not a physical allocation-lineage certificate.

Selected stage loading uses
[aligned selected-payload reads](QWEN_DENSE_STAGE_LOADING.md#aligned-selected-payload-reads)
through its owned verified safetensors descriptors in
[`materializeVerifiedQwenLayerStage`](Sources/ClusterInference/VerifiedQwenLayerStageLoading.swift).
It requests uncached IO and disables read-ahead, using at most 8 MiB of anonymous
aligned scratch and explicit padding/read accounting. It does not map checkpoint
files, change a global cache flag or establish file-cache absence. Selected bytes
and storage identities retain their meanings; the host scratch allowance is
charged while reads remain. Ordinary full-reference loading is unchanged.

The dedicated rank CLI requests `Memory.cacheLimit = 0` after its typed and
actual resource gates. Before loaded readiness,
[`QwenResidentBenchmarkAllocatorPolicy`](Sources/ClusterInference/QwenResidentBenchmarkAllocatorPolicy.swift)
synchronizes native streams, checks native errors, clears freed-buffer cache
and requires zero cached bytes with unchanged active/peak allocation snapshots.
The optional `allocatorPolicy` ready record carries those observations. This
does not change active allocation limits, full-reference loading or the solo
cache policy, and adds no cache clear between requests.

## Results and remaining scope

[`QwenLongPrefillResidentRankReport`](Sources/ClusterInference/QwenLongPrefillResidentRankReport.swift)
separates each retired request with resident weights from the final model release.
It records the common cohort agreement and readiness, original source load once,
warmup designation, per-request timing and CPU diagnostics, and allocator
observations after each retirement. Timing keeps the existing first-token
boundaries; it is not qualified throughput.

The CLI and private parent now enforce one warmup and three measured requests,
with one weight load and fresh request state. The solo control ran all four
requests successfully, matching the retained same-input reference before clean
release. Earlier 12/20 and 8/24 physical attempts crossed the unchanged 6 GiB
actual-free floor during their first requests. The 4/28 cut completed the full
cohort, with all final-logit and state digest comparisons passing. See the
linked report for measured intervals, memory samples and qualification limits.
Multi-token continuation, broader prompts and external TTFT remain unmeasured.

## Resident worker and JACCL selection

[`QwenResidentBenchmarkWorkerCLI`](Sources/ClusterInference/QwenResidentBenchmarkWorkerCLI.swift)
accepts `--role solo|rank`, exact registered artifact/prompt identities, the model
directory and a bounded lifetime. Rank execution also selects the existing
prefill policy and optional legal stage cut. Its JSONL control sequence is
`open`, four individually authorized `run` commands, and explicit `shutdown`;
outputs are `ready`, four `result` events, `released` and `stopped`. The
[protocol types](Sources/ClusterInference/QwenResidentBenchmarkWorkerProtocol.swift)
define request IDs and fresh epochs. The worker profile remains fixed at
8192 input tokens, 512-token chunks, B1, one generated token and MTP off.

Ranks may now select `--transport jaccl`; omitted transport retains
`loopback-test`. Solo rejects a transport selector. The separate one-shot
long-prefill modes retain their existing loopback restrictions. Before any
model load, [JACCL admission](Sources/ClusterInference/QwenResidentJACCLConfiguration.swift)
validates rank 0/1, an explicit two-member device matrix, and a numeric IPv4
coordinator. It accepts the native `JACCL_RANK`, `JACCL_IBV_DEVICES` and
`JACCL_COORDINATOR` names or their `MLX_RANK`, `MLX_IBV_DEVICES` and
`MLX_JACCL_COORDINATOR` aliases; conflicting aliases and ring overrides refuse.
Both peers bind the same matrix bytes and coordinator into their cohort
agreement. Actual initialized rank, size and backend must match. No network
configuration is changed by this admission code.

The parent must supervise both remote native processes, enforce the cohort
deadline, cancel on failure and confirm retirement separately from SSH exit.
An initialized JACCL backend alone does not prove physical model correctness.

## Model-free readiness entry

The experimental `qwen-long-prefill-cohort-readiness-check` mode exercises the
actual pre-load exchange without a model. Its
[closed admission](Sources/ClusterInference/QwenLongPrefillCohortReadinessAdmission.swift)
accepts exactly five explicit flag/value pairs:

| Flag | Value |
|---|---|
| `--mode` | `qwen-long-prefill-cohort-readiness-check` |
| `--transport` | `loopback-test` |
| `--epoch` | Fresh lowercase 32-digit hexadecimal run identity |
| `--cohort-readiness-case` | `match` or `warmup-mismatch` |
| `--timeout-seconds` | Canonical integer from 1 through 30 |

Every other inference flag rejects. Both intents use the retained 9B metadata
and a synthetic A/B/A request sequence with fresh request epochs. The mismatch
changes the excluded warmup count on one rank. No model directory, checkpoint
payload, loaded-stage receipt or request execution is admitted. The fixture's
resource identities do not establish current OS resource admission.

A parent must configure both loopback ranks, bound the whole cohort, and cancel
and reap peers on failure. The native alarm alone does not establish coordinated
cancellation. Matching, warmup-mismatch and parent cancellation with a missing
peer have a private qualification driver; its current version passes 36
fabricated CPU tests. Actual model-free loopback checks on one development Mac
pass all three scenarios. Matching ranks exit successfully with identical cohort
records. Mismatched ranks both exit with the exact semantic disagreement before
model loading. The missing-peer test observes the configured lone rank running
before its three-second parent deadline, then cancels and reaps it. Source,
bundle and owned-process checks pass afterward.

The [shared exchange](Sources/ClusterInference/QwenLongPrefillReadinessExchange.swift)
completes each rank's ordered digest send/receive before comparing values. An
earlier version threw during receive, leaving its peer without a response; that
failed qualification remains retained. Send completion permits local source
release and does not establish peer consumption. Transport or native failures
still invalidate the exchange. These checks do not invoke the resident model
controller described above or establish physical two-machine transfer.

## CPU checks

From the repository root on macOS:

```sh
bash experiments/cluster/inference/Tests/ResidentLayerStages/run.sh
```

The runner compiles the actual lifecycle gate and a fake private owner under
Swift 6 with warnings treated as errors. Its 21 passing cases cover A/B/A
histories on one fake model, fresh zero-frontier state, replay and limit
refusals, errors after a commit or close, retained objects, reentry and final
release failures. Two semaphore-controlled overlap cases join four actual
threads and verify that request and release contenders refuse while the first
request remains active. These checks exercise CPU ownership and synchronization;
they do not initialize MLX, load weights or establish native model reuse.

The executable's `--mode adapter-check` also passes four accepted and 35 rejected
actual cohort-admission cases, followed by six cohort identity invariants, eight
pairs of distinct valid peer agreements and 17 rejection cases. Four independently
derived SHA vectors preserve the original request readiness domain and distinguish
the new cohort domain. These checks use the actual Options and admission types
without constructing a collective or model. The model-free entry adds three
accepted, 42 rejected and five identity cases through actual Options. These
admission records remain in the current adapter suite and do not execute the
native exchange.

`--mode qwen-resident-benchmark-worker-check` adds the resident protocol,
resource/lifecycle, solo and CLI checks. Its JACCL group passes 24 accepted and
77 rejected configuration/admission cases with injected environment and file
readers. The preceding five groups remain byte-identical to the solo worker
build.
These are CPU fixtures; actual physical transfer is a separate test.

`adapter-check` includes `checkpoint_read_policy_check`. Its tiny real
file verifies cached/uncached bytes, repeated opt-in and rehash, bounds rejection
and in-place mutation detection without model arrays. The added
`checkpoint_aligned_selected_read_check` passes nine accepted and ten rejected
actual-file cases for aligned/edge copies, bounds, overflow, EOF/interruption and
mutation. All 43 adapter records pass; the preceding 42 retain their exact bytes
and order. These CPU fixtures do not measure physical memory savings.

See also the [long-prefill rank flow](QWEN_LONG_PREFILL_RANKS.md) and
[registered dense model profiles](QWEN_DENSE_PROFILE.md).
