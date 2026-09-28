# Distributed inference — goal and acceptance criteria

> Last updated: 2026-09-15 · commit `e4df336bc`

Status: **Superseded by [distributed cluster delivery](distributed-cluster-delivery.md)** — 2026-09-15 — user confirmed reusable framework delivery on the available Macs, 9B → 27B → Gemma with MTP comparisons, and estimated M3 Ultra performance.

Build an opt-in distributed inference framework for Darkbloom that lets users
connect Apple Silicon Macs and reduce inference latency. The first product
priority is faster prefill for Qwen3.8 27B on two M3 Ultras: **800 or more
uncached input tokens per second is the acceptance target; 1,000 or more is the
stretch target.** This is the active engineering goal, not a measured result or
a promised hardware capability.

The framework must make additional models practical to support through shared
partitioning, transport, scheduling and validation machinery. Decode throughput
remains a secondary objective; a prefill gain must not conceal a worse overall
request experience. This record refines the ongoing cluster-inference work.

## Hardware and model scope

The initial release audience is users connecting two M3 Ultra Macs over
Thunderbolt 5 with a verified RDMA transport. Start qualification with two
256 GB machines. Record the exact GPU core count on each machine; results from
different M3 Ultra configurations are separate qualifications. Memory capacity
alone does not identify a performance tier. Smaller development Macs can prove
correctness and expose transport costs, but cannot qualify the M3 Ultra target.

| Model | Role | Required outcome |
|---|---|---|
| Qwen3.8 27B, dense | Primary performance and initial release model | Qualify the registered 4-bit artifact on M3 Ultra, reach the prefill target, and validate continuation after distributed prefill |
| Qwen3.5 9B, dense | Development and regression model | Exercise the same adapter and execution path with affordable correctness and failure tests |
| Qwen3.5 35B, MoE | Planned additional model | Reuse the framework for expert projections and routing; measure prefill and decode against its own single-node baseline |
| Gemma 4 26B, MoE | Planned additional model | Reuse the framework while preserving Gemma-specific branch normalization and state dependencies; qualify each selected quantization separately |

The two MoE models are part of the intended framework scope. Select the first
MoE implementation using profiles and implementation dependencies, and qualify
the other afterward. Their acceptance target is a demonstrated latency benefit
on stated workloads, not an assumed copy of the dense model's TPS target.
Quantization, auxiliary prediction and multimodal modes are explicit capability
dimensions. Initial qualification is text-only; unqualified modes remain
unavailable for distributed execution.

## What counts as reaching the prefill target

The primary benchmark measures one request with 8,192 uncached input tokens,
batch size one, model weights already loaded, fresh attention and recurrent
state, and no shared-prefix cache hit. Use the same artifact, numerical policy
and prompt token IDs for paired single-node and distributed runs.

Measure from submission of the prepared input tokens to the inference engine
until the first target-model token is available and all required GPU and
collective work has completed. This includes prompt chunking, synchronization
and the final forward pass that produces the first token. Divide the complete
input token count by that elapsed time. Report tokenization, loading and API
overhead separately, along with end-to-end time to first token. Cached, replayed
and speculative tokens cannot inflate this metric.

Qualification requires all of the following:

1. **Repeatable throughput:** at least ten fixed, representative text prompts
   of the primary length, three measured runs each after separate warmup.
   Publish the median of each prompt's median, the individual prompt results
   and latency tails. The primary aggregate must reach 800 TPS; 1,000 TPS is
   the stretch outcome. Keep failures in the report and explain exclusions.
2. **A real benefit from clustering:** paired comparison against the fastest
   correct, eligible single-node implementation on the same hardware and
   artifact. Show the latency reduction and its variation. Also compare two
   independent replicas for aggregate serving throughput, which is a separate
   objective from accelerating one prompt.
3. **Useful operating range:** publish 4K and 16K prompt results and selected
   shorter/longer cases supported by the artifact. Report chunk size, batch
   width and memory peaks. A gain at 8K cannot become an unqualified claim for
   every context length or workload.
4. **Correct continuation:** validate logits with explicit numerical tolerances,
   controlled token histories and generation checks; exercise attention,
   convolution and recurrent state over chunk boundaries. Measure committed
   decode TPS, inter-token latency, and total request latency after prefill.
   Any phase handoff or MTP path needs its own correctness qualification.
5. **Reproducibility:** retain model/config/tokenizer hashes, executable and
   dependency revisions, plan digest, hardware and OS identities, power/thermal
   state, background load, actual transport, dtype/quantization, raw timings,
   generated tokens and errors. Runs with logit capture are correctness runs
   unless the instrumentation is proven outside every rank's timed path.

Tune on a development prompt set and freeze a separate qualification set before
claiming success. Report cold startup and sustained operation as additional
product measurements. A synthetic test, an estimated FLOP budget, a summed
two-replica rate, or a successful RDMA initialization cannot satisfy this goal.

## Architecture decision

Use a small set of correct execution plans and measured selection between them.
Choose the plan that minimizes the stated request objective under memory and
transport constraints. Tensor parallelism is a candidate, not a requirement to
split every operator. Compare selective FFN splitting, broader attention and
recurrent-head splitting, replicas, whole-block placement, and separate
prefill/decode placement when their dependencies justify implementation.

An adapter describes model semantics; shared runtime code owns process
lifecycle, collective sequencing, transport, profiling and failure handling.
The conceptual adapter boundaries are:

| Boundary | Contract |
|---|---|
| Describe model and artifact | Exact operator graph, effective quantization, numerical semantics, state dependencies and supported phases |
| Enumerate legal partitions | Tensor ranges, packing/group alignment, replicated values, required communication and memory bounds |
| Load a partition | Verify artifact identity and materialize only owned ranges; avoid a transient full-model allocation when loading a shard |
| Execute a phase | Agreed plan and membership epoch, deterministic collective order, completion fences and bounded cancellation |
| Export/import committed state | Versioned ownership for KV, convolution, recurrent and auxiliary state, with explicit support or refusal for each conversion |
| Qualify and profile | Correctness and timing evidence keyed by artifact, hardware, backend, shape, phase and numerical settings |

Begin with dense Qwen FFN partitioning while preserving the rest of its local
semantics. Extend to further operators only after profiles identify the
remaining critical path. For MoEs, compare splitting each expert's intermediate
width with assigning whole experts; retain exact global routing and account
for skew and empty-rank participation. Model-specific nonlinearities determine
where partial results must be combined. A universal replacement based on tensor
names is insufficient.

The planner must account for CPU/GPU staging, collective latency, actual bytes,
synchronization, memory peaks and phase-transfer costs. If separate decode
placement wins, move only a complete committed state and switch ownership
atomically. Losing a rank invalidates that collective epoch; continuing with
partial reductions is never a recovery strategy.

Study Exo and compare eligible implementations using reproducible workloads.
Use measured limitations to choose experiments. Superiority requires equivalent
artifact and workload comparisons, or an explicit account of differences.

## Opt-in product behavior

Distributed execution is disabled by default. A user explicitly creates a
cluster, selects its members and enables compatible models. Ordinary local
inference remains available independently.

Setup must identify compatible hardware/software, verify model/build identity,
check available memory, test the physical link, and complete a real collective
before declaring the cluster ready. Report actionable setup failures and make
the active execution mode visible. An unavailable RDMA backend must not silently
be presented as working RDMA through a different transport.

Network setup needs saved configuration, narrowly scoped changes, an independent
management path and verified rollback. Recovery-only RDMA enablement steps must
be explained before setup starts. Do not automatically disable a live management
interface or bridge during remote setup. Reboot, cable removal, peer loss and
reconnection must be tested before release; the development connectivity
incident makes recovery a first-release requirement.

Cluster membership requires explicit peer trust and authenticated control.
Prompt/state access by participating machines must be reflected in the existing
[privacy and encryption model](../architecture/security/encryption.md). Keep
credentials, private addresses and prompt content out of published diagnostics.
Protocol, security and accounting changes need coordinated integration rather
than claims that the experimental launcher already provides a production trust
boundary.

Bound deadlines and cancel all participating work when a rank fails. For future
requests, expose a clear unavailable state or choose an explicitly allowed local
plan. Retry an interrupted request only from a validated committed point, with
correct token accounting and no duplicate stream output.

## Execution milestones and completion

| Milestone | Evidence required to close it |
|---|---|
| 1. Reproducible development harness | Verified artifacts and runtime bundles; isolated solo and multi-process runs; strict report validation; deadlines and cleanup tested |
| 2. Dense model correctness | Qwen3.5 9B and Qwen3.8 27B partition parity, state continuity and shard-loading memory bounds; actual two-machine transport validated |
| 3. M3 Ultra performance | Measured operator and collective profiles, selected execution plan, and the primary benchmark meeting the acceptance target |
| 4. Reusable MoE support | Both named MoE families qualified through shared machinery, with explicit model-specific adapters and per-artifact performance evidence |
| 5. Opt-in release readiness | Provider integration, setup/rollback, peer failure and restart behavior, diagnostics, compatibility matrix, and local-mode regression checks |

The initial opt-in release can qualify the primary dense model first and add
qualified MoEs incrementally. Each advertised capability requires its own
evidence. Shipping a first model does not close the wider framework goal.

The goal remains active until the performance, reusability and product criteria
are demonstrated. If measurements miss the target, record the limiting work
and revise the implementation; do not replace the target with an estimate or
mark an unfinished milestone complete. Publishing a release is a separate
deployment action after the implementation is reviewable.

## Current evidence and related work

The isolated [cluster experiments](https://github.com/Layr-Labs/d-inference/blob/39ab57dc66da7d15dfeb4ba41fc4ceaf25e24433/experiments/cluster/README.md) contain
the native transport probe and inference harness. Prototype success is narrower
than qualification: local synthetic partition parity has passed, while
successful two-machine RDMA inference and M3 Ultra throughput remain unproven.
An unavailable development peer currently limits physical two-machine checks;
offline implementation and correctness work can continue.

Production behavior is documented in
[inference architecture](../architecture/inference.md). Existing
[model acceptance work](release-090-acceptance.md) and
[Gemma optimization design](gemma4-26b-inference-optimization.md) provide related
constraints; they do not establish distributed support.
