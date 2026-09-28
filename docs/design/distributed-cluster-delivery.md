# Distributed cluster delivery — reusable runtime, prefill and MTP

> Last updated: 2026-09-16 · commit `605651bb9`

Status: **In progress** — 2026-09-16 — [9B measurements](../reports/2026-09-15-cluster-resident-solo-comparison.md) show a 1.85× prefill gain, with one external 8K response at [10.503 seconds](../reports/2026-09-15-cluster-balanced-prefill-http.md). [First 27B results](../reports/2026-09-16-cluster-delivery-progress.md) reach 165 distributed versus 127 solo prefill tokens/s. [Authorization and encrypted-buffer checks](../reports/2026-09-16-cluster-authorization-and-buffer-checks.md) pass 2,790 coordinator tests and 35 native allocation cases on each Mac. Verified pair reservation and CLI/lifecycle foundations are implemented; automatic placement, tensor/expert parallelism, real MTP gains, full Gemma execution, encrypted RDMA and sustained product/SLA qualification remain unfinished.

Deliver an opt-in distributed inference framework inside Darkbloom. Reusable
model support and lower real request latency are primary acceptance criteria.
Prefill is the main performance priority; measure decode and total response
latency as well. This decision supersedes the hardware-dependent completion
criteria in [the original goal](distributed-inference-goal.md).

## Hardware and implementation order

The available development cluster consists of two M4 Pro Macs with 24 GB and
48 GB of unified memory, connected through Thunderbolt 5. Develop, validate and
benchmark on this pair. Both machines run Darkbloom, with compatible runtime
versions and explicit cluster membership. There is no M3 Ultra test pair.

| Order | Registered artifact | Required comparison |
|---|---|---|
| 1 | Qwen3.5 9B, 4-bit | Working solo and physical two-machine inference, fresh-state prefill and generation; MTP off/on where the artifact and runtime support it |
| 2 | Qwen3.8 27B, 4-bit | Reuse the framework, validate partition loading and state continuity, optimize prefill and compare MTP off/on |
| 3 | Gemma 4 26B, 4-bit | Add its model-specific semantics through the same framework; compare prefill, decode and MTP off/on |
| Follow-on | Qwen3.5 35B and further families | Extend through adapters and capability checks rather than duplicating the cluster runtime |

Use exact registry identities and artifact/config/tokenizer hashes. A model
family name or an MTP flag alone does not establish a supported capability.
Initial qualification is text-only. Each additional quantization, modality,
state-transfer mode or speculation implementation needs explicit support.

## What makes the framework reusable

Shared code owns cluster membership, authenticated control, transport,
collective ordering, deadlines, cancellation, worker lifecycle, measurement and
execution-plan selection. A model adapter describes:

- Operators, numerical semantics and legal partition boundaries, including
  tensor packing and quantization alignment.
- Owned weight ranges and bounded partition loading without an accidental
  full-model allocation on each member.
- Attention, convolution, recurrent and auxiliary state ownership across
  prefill, decode, speculation, acceptance and rollback.
- Supported execution plans, capability checks and model-specific validation.

The runtime must execute the selected Qwen and Gemma artifacts through these
shared boundaries. Adding another model may require an adapter and kernels;
arbitrary models are not automatically compatible through tensor-name matching.
Support more than two members in the interfaces and membership protocol, while
initially qualifying physical execution on the available two-member cluster.

Choose work division from measured costs. Compare selective tensor splitting,
whole-layer placement and useful hybrid plans. Account for actual communication,
CPU/GPU staging, synchronization, memory and uneven rank service times. Capacity
alone must not assign twice the compute to the 48 GB member: the available Macs
have the same CPU/GPU core counts. Separate prefill/decode placement is useful
only if complete committed-state transfer and its measured cost justify it.

## Measurement and the first-content deadline

The user-supplied upstream requirement is **10 seconds + 1 ms per token**, with
TTFT measured from when OpenRouter sends the request until the first streamed
token. Use the prompt-token interpretation in the existing coordinator policy;
at 8,192 prompt tokens the stated allowance is 18.192 seconds. Measure the whole
interval with an external client, including transit, routing, queueing,
tokenization, inference and delivery back. Record every request's deadline margin
and misses, plus latency percentiles; no percentile-based exception was specified
and a median alone cannot establish SLA compliance.

The current [coordinator policy](../../coordinator/modelpolicy/first_content_deadline.go)
already represents that ordinary upstream formula and a one-second response
margin. Its [first-token clock](../../coordinator/api/first_token_clock.go)
is request-absolute and includes waiting and dispatch. Preserve the effective
configured/model-specific deadline; a cluster handoff must not reset it.
Production configuration has not been changed as part of this design.

Measure these separately:

1. **Engine prefill:** prepared input tokens through the first target-model
   token, including fresh state, chunking, GPU completion and collectives.
   Weights are resident; prefix-cache hits are disabled for the primary test.
2. **Serving time to first content:** external request send through receipt of
   the first actual streamed content, including network transit, routing,
   queueing, tokenization, transfer and serialization. Retain server-side spans
   separately. A heartbeat or unverified draft token does not satisfy it.
3. **Generation:** committed output TPS, inter-token latency, accepted draft
   tokens, verification cost, and complete response latency.

OpenRouter's [provider documentation](https://openrouter.ai/docs/guides/community/for-providers)
also includes fetch, first-token and streaming time in its displayed throughput
calculation. That metric must not be confused with engine prefill TPS. The
public page does not specify the user's numerical deadline; the user's
requirement and the repository policy are the basis for this engineering target.

Use a four-condition matrix for each qualified artifact: solo/MTP off,
solo/MTP on, distributed/MTP off, distributed/MTP on. Record unsupported or
inactive MTP explicitly. MTP is primarily a decode optimization; measure any
prefill startup, memory or contention cost instead of assuming a prefill gain.
Count only accepted target-model tokens and qualify rejection/rollback and
multi-token state commits. Keep target artifact, prompt IDs, sampling policy
and numerical settings matched between comparisons.

Begin with a diagnostic 9B cohort to prove the actual runtime. Then tune on a
development set and freeze a separate representative qualification set. Run at
least ten distinct 8K prompts, one warmup and three measured requests per
condition, with balanced condition order. Report raw measurements, failures,
per-prompt medians, latency tails and paired speedups. Extend to 4K and 16K,
longer cases supported by the artifact, and serving load. Compare against the
fastest correct eligible solo implementation and separately against two
independent replicas for aggregate serving throughput.

## M3 Ultra projections

Retain 800 uncached prefill TPS for 27B as the desired M3 Ultra outcome and
1,000 TPS as the stretch outcome. These are projection targets, not release
gates requiring hardware we do not have and not measured capabilities.

Estimate a stated M3 Ultra configuration from measured operator service times,
memory traffic, actual collective costs and execution-plan overlap. Publish
ranges and assumptions, with sensitivity to compute scaling, bandwidth and
communication. Do not scale solely by memory capacity, sum replica throughput,
or convert a host-buffer transport smoke test into a model speed claim.
On-device validation remains future work when hardware becomes available.

## Darkbloom product workflow

Proposed command surface, to be implemented and tested in the provider CLI:

```text
darkbloom cluster configure
darkbloom cluster doctor
darkbloom cluster status
darkbloom start --distributed
```

Run configuration on both machines to create or join a trusted cluster, select
each member's role and save the settings. Each member starts its own Darkbloom
service; `start --distributed` uses the saved cluster configuration and refuses
incomplete setup. Status identifies the actual members, model, transport, work
division and MTP activity. Distributed execution remains opt-in.

The request-owning member integrates with Darkbloom's normal serving path.
Supporting members contribute capacity without independently advertising the
same model allocation as another available provider. Carry the request deadline,
cancellation, committed-token accounting and stream ownership through the
cluster. Peer trust and participating machines' prompt/state access must fit
the [existing privacy model](../architecture/security/encryption.md).

Configuration verifies software/artifact identity, available memory and the
actual physical link, including a real collective. Preserve an independent
management path and saved network settings; verify rollback for any changes.
Do not disable a live management interface or bridge during remote setup.
Test peer loss, cable removal, cancellation, restart, version mismatch and
reconnection. Lost membership invalidates the collective epoch. Future requests
may use an explicitly allowed local plan; partial reductions or duplicate
stream output are never recovery behavior.

## Delivery milestones and completion

| Milestone | Evidence required |
|---|---|
| 1. Physical 9B execution | Resident solo and two-Mac RDMA inference, correct generation, repeated timings, request cancellation and cleanup |
| 2. Reusable model runtime | 27B and Gemma adapters using shared loading/transport/scheduling/lifecycle machinery, with per-artifact correctness and memory evidence |
| 3. Work-division performance | Measured prefill benefit and deadline margins on the available pair; MTP off/on comparisons and documented operating limits |
| 4. Darkbloom integration | Configure/start/status/doctor on both members, authenticated membership, serving integration and failure/restart tests |
| 5. Reproducible delivery | Runnable benchmark suite, compatibility table, raw evidence, setup/troubleshooting docs and explicitly estimated M3 Ultra results |

Every implementation cycle should end with runnable code, a meaningful check or
measurement, and the next concrete bottleneck. Hardware availability does not
block framework development. A numerical test, transport smoke, scaffold or
projection alone cannot close the integrated delivery. Publish the release only
after the complete implementation and its evidence are reviewable.
