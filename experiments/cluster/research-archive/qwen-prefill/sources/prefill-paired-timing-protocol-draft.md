# Prospective paired prefill timing protocol

> Draft: 2026-09-14. Source inspection only; implementation and trials remain prospective.

The observed serial interval of 3.726663625 s and later lookahead interval of
0.228014625 s are two differently ordered fresh-process observations. They do
not identify a scheduling speedup: process initialization, native pipeline
compilation, shared driver caches, model fusion, allocator state and host load
can all differ. Preserve both observations as prior diagnostics, outside the
prospective sample below. Serial independent correctness has passed; the
lookahead independent audit must pass before this protocol starts.

## Fixed scope and questions

Keep the registered real 9B artifact, exact natural prompt IDs, 65 input tokens,
chunk size 32, output count 1, no teacher, native precision, batch one, 16+16 layer plan and
two-process loopback transport. Keep the existing prompt ≤128/chunk ≤32, source,
storage, resource, ownership and deadline gates intact. Do not change the current
single-shot modes' `repeats=1`, `warmups=0` admission to create a hidden loop.

Measure three implementations: **S**, verified unpartitioned CBv2 solo with the
same 32/32/1 chunks; **A**, v3 `serial_v1`; **B**, v3
`prompt_lookahead_one_v1`. A and B use identical boundary/token wire semantics
and integrity work. The two workers share one physical GPU; this is a driver,
reuse and local scheduling experiment, not a two-chip scaling experiment.

Distinguish two process conditions. **F** creates a fresh process or process
pair, loads verified weights, then runs its first request. **R** loads weights
once, runs two fixed warmup requests, then two measured requests on those same
model objects. Every request, including warmups, has a fresh UUID, agreement,
transport wrapper and empty KV/recurrent state. R retains no prefix cache or
prior logits. Both conditions run after common qualification priming, so F is
called **host-primed/fresh-process**, never cold-driver or cold-filesystem.
R versus F measures the combined resident-process/model-reuse intervention;
it cannot isolate weight residency from fusion, compilation or allocator reuse.

## Prerequisite qualification and common priming

Before counting timings, run one bounded four-request R cohort for each of S,
A and B. Retain all four first-token intervals, but exclude these cohorts from
the prospective performance sample. Preserve the existing same-process native
exact-byte baseline/stage control. For every two-rank request compare final
logit metadata/native-byte SHA and every global KV/conv/SSM descriptor/digest
with the separately resident, verified full-model reference at the same prompt
and chunk schedule. Candidate full-vocabulary values remain private; the remote
CPU audit verifies their native-byte digest, not a direct candidate byte array. Derive
the expected finite first-index argmax from that reference, not a hardcoded
token. Require all request frontiers to start at zero and end at 65; for A/B,
require three completed boundaries, exact ACK/selection bindings, three released
original wrappers per rank and A=0/B=2 prepared-ahead frames.

The tiny lifecycle proof already exercises fresh requests on the same fused
stage objects (`QwenLayerStageLifecycleCheck.swift:58–62`). It is not the real
9B resident reuse qualification. Keep `QwenLayerStageSession`'s loaded-layout,
frozen-model and no-MTP guards; do not bypass them if a later construction fails.
Release all models and owned processes after each qualification cohort. These
three cohorts also provide common priming of all tested paths. Do not purge OS
or Metal caches, reboot, change power policy or evict unrelated user workloads.
Cache warmth is an observed condition, not something the process boundary proves.

## Counterbalanced prospective sample

Freeze the six-condition mapping, order, input bytes and analysis before launch:

| Label | Implementation | Process condition |
|---|---|---|
| 1 | S: matched solo | F: one first request |
| 2 | A: serial stages | F: one first request |
| 3 | B: lookahead stages | F: one first request |
| 4 | S: matched solo | R: two warmups, two measured requests |
| 5 | A: serial stages | R: two warmups, two measured requests |
| 6 | B: lookahead stages | R: two warmups, two measured requests |

Execute six chronological blocks, one cohort per cell, in this fixed order:

| Block | Cohort order |
|---|---|
| 1 | 1, 2, 6, 3, 5, 4 |
| 2 | 2, 3, 1, 4, 6, 5 |
| 3 | 3, 4, 2, 5, 1, 6 |
| 4 | 4, 5, 3, 6, 2, 1 |
| 5 | 5, 6, 4, 1, 3, 2 |
| 6 | 6, 1, 5, 2, 4, 3 |

Each condition occupies every within-block position once; within-block directed
carryover pairs are balanced. This gives 36 prospective cohorts and 90 target
requests, plus 12 prerequisite requests. A cohort's F value is its one interval;
its R value is the median of its third and fourth request intervals. Retain both
R measurements and both warmups individually. Treat the six blocks, not the 12
correlated R requests, as the comparison units. Pair S/A/B within each block
and process condition; pair F/R within each implementation and block.

No model or worker from one cell remains alive during another cell. In
particular, never co-reside the solo baseline with stage weights. Between
cohorts use the same predeclared five-second quiet interval, then rerun existing
resource/admission checks. Inside R, complete post-stop evidence and retirement,
synchronize both streams, then use a one-second quiet interval and fresh
readiness agreement before the next request. Keep those intervals outside the
first-token clock. Do not lengthen warmup until a preferred latency appears.

## Matched first-token interval

Prepare token IDs and verify/load models before entry. A/B keep the current
rank 0 clock: immediately before start-send, before either fresh native context,
through validation of the returned first selected token and the final consumed
ACK. S starts immediately before `CBv2RequestSession` construction and stops
after its actual uncast argmax, all-logits-finite reduction, scalar readback and
local selection/frontier validation. S has no artificial wire delay or dummy
boundary hashing; communication and stage integrity are real A/B costs. All
paths include fresh request state, all three prefill chunks, final norm/head,
required state-root evaluation and checked token availability.

Keep boundary checksums, native staging/copying, metadata checks, completion
fences and bounded scalar trace work inside A/B. Exclude tokenization, weight
load/hash, readiness, previous warmups, final state/logit capture and retirement
from every first-token interval. On A/B, the existing post-stop-release ACK
remains after rank 0's stop and before either rank's diagnostic capture. Preserve
the exact UInt64 start/stop/duration nanoseconds; never subtract clocks across
ranks. Record post-stop capture/close and model-release/load times separately.

S must use `.evaluationOnly` for its first two chunks and
`.lastPositionLogits` for the final chunk via the actual CBv2 session, matching
the current stage consumer. The existing captured baseline recorder is not a
timer: its per-frame state captures remain outside this new measured path.
The solo owner retains its final `[1,V]` array only through post-stop exact
capture, then drops it and closes/cancels its request.

## Minimum additive implementation

1. Add a small matched-solo owner around `loadVerifiedQwenLayerStageBaseline`
   and `CBv2RequestSession`; reuse their forward/retirement paths. Use the same
   native selection operations as `QwenLayerStagePrefillFinalObservation.select`
   with a truthful solo identity, not a fabricated stage receipt. Return CPU-only
   timing, selection and final evidence. Prove its evidence against the existing
   recorded full-model baseline before including it in the sample.
2. Add a separately admitted, fixed-size resident cohort owner. Retain one
   verified `LoadedQwenLayerStage` per rank, then call the existing
   `runQwenLayerStagePrefillRankRequest` four times with newly constructed
   requests/agreements/transports. Its current start, stop, final capture and
   close logic can remain unchanged. A solo cohort analog retains `LoadedModel`
   and creates four independent CBv2 sessions. No second MLX caller/thread and
   no reusable request context are needed.
3. Bind cohort UUID, ordered fresh request epochs, fixed policy, ordinal,
   warmup/measured role and source/input fingerprints in a closed parent cohort
   manifest. If the native collective group is retained, permit the next
   readiness exchange only after both prior request paths have drained their
   terminal controls and retired state. Each fresh readiness exchange binds the
   next agreement; a failed group is never reused. Validate this bounded group
   reuse before the prospective sample; it is new relative to one-shot launch.
4. Keep per-request reports truthful: state retired, weights still resident.
   Emit `modelReleased=true` only on the terminal cohort record after the outer
   model autorelease scope, stream synchronization and weak-model check. Retain
   CPU-only per-request records; do not keep contexts, arrays or loaded models
   in returned tuples/closures. Clear the MLX allocation cache only at final
   model release, consistently with current one-shot behavior, not between R
   requests. Record cached/active bytes separately from request ownership.
5. Add guarded parent scheduling and CPU audit for the fixed manifest. Existing
   v3 flow/policies and one-shot modes stay unchanged. Do not add user-facing
   repeat/warmup options that silently bypass current admission. New cohort
   and solo source/binary/launcher changes require new frozen provenance.

## Provenance, resource and stopping rules

Pin source commit plus dirty-source snapshot, submodule/runtime revisions,
binary SHA, metallib/runtime bundle, launcher/control/auditor SHA, exact model
aggregate/config/storage/plan identities and input bytes. Pin native dtype,
BF16 conversion, `DARKBLOOM_CBV2_ATTN_QUERY_BLOCK`, relevant MLX environment,
host/OS/build and power mode. Record process/cohort/request IDs and chronology.
Do not infer equal arithmetic merely from an artifact hash. Re-verify before
and after each cohort; all three implementations use the same frozen build.

Retain the guarded launcher's current initial actual-free ≥6 GiB, post-hash
reclaimable ≥8 GiB, pressure ≤2 and zero-new-reported-swap rules; these are screens,
not memory guarantees. Carry the study's initial swap reference across cohorts
as well as each local gate. Keep bounded owned-PID/RSS observations, active/cache
MLX bytes and process-lifetime MLX peak. That peak is not a per-request peak;
one-second host sampling can miss a short request. Preserve full resource
records and comparison-phase timestamps without placing new polling inside the
native timed interval. No unrelated model/process eviction is allowed.

Each cohort retains the existing 180-second hard parent deadline, covering all
its warmups and measured requests; do not restart that deadline per request.
Bound the entire study to 39 cohorts/102 requests and two hours. On any artifact,
identity, native/state/logit/token, ownership, output, resource or deadline
failure, stop the study, fence both owned ranks, preserve the primary and cleanup
errors, and retain the incomplete block. Do not retry that epoch, replace a slow
sample, or complete the block using an unrecorded extra run. A new study after
diagnosis needs a new manifest. Do not stop early for an attractive ratio or
extend the fixed sample to obtain significance. An admitted but slow run remains
a valid observation. Continue only while all predeclared gates pass.

Report all elapsed intervals in chronological order, each condition's six
cohort values, median/range and paired per-block latency differences/ratios.
Show the F-to-R contrast, request 1–4 warmup trajectories and block/order trends.
Six paired blocks are a bounded pilot, not a reliable p95/p99 or broad workload
claim. Persistent drift or disagreement among block ratios makes the comparison
inconclusive; it does not justify deleting observations or relabeling caches.

## Relationship to the target

This protocol can qualify timer consistency, real 9B resident reuse and local
serial/lookahead behavior on one frozen 65-token prompt. It does not establish
the fastest eligible solo, two-machine transport/GPU overlap, long-context
prefill, generated decode or 800 TPS for 27B on two M3 Ultras. Those require
separate artifact/resource admission, same-interval fastest-correct-solo
screening, physical two-host qualification and the goal's held-out 8K workload.
Keep `throughputMeasurementValid=false` for current correctness modes. Do not
turn these short-loopback diagnostic rates into a hardware performance claim.
