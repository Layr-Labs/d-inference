# Provider Model Autopilot: Problem Statement

## Objective

Darkbloom needs a default-on model autopilot that turns a heterogeneous,
intermittently connected provider fleet into useful model capacity without
requiring each operator to predict demand manually.

An operator should choose how much local storage Darkbloom may use for model
artifacts. The system should then decide which compatible models to download,
retain, load, serve, unload, and evict. Operators must be able to opt out and
pin the provider to one model.

The coordinator must continuously align fleet capacity with observed and
unserved demand while respecting every provider's storage, memory, hardware,
software-version, trust, and availability constraints.

## Fundamental Constraints

1. **Disk capacity is not serving capacity.** Downloaded models are candidates;
   only models loaded into memory and admitted by the provider's live memory
   gate can serve requests.
2. **The fleet is ephemeral.** Any assignment may disappear at any time, so
   useful capacity requires redundancy across failure domains and must not
   depend on every targeted provider being online.
3. **Demand is noisy and partially censored.** Completed requests reveal served
   demand, while queueing, rejections, and capability mismatches reveal demand
   the current fleet could not serve. Planning from completions alone reinforces
   shortages.
4. **Model movement is expensive.** Downloads and loads operate on much slower
   timescales than request routing. A control loop must use hysteresis,
   cooldowns, minimum residency, and bounded concurrency to avoid oscillation,
   bandwidth spikes, and synchronized fleet churn.
5. **Providers are heterogeneous.** A valid assignment must satisfy model
   artifact size, required provider version, architecture, memory, trust,
   capability, and operator-policy constraints before it is issued.
6. **Commands cross an unreliable boundary.** Desired state must be durable,
   versioned, idempotent, lease-based, observable, and reconciled against
   provider-reported actual state. A transient disconnect cannot turn an old
   command into permanent intent.
7. **Global optimization belongs at the coordinator; local safety belongs at
   the provider.** The coordinator can observe aggregate demand and fleet
   supply. The provider alone can enforce disk limits, verify artifacts, protect
   local memory, serialize downloads, and reject unsafe work.
8. **Privacy is invariant.** Planning may use model IDs, aggregate token demand,
   queue outcomes, timings, and coarse capacity data. It must never collect
   prompt or completion content.
9. **Utilization is not the same as busyness.** The goal is to maximize useful,
   reliable served demand per unit of fleet capacity, not to force every machine
   to load a model or churn artifacts when spare capacity has no demand.

## Required Behavior

### Provider operator experience

- Autopilot is enabled by default.
- The operator sets a model-storage budget in GiB.
- The provider exposes downloaded, downloading, loaded, assigned, and evictable
  model state plus budget usage.
- The operator can disable autopilot and pin exactly one model.
- Existing installations receive a safe default budget derived from available
  disk, with a reserve that Darkbloom never consumes.
- Local policy remains authoritative: the provider rejects assignments that
  exceed its current safety limits and reports a structured reason.

### Fleet control

- The coordinator measures served demand and unmet demand per model over rolling
  windows.
- It estimates warm capacity, cached capacity, compatible online capacity, and
  recent provider availability.
- It computes per-provider desired model sets rather than sending an ambiguous
  fleet-wide broadcast.
- It preserves baseline replicas for enabled models, allocates additional
  replicas where marginal demand justifies them, and removes excess capacity
  gradually.
- It prefers assignments that avoid downloads, fit memory, improve failure
  diversity, and minimize disruption to active requests.
- It accounts for provider and model compatibility, including minimum provider
  versions, before assignment.
- It reconciles desired and actual state after reconnects, heartbeats, planner
  runs, configuration changes, command failures, and lease expiry.

### Provider execution

- The provider validates each desired-state revision against the signed model
  registry and local policy.
- It downloads with bounded concurrency, resumability, integrity verification,
  atomic publication, and explicit temporary-space accounting.
- It never evicts a pinned, loaded, active, or newly downloaded minimum-residency
  model.
- It evicts only enough eligible least-valuable artifacts to satisfy the storage
  budget.
- It loads and unloads through the existing slot and unified-memory safety
  mechanisms; autopilot cannot bypass them.
- It reports progress and terminal outcomes so the coordinator can replan rather
  than waiting indefinitely.

## Inputs

- Per-model served requests, input tokens, requested output tokens, observed
  output tokens, queue time, service time, and failures.
- Per-model unmet requests, including no-compatible-provider, queue timeout, and
  admission rejection outcomes.
- Registry metadata: artifact bytes, memory requirements, capabilities, trust
  requirements, and minimum provider version.
- Provider metadata: provider version, hardware and memory, free-for-load
  capacity, model slots, storage budget and usage, cached models, current
  downloads, trust, current assignments, and coarse availability history.
- Operator policy: autopilot enabled or disabled, storage budget, and pinned
  model.
- Control-loop state: assignment revision, lease, cooldown, residency, command
  outcome, and recent movement cost.

## Outputs

- A durable, revisioned desired model set for each provider.
- Reconciliation commands or protocol messages carrying assignment revision and
  lease information.
- Provider-reported execution status and rejection reason per model.
- Aggregate privacy-safe metrics for planner decisions, movement, convergence,
  unmet demand, and assignment failures.
- Operator-visible configuration and current state.

## Safety and Correctness Invariants

- Storage managed by Darkbloom never exceeds the configured budget after a
  reconciliation cycle; temporary download bytes are reserved before transfer.
- User-pinned artifacts and models in active use are never automatically
  evicted.
- A provider never executes an assignment requiring a newer provider version or
  unsupported hardware/capability.
- A stale assignment revision cannot overwrite a newer one.
- Planner retries and duplicate messages are harmless.
- A planner outage leaves currently useful capacity serving; it does not trigger
  mass unloads.
- A provider disconnect or missed lease cannot silently count as available
  capacity.
- Demand telemetry contains no user content.
- Every autonomous action has a machine-readable reason and outcome.
- Disabling autopilot converges the provider to its pinned-model policy without
  interrupting an in-flight request.

## Success Criteria

- Providers can configure a storage budget and single-model opt-out through the
  supported CLI and coordinator-facing state.
- A real provider can receive desired state, download a compatible model, report
  progress, load it through existing safeguards, and later evict it safely.
- The coordinator allocates replicas from both served and unmet demand, remains
  stable under bursty traffic, and avoids herd behavior in deterministic
  simulations.
- Reconnects, stale revisions, partial downloads, insufficient disk, incompatible
  versions, load failures, and planner restarts converge without unsafe state or
  manual database repair.
- Unit, protocol-symmetry, integration, and trace-driven simulation tests pin the
  control loop and provider state-machine behavior.
- Operators and maintainers can observe why an assignment was made, whether it
  converged, and why it failed without exposing inference content.

## Scope Boundary

This goal adds model placement, artifact lifecycle automation, reconciliation,
configuration, and observability. It reuses the existing request scheduler,
model registry, verified downloader, model-slot lifecycle, and unified-memory
gate. It does not replace request routing, weaken attestation, invent a second
model catalog, or mutate deployed infrastructure.

Existing mechanisms named here are implemented in
`coordinator/registry/warm_pool_controller.go`,
`coordinator/registry/scheduler.go`,
`coordinator/api/model_registry_handlers.go`,
`provider-swift/Sources/ProviderCore/Models/ModelDownloader+Prefetch.swift`,
`provider-swift/Sources/ProviderCore/Server/ModelPrefetchCoordinator.swift`,
`provider-swift/Sources/ProviderCore/ProviderLoop+ModelLoading.swift`, and
`provider-swift/Sources/ProviderCore/Inference/UnifiedMemoryCap.swift`.
