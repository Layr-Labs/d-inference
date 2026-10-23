# Provider Autopilot

> Last updated: 2026-10-23

Provider Autopilot offers an external controller the models of a Mac whose
operator saved Autopilot consent: the saved selection plus every verified
catalog build in the local cache, which a controller can grow by downloading
catalog builds on the operator's behalf. Interest or shadow enrollment does not
authorize live control, higher earnings or relaxed memory limits.

## Mechanism

`ModelAutopilotSettings` in
`provider-swift/Sources/ProviderCore/Autopilot/ModelAutopilotSettings.swift`
owns consent and the persisted selection. Ordinary startup selection remains
separate. The provider publishes typed snapshots, validates control leases and
rechecks actual work, pins, inventory and memory before changing residency.

| Responsibility | Provider source |
|---|---|
| Control lifecycle, expiry and clearing | `provider-swift/Sources/ProviderCore/Autopilot/ProviderLoop+AutopilotControl.swift` |
| The Autopilot model set and its eligibility rules | `provider-swift/Sources/ProviderCore/Autopilot/AutopilotModelSet.swift`, `ProviderLoop+AutopilotModelSet.swift` and `AutopilotStartInventory.swift` in the same directory |
| Downloads on the operator's behalf | `provider-swift/Sources/ProviderCore/Autopilot/AutopilotDownload.swift`, `ProviderLoop+AutopilotDownload.swift` and `AutopilotDownloadLedger.swift` in the same directory |
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

## The Autopilot model set

With saved consent, every Autopilot gate uses one set, reported as
`selected_models`: the persisted selection plus every verified catalog build in
the local cache that this Mac can run (`autopilotModelSet`,
`autopilotSetAllows`). The policy target and victim checks, serving
(`autopilotAllowsModel`), inventory restoration, adoption, holds and the
registration inventory all read it. No consent step, prompt or revision change
widens it; the saved opt-in is the gate. Without consent, or on a
`private_only` Mac, the report is the persisted list exactly as before.

A cached build qualifies under the opt-in picker's default-selection rules
(`AutopilotBuildEligibility`): an active catalog build, the catalog RAM floor
and runtime capabilities met, a supported engine family, a footprint inside the
load budget, and a reportable ID (1 to 256 bytes of visible ASCII). It is
verified when its weight hash is the catalog's current `weight_hash` (or the
manifest aggregate). The start path checks this with its single weight-hash pass
(`AutopilotStartInventory`, used by `runForeground`). Pins stay a subset of the
persisted selection, so they are a subset of the set.

| Event | Effect on the set |
|---|---|
| Daemon start with the catalog | Every verified current catalog build in the cache joins |
| Daemon start without the catalog | A build recorded in `autopilot-downloads.json` joins while its bytes still hash to the recorded value |
| Next scheduled window | Builds verified at start or recorded stay while their bytes are unchanged (`ScheduledWindowSelection`) |
| A verified Autopilot download | Joins, persisted in the ledger |
| An ordinary prefetch verifies a build | Joins with its advertisement (`publishVerifiedPrefetch`) |
| A build is superseded or its files disappear | Leaves (`dropAdvertisedBuild`; `sweepAutopilotCachedBuilds`, once a minute, never for a saved, resident, loading or ordinary build) |

The union is capped at 256 IDs, persisted selection first, because the
coordinator fences a machine whose report exceeds its bounds. Changes never
touch the consent `revision`, so a live lease or accepted operation stays
valid. The coordinator learns inventory metadata (`ModelInfo`) only from
`register.autopilot_inventory`: a build added at runtime appears in the next
heartbeat's `selected_models`, and the provider re-registers once
(`refreshAutopilotInventoryRegistration`, a planned reconnect) on the first
capacity tick with no busy reason and no operation. A busy provider keeps
waiting rather than interrupting work; a registration made for any other reason
also ends the wait (`registeredAutopilotInventoryIDs`).

## Downloads on the operator's behalf

With saved consent, a `prefetch_model` for a build outside ordinary serving is
a download into the set (`handleAutopilotDownloadRequest`). It reuses the
ordinary resumable, manifest-verified prefetch on a separate prefetch
coordinator (`autopilotDownloadCoordinator`), replies `started`, `downloading`
and a terminal `verified` or `failed`, and never advertises, loads or deletes
anything; a later Autopilot operation may load the build. Serving is never
fenced for a download. Without consent the reply stays `model_not_selected`.

| Step | Check | Refusal (`AutopilotDownloadRefusal`) |
|---|---|---|
| Request | Autopilot not paused | `autopilot_paused` |
| Request | Reportable ID, runtime capabilities | `model_not_supported` |
| Download task | Catalog and manifest fetched | `catalog_unavailable` |
| Download task | Active catalog build with a manifest, RAM floor, capabilities | `model_not_supported` |
| Download task | Disk guard: free space minus the download keeps `autopilot_download_reserve_gb` (default `AutopilotDiskGuard.defaultReserveGiB = 50` GiB) | `insufficient_disk` |
| Download task | Transfer and verification | `download_failed` |
| Publication | Scan and weight hash, supported family, load budget, no failed self-test | `download_failed`, `model_not_supported` |
| Publication | Consent still saved and not paused | `model_not_selected`, `autopilot_paused` |

A build already in the set with a verified hash answers `verified` without a
download. A verified download is recorded in `autopilot-downloads.json` beside
the config (`AutopilotDownloadLedger`: model, weight hash, time, owner-only),
so a restart keeps it and a future cleanup can tell it from the operator's own
downloads.

## Placements after an operation

A coordinator may grant a live lease only for one operation. A succeeded
operation's placement then outlives that lease in two per-model forms, recorded
by `recordAutopilotPlacement` before the command releases ownership:

| Placement | Recorded when | Effect | Ends when |
|---|---|---|---|
| Adoption | The target is cached inventory: in the Autopilot set, outside ordinary serving | `autopilotServesModel` admits it to network, local and `load_model` serving without a lease; `withdrawInactiveAutopilotModels` keeps it advertised | The slot leaves residency for any reason; consent is revoked, Autopilot disabled or the model leaves the Autopilot set; a failed self-test, retirement or unverifiable weight hash; shutdown |
| Hold | The command carries `hold_seconds` above zero | LRU eviction (`evictableModelSlots`) and idle unload skip the slot until expiry; afterwards the idle timeout restarts at the expiry; `free_for_load_gb` gives its weights no reclaim credit | Expiry; any end of the adoption basis above; the model stops being advertised; an operation unloads it |

`reconcileAutopilotPlacements` enforces the end conditions before every snapshot
and when an unload removes a slot, then withdraws newly unadopted inventory.
Adoption grants serving only. Verified publication, desired-build and revision
changes still need the ordinary selection or a live lease
(`autopilotAllowsModel`); a prefetch outside them is a download into the set. A
local pause, a pending inventory refresh or a new consent revision that keeps
the model in the set does not end an adoption. A later
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
each occurrence of a bounded transition (`ModelAutopilotTransition.stallBound`).
Each load, startup candidate, advertisement and model switch is its own
occurrence (`TransitionGenerations`), so a retry that starts between two ticks
does not inherit the previous age. The capacity monitor starts only after the
startup preload gate, but a startup candidate is aged from when it began
(`markStartupPreloadReached`): one that has already outlived its bound stalls at
the first observation. The watchdog never runs during the gate itself.

| Transition | Bound | On stall |
|---|---|---|
| `autopilot_operation` | 600 s | Cancel the operation; it fails as `transition_stalled`, records no lease or placement, and keeps any unload or load that completed after the cancellation |
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

1. Consent off reports no placement, busy, watchdog or capability fields,
   reports the persisted `selected_models` exactly, records no placement and
   downloads nothing; serving and residency are unchanged
   (`ProviderLoop.publishModelAutopilotSnapshot`, `superviseTransitions`,
   `handlePrefetchModelRequest`).
2. Only a succeeded operation's resident target is adopted or held
   (`recordAutopilotPlacement`).
3. No placement outlives consent, selection, residency or a verified build: a
   live weight hash (`liveModelHashes`, cleared by `markWeightHashUnavailable`)
   and no failed self-test. This applies to holds on ordinary models too
   (`reconcileAutopilotPlacements`).
4. An expired hold protects nothing (`autopilotHoldsModel`).
5. The watchdog clears no load, admission, drain or reconnect flag and
   interrupts nothing but a stalled operation; untracking a preload removes only
   the coordinator's handle. An owner that may still allocate memory keeps its
   fence (`resolveStalledTransition`).
6. `provider_busy` reasons are exactly the policy's busy conditions
   (`autopilotBusyReasons`).
7. The set holds at most 256 IDs, keeps the whole persisted selection, adds
   only reportable verified catalog builds and never changes the consent
   `revision` (`AutopilotModelSet.effective`, `AutopilotStartInventory`).
8. A download never advertises, loads or deletes a build and never fences
   serving; every refusal is a closed code (`AutopilotDownloadRefusal`,
   `publishAutopilotDownload`).

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
- An unreachable catalog at start leaves only the persisted selection and the
  recorded downloads in the set until the next start.
- Until the provider re-registers, a coordinator sees a newly downloaded build
  only as an ID in `selected_models`; operations on it are refused as not
  cached. A provider that is never idle keeps waiting.
- A build at the 256-ID bound downloads but stays out of the set and its
  download reports `model_not_supported`.

## External Policy

Machine selection, demand planning, rewards, accounting and rollout controls
belong to [platform Autopilot](https://github.com/Layr-Labs/darkbloom-platform/blob/48a198c71a2d30feec5597bacf1101120f7f955d/docs/architecture/model-autopilot.md).
Do not administer those systems by reintroducing backend code here. Wire changes
require coordinated review; fixed provider fixtures alone do not qualify live
controller behavior or a production cohort. A coordinator uses adoption, holds
and downloads only for providers reporting the matching `capabilities`
(`inventory_adoption`, `placement_holds`, `inventory_downloads`).

## Related

- [CLI settings](../provider/cli-reference.md)
- [Configuration](../reference/configuration.md)
- [Protocol](../reference/protocol-messages.md)
- [Memory safeguards](hardware-support.md)
