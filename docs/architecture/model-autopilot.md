# Provider Autopilot

> Last updated: 2026-10-23

Provider Autopilot offers explicitly consented cached models to an external
controller. Interest or shadow enrollment does not authorize live control,
downloads, higher earnings or relaxed memory limits.

## Mechanism

`ModelAutopilotSettings` in
`provider-swift/Sources/ProviderCore/Autopilot/ModelAutopilotSettings.swift`
owns consent and selected-model eligibility. Ordinary startup selection remains
separate. The provider publishes typed snapshots, validates control leases and
rechecks actual work, pins, inventory and memory before changing residency.

| Responsibility | Provider source |
|---|---|
| Control lifecycle, expiry and clearing | `provider-swift/Sources/ProviderCore/Autopilot/ProviderLoop+AutopilotControl.swift` |
| Command policy and terminal results | `provider-swift/Sources/ProviderCore/Autopilot/ProviderLoop+Autopilot.swift`, `ModelAutopilotPolicy.swift` in the same directory |
| Cached target preparation and ordinary load safeguards | `provider-swift/Sources/ProviderCore/Autopilot/ProviderLoop+AutopilotInventory.swift` |
| Adoption and placement holds after an operation | `provider-swift/Sources/ProviderCore/Autopilot/ProviderLoop+AutopilotPlacement.swift` |
| Busy reasons | `provider-swift/Sources/ProviderCore/Autopilot/ProviderLoop+AutopilotBusy.swift` |
| Stuck-transition watchdog | `provider-swift/Sources/ProviderCore/Autopilot/TransitionWatchdog.swift`, `ProviderLoop+TransitionWatchdog.swift` in the same directory |
| Load-time history | `provider-swift/Sources/ProviderCore/Autopilot/ModelAutopilotHistory.swift` |

Failed or expired control cannot manufacture ownership of accepted work.
Cancellation, disconnect and shutdown must preserve native retirement and
restore ordinary serving eligibility only through the existing lifecycle.
Files already on disk are not evidence that a model can load safely.

## Placements after an operation

A coordinator may grant a live lease only for one operation. A succeeded
operation's placement then outlives that lease in two per-model forms, recorded
by `recordAutopilotPlacement` before the command releases ownership:

| Placement | Recorded when | Effect | Ends when |
|---|---|---|---|
| Adoption | The target is cached inventory: selected, outside the ordinary selection | `autopilotServesModel` admits it to network, local and `load_model` serving without a lease; `withdrawInactiveAutopilotModels` keeps it advertised | The slot leaves residency for any reason; consent is revoked, Autopilot disabled or the model deselected; a failed self-test, retirement or unverifiable weight hash; shutdown |
| Hold | The command carries `hold_seconds` above zero | LRU eviction (`evictableModelSlots`) and idle unload skip the slot until expiry; afterwards the idle timeout restarts at the expiry; `free_for_load_gb` gives its weights no reclaim credit | Expiry; any end of the adoption basis above; the model stops being advertised; an operation unloads it |

`reconcileAutopilotPlacements` enforces the end conditions before every snapshot
and when an unload removes a slot, then withdraws newly unadopted inventory.
Adoption grants serving only. Prefetch, verified publication, desired-build and
revision changes still need the ordinary selection or a live lease
(`autopilotAllowsModel`). A local pause, a pending inventory refresh or a new
consent revision that keeps the model selected does not end an adoption. A later
operation's `hold_seconds` replaces the target's earlier hold; an absent or zero
value leaves it. Placements live in memory: a provider restart restores the
operator's ordinary selection and idle policy.

Neither form is machine-level control. The idle timer keeps running, other
models keep their ordinary idle and eviction policy, and cold loads into free
memory proceed. A load that would have to evict a held slot fails with the
existing transient slot or insufficient-memory refusal.

## Busy reasons and stalled transitions

`autopilotBusyReasons` names every condition behind `provider_busy`. It is empty
exactly when the operation policy's busy input is false. A `provider_busy`
status carries the first reason as `detail`, and consented snapshots report the
reasons and their age ([protocol](../reference/protocol-messages.md#model_autopilot-state)).

`superviseTransitions` runs on the capacity tick while consent is saved. It ages
each occurrence of a bounded transition (`ModelAutopilotTransition.stallBound`):

| Transition | Bound | On stall |
|---|---|---|
| `autopilot_operation` | 600 s | Cancel the operation; it fails as `transition_stalled` |
| `startup_preload` (per candidate) | 600 s | Stop the driver before its next candidate |
| `preload` (per coordinator `load_model`) | 600 s | Answer `failed` with `transition_stalled` and stop tracking the task |
| `model_loading`, `model_advertisement`, `model_switch` | 600 s | Report only |
| `reslice`, `reconnect_after_retirement` | 300 s | Report only |

Every stall increments `transition_stalls` and logs `transition_stalled`. Only
an operation is interrupted: it excludes every other load and admission, and its
own failure path releases its flags and pending-load reservation. A preload or
the startup driver can own a load that other requests wait on, and cancelling it
would fail those requests and discard a slow but healthy load. The watchdog
therefore answers the coordinator and lets a new `load_model` start afresh, or
stops the driver at its next candidate, and the current step finishes normally.

## Invariants

1. Consent off reports no placement, busy or watchdog fields and records no
   placement; serving and residency are unchanged
   (`ProviderLoop.publishModelAutopilotSnapshot`, `superviseTransitions`).
2. Only a succeeded operation's resident target is adopted or held
   (`recordAutopilotPlacement`).
3. No placement outlives consent, selection, residency or a verified build
   (`reconcileAutopilotPlacements`).
4. An expired hold protects nothing (`autopilotHoldsModel`).
5. The watchdog clears no load, admission, drain or reconnect flag and
   interrupts nothing but a stalled operation; untracking a preload removes only
   the coordinator's handle. An owner that may still allocate memory keeps its
   fence (`resolveStalledTransition`).
6. `provider_busy` reasons are exactly the policy's busy conditions
   (`autopilotBusyReasons`).

## Failure modes

- A wedged native load or bridge shutdown ignores cancellation. Its flags stay
  set and keep refusing operations; the stall is reported, not cleared.
- Deliberate retentions (unproven GLM or MiMo native work, a failed revision
  restore, a timed-out lifecycle drain) stay busy until their own recovery or a
  restart. `native_memory_retained`, `revision_update` and `draining` name them.
- A restart drops adoptions and holds. Startup preload skips unadvertised
  inventory, so adopted inventory is not reloaded; the operator's ordinary
  selection and idle policy apply.
- A healthy operation slower than its bound is cancelled and can be retried. A
  slow preload is answered as failed even if it later warms the model, which then
  appears in heartbeats; the startup preload skips its remaining models.

## External Policy

Machine selection, demand planning, rewards, accounting and rollout controls
belong to [platform Autopilot](https://github.com/Layr-Labs/darkbloom-platform/blob/48a198c71a2d30feec5597bacf1101120f7f955d/docs/architecture/model-autopilot.md).
Do not administer those systems by reintroducing backend code here. Wire changes
require coordinated review; fixed provider fixtures alone do not qualify live
controller behavior or a production cohort. A coordinator uses adoption and
holds only for providers reporting the matching `capabilities`.

## Related

- [CLI settings](../provider/cli-reference.md)
- [Configuration](../reference/configuration.md)
- [Protocol](../reference/protocol-messages.md)
- [Memory safeguards](hardware-support.md)
