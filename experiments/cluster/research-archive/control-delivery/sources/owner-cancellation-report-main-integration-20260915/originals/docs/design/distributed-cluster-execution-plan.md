# Distributed cluster execution plan

> Last updated: 2026-09-15 · commit `605651bb9`

Status: **In progress** — 2026-09-15 — engineering plan reviewed; master `605651bb9` merged with existing work preserved. Solo and two-Mac one-output cohorts completed; [serial and lookahead 128-token continuation correctness](../reports/2026-09-15-cluster-lookahead-generation-and-timing.md) now pass for the registered 9B path. Milestone 1 still requires end-to-end provider HTTP streaming/TTFT and peer-failure/recovery qualification. The [peer-owner addendum](distributed-peer-owner.md) supersedes the SSH-only-for-bootstrap transport decision below.

This plan implements the confirmed [delivery requirements](distributed-cluster-delivery.md):
a reusable Darkbloom cluster framework, measured on the available two M4 Pro
Macs, starting with Qwen9B 4-bit, then Qwen27B 4-bit and Gemma26B 4-bit. Prefill
and request-send-to-first-token latency take priority. MTP comparisons include
actual multi-token generation. M3 Ultra results remain estimates.

## Architecture decisions

Use one shared cluster runtime and explicit model adapters. Promote working
experimental code into the provider's normal build rather than making the
Python experiment launcher a permanent product dependency. Keep benchmark
capture and fixed four-request cohort control outside the serving API.

| Component | Owns | Does not own |
|---|---|---|
| Model adapter | Artifact/config semantics; legal partitions; owned/replicated weights; operator execution; request-state and optional MTP bindings | Peer discovery, network setup or provider accounting |
| Execution plan | Membership epoch, rank assignments, tensor/layout identities, chunk policy, state owners, collective order and memory requirements | A universal rule that every model uses the same partition |
| Cluster runtime | Resident workers, plan agreement, transport, scheduling, completion fences, deadline propagation, cancellation and group recovery | Model-specific routing, nonlinearities or speculative acceptance rules |
| Provider integration | One distributed model slot, admission/readiness, normal request and streaming contract, telemetry and accounting | A second independent advertisement of each worker's already-allocated capacity |
| Benchmark client | External request clock, first actual streamed token, completion and errors; paired analysis | Inferring external TTFT from an internal timer or a nonstreaming request |

Initial physical qualification is two members and one active distributed
request per model allocation. Interfaces carry explicit rank count and ownership
so they can extend to larger clusters, but that does not qualify untested sizes
or distributed continuous batching. Reuse existing CBv2 request/state and MTP
semantics. Keep local execution available as its existing separate capability.

The initial Qwen performance candidate is **two whole-layer stages with bounded
prompt-chunk overlap**. This preserves full operator shapes and reuses the
existing state and boundary machinery. Begin with serial transfer to establish
correct physical execution, then enable the existing one-chunk lookahead. Keep
selective FFN tensor parallelism as a measured competitor; broader attention/GDN
head splitting follows only if correctness and profiles justify it.

The initial Gemma candidate is **FFN/expert-intermediate tensor partitioning**,
using the existing experimental loader/hooks while retaining global routing and
attention semantics. It is not numerically qualified yet. This avoids requiring
a new compact whole-layer Gemma constructor for the first comparison. A Gemma
layer pipeline is a later candidate if measured costs warrant that implementation.
Different legal plans through the same runtime are a test of framework reuse.

## 0. Reconcile the working branch with current master

Fetched master is six commits ahead at `605651bb95d71c1da9bb122107925143e9441973`.
It changes provider organization, benchmark construction and attestation/trust
integration. There are no changes to the MLX submodule pointers or experimental
cluster directory in that fetched range.

1. Preserve the current tracked edits, untracked experiment sources and private
   evidence before merging. Keep the frozen c079 and aa7d bundles unchanged.
2. Merge the fetched master into the development branch, resolve documentation
   overlap, and map provider integration to the new subsystem folders.
3. Confirm dependency commits and experimental source identities. Run affected
   build/test checks and current documentation checks. Archive the actual base
   for subsequent builds; a historical binary retains its historical identity.

**Exit:** working branch contains the fetched master, local work is retained,
and new builds have an explicit, reproducible source/dependency base.

## 1. Establish a real 9B path and honest clocks

Start with the registered Qwen3.5 9B 4-bit artifact already downloaded. Reuse
the verified model loader, aa7d resident owner, reviewed process adapter and
retained full-model reference. Finish the small actual launcher/validator
integration; do not build another general evidence framework.

1. Run one bounded resident solo cohort: one load, excluded warmup, three fresh
   requests, explicit release and clean shutdown. Use the retained diagnostic
   input for this runtime check and keep its limited workload claim.
2. Add resident-only JACCL selection and validate effective environment aliases,
   expected rank, two-member device matrix and coordinator before model load.
   Bind actual initialized rank/backend to reports and plan agreement. Preserve
   the existing loopback-only legacy checks and no-fallback behavior.
3. Run the same 9B path over the actual TB/RDMA link, initially serial and MTP
   off. Use an existing validated layer cut; test both 12/20 and 16/16 rather
   than treating prior same-GPU observations as a physical ranking.
4. Validate final logits, committed state and multi-token continuation. Exercise
   timeout, cancellation, peer exit and reconnect; fence the failed membership
   epoch and retire every request owner before accepting fresh work.
5. Integrate this path behind an experimental distributed provider slot and
   local streaming endpoint early. Add an external streaming benchmark client.
   This makes full TTFT measurable before optimizing an isolated harness only.

The current `scripts/benchmark-models.py` is nonstreaming and its elapsed time
is not TTFT. The new client uses one monotonic clock from request send to first
actual content token received. Keep server spans for queueing, tokenization,
plan dispatch, prefill, first-token return and serialization. Do not subtract
timestamps from different machines to manufacture a latency interval.

**Exit:** a reproducible solo/two-machine 9B run with correct continuation,
working cancellation/recovery, and separate external TTFT and internal prefill
measurements. Successful transport initialization alone does not close this step.

## 2. Optimize 9B work division and establish reusable contracts

Use the same artifact, prompt IDs and numerical policy in each paired run.
Freeze development prompts separately from qualification prompts. Establish the
fastest correct eligible solo control on each available device, including the
current Darkbloom serving path; a slower diagnostic baseline is insufficient.

Measure per-stage compute, boundary bytes, GPU-to-transport staging, transfer,
acknowledgements, synchronization, idle time and memory peaks. First measure the
actual critical path, then evaluate a small candidate set:

| Experiment | Change | Selection rule |
|---|---|---|
| Overlap | Serial versus one-chunk lookahead | Retain overlap only when completed-request latency improves within memory bounds |
| Layer balance | 12/20, 16/16 and justified neighboring legal cuts | Balance measured stage service, including attention/endpoint costs; memory capacity is a constraint, not compute speed |
| Chunk size | Start at admitted 512; add a small validated sweep | Trade kernel efficiency against overlap, communication frequency and temporary memory |
| FFN tensor split | Existing selective FFN implementation | Require numerical acceptance and compute savings exceeding added collective/staging cost |
| Broader splitting | Attention/GDN or a justified hybrid | Implement only for a remaining measured bottleneck; preserve numerical and state contracts |

Do not infer faster compute from the 48 GB member's larger memory: both available
Macs have the same CPU/GPU core counts. Keep independent replicas as a separate
aggregate-throughput control. Prefill/decode relocation requires measured state
transfer cost and complete committed-state import/export before it is a candidate.

Extract shared interfaces as the real path is integrated: artifact admission,
partition load, phase execution, committed frontier, cancellation and retirement.
Avoid copying a new supervisor, transport or request lifecycle for each model.
Refactor behavior-preservingly and rerun the relevant real comparison after any
change that affects the timed path.

**Exit:** a selected 9B plan with repeatable benefit or an explicit measured
limitation, plus shared runtime interfaces used by the provider path. A candidate
that regresses or remains numerically invalid is rejected, not selected because
it looks better in a cost estimate.

## 3. Add and measure 9B MTP

The exact 9B and 27B artifacts already include inline Qwen MTP head shards.
Current stage plans explicitly exclude MTP and the final stage has an inert
input embedding. Initially place the head on the final stage and explicitly
admit replication of the required input embedding; retain final norm/output
projection ownership there. Measure its memory cost. Remote embedding lookup
is an alternative only if its extra per-round dependency is worthwhile.

Implement a request transaction spanning all participating ranks: target-owned
verification determines the accepted prefix, then attention KV, GDN recurrent
state, convolution state and assistant history commit that same frontier.
Rejected suffixes roll back consistently before any next round. Publish only
accepted target tokens. Include head/artifact identity and verification policy
in plan/request agreement and exercise rejection, EOS, cancellation and peer
failure during verification.

Reuse the existing local drafter/finalization semantics. Compare serial and
rectangular verification under explicit numerical policies; changed accumulation
order does not imply bitwise identity with serial-off generation. Preserve
existing restrictions for unsupported sampling constraints and output features.

Run the four conditions: solo/off, solo/on, distributed/off, distributed/on.
Use **128 requested output tokens** for the primary MTP/decode comparison and
retain first-token latency from the same request. Record actual MTP engagement,
draft depth, accepted/proposed tokens, verification cost and committed output
TPS. EOS-shortened runs retain their actual counts. A one-output request clamps
speculation to depth zero and can serve only as a prefill/runtime smoke, not
evidence of active MTP. Check any MTP prefill/history and memory overhead.

**Exit:** correct distributed MTP transactions and an honest on/off comparison,
including cases where MTP is unsupported, inactive or slower. Automatic selection
uses measured benefit in the supported workload range; it does not equate an
enabled flag with useful speculation.

## 4. Extend to Qwen27B, then Gemma26B

**Qwen3.8 27B 4-bit:** use the same Qwen adapter/runtime and MTP transaction with
its independently verified 64-layer configuration, inventory and storage/state
bounds. Add long-prefill admission for this actual profile; relabeling the 9B
8K check is insufficient. Repeat correctness, service-time profiling, legal-cut
selection and the four-condition matrix. Prefer partition-only loading on the
smaller member. Measure, rather than linearly extrapolating 9B results.

Current provider policy restricts the exact 27B IDs to M5/NAX. Product integration
must introduce an explicit qualified distributed execution-profile capability
in both provider and coordinator, preserving the existing local profile rules.
Do not spoof hardware capabilities or rename the same artifact to evade the
policy. Available M4 tests qualify their own profile; M3 remains projected.

**Gemma4 26B 4-bit:** select the retained `gemma-4-26b-qat-4bit` artifact. Its
configuration has 30 layers, 25 sliding and five full-attention layers, 128
experts/top-8 and tied embeddings. Its W4/G64 default has 120 W8 overrides;
preserve those declarations. The separate `gemma-4-26b` W8 artifact is not this
benchmark cell.

Start by qualifying the existing FFN/expert-width partition machinery under the
shared runtime. Preserve global routing, branch normalization, quantization and
attention/sliding-state semantics. Dense and sparse partials each reduce before
their own RMSNorm, in dense-before-sparse order. Add a Gemma request-state adapter:
the existing experimental CBv2 request owner admits dense Qwen, so Gemma loading
alone does not supply sliding-state capture, rollback or retirement.

Account for two concrete performance risks. The existing 704-wide expert is
split into 320/384 widths, which removes eligibility for a current optimized
Gemma expert path even though 30-layer geometry is preserved. Also, two branch
reductions across 30 layers and sixteen prompt chunks imply 960 reduction sites
per 8K prefill. These are source-derived counts, not measured transfer times.
Reject this candidate or target the responsible kernel/communication cost if it
loses to optimized solo execution. Compare whole-expert placement only if its
routing skew and communication costs can improve the measured bottleneck.
If a layer pipeline becomes justified, preserve global layer roles and original
30-layer dispatch identity; compact construction and tied output storage cannot
be treated as a simple layer-count edit.

Gemma MTP uses a separate compatible assistant and frozen target full/sliding KV
captures, unlike Qwen's inline head/history. Qualify target/assistant compatibility
and capture ownership explicitly, then run the same on/off matrix. Place the
assistant on the request owner; broadcast the exact verification token window
and policy so every rank executes the same target collective order. Only the
owner samples and accepts; all ranks reconcile before publication. Keep frozen
captures valid across speculative writes and check reduction execution on
prefill, ordinary decode and verification paths. Adapter-specific
state rules stay separate while runtime ordering, cancellation and telemetry are
shared. Complete this model before adding the follow-on Qwen35B scope.

**Exit:** all three selected artifacts use the same cluster lifecycle, transport,
plan and provider integration, with their own correctness, memory and performance
results and explicit MTP capability limits.

## 5. Complete the Darkbloom operator workflow and serving qualification

Implement `darkbloom cluster configure`, `cluster doctor`, `cluster status` and
`darkbloom start --distributed`. Configuration on each member creates or joins
a cluster, pins trusted peer identity and saves its role. Every member runs its
own compatible Darkbloom service; a request-owning member exposes the usual API.
Pairing and authenticated control use the existing security architecture and
platform cryptography. SSH remains a development/bootstrap mechanism, not the
production trust boundary.

Setup must verify model/build identity, memory, the real physical link and a
collective. Preserve management connectivity and saved interface settings;
verify rollback for network changes. Status reports actual transport, active
members, selected plan, model readiness and active/inactive MTP with reasons.

Trace all authoritative slot/capacity readers when integrating registration,
heartbeats, admission and accounting. A peer failure removes the distributed
slot's readiness. Restart or cable reconnection creates a fresh agreed epoch;
surviving partial state cannot silently continue. Preserve the existing absolute
request deadline through routing, queueing and cluster handoffs. Use the caller's
remaining budget and retain the upstream response margin.

For qualification, use ten distinct 8K prompts with balanced condition order,
one warmup and three measured requests per condition. Record each request,
failure, external deadline margin, per-prompt median and paired speedup. Expand
to 4K/16K and selected supported lengths, then sustained serving and capacity
tests with sample counts sufficient to interpret the reported tails. Include
cold startup separately. Retain actual prompt usage after chat templating and
tokenization and the coordinator's estimated prompt count, since they need not
be identical. No percentile exemption to the per-request SLA was specified.
Direct endpoint tests identify their client location and qualify that path only;
final upstream validation uses the actual OpenRouter route and its telemetry
when accessible, with provider routing/fallback behavior recorded.

Compare Exo where the artifact and workload can be matched; otherwise state
the differences. The inspected local Exo snapshot is `21a54c5e`, with separate
pipeline/tensor placement and remote-prefill code. Source comparisons guide
experiments; comparative speed claims require actual matched measurements.

**Exit:** CLI workflow, startup, status, streaming, cancellation, restart,
reconnection, version mismatch, local-mode regression, capacity and accounting
checks pass. Publish supported configurations and operating limits, runnable
benchmarks, raw evidence and setup/troubleshooting documentation. Prepare the
release change for review before any production deployment.

## M3 Ultra projection and progress reporting

After real profiles exist, estimate a named M3 Ultra configuration using separate
operator compute, memory traffic, communication and overlap terms. Publish ranges,
assumptions and sensitivity; never put modeled results in measured tables. The
800/1000 TPS 27B objectives remain desired/projected outcomes, not proof or a
hardware-access dependency for this delivery.

For each milestone report: what now runs, the relevant correctness/failure
checks, measured TTFT/prefill/decode or the concrete reason no measurement exists,
and the next bottleneck. Keep experiments small enough to reject a losing
approach quickly. The final outcome is working reusable provider functionality;
an accumulation of scaffolding or audit receipts is not completion.
