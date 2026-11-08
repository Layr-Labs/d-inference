# Owner pause ("me first")

> Last updated: 2026-11-08

How a provider that serves Darkbloom and its owner from one Mac stops taking
Darkbloom work while the owner uses the Mac through its local API, and returns
once the owner is idle. This explanation is for provider developers; the wire
fields are in the [protocol reference](../reference/protocol-messages.md#add-on-hold-busy-fields).

## Context

A provider serving **Both, me first**, its local API beside Darkbloom, shares one engine and one KV
budget between the owner's requests and Darkbloom's. The owner pause gives the
owner the Mac: Darkbloom work stops arriving while the owner uses it, nothing
that has started answering is cut, and the Mac goes back to Darkbloom on its
own.

It uses only signals coordinators already honour, so it needs no coordinator
change. A `draining` heartbeat takes the Mac out of routing and keeps its
uptime. The typed refusal `capacity / 503 / error_reason draining` fails a
racing request over without spending a retry or derating the Mac.

The pause is not an [add-on hold](addon-hold.md). It keeps every model loaded
and admits local requests. It cancels only Darkbloom work that hasn't sent
output, while one of the owner's requests waits for it
([when the owner's request waits](#when-the-owners-request-waits)).

## Mechanism

```mermaid
stateDiagram-v2
  [*] --> Open
  Open --> Paused: a local request starts
  Paused --> Paused: a local request starts or ends
  Paused --> Open: no local request in flight for the idle time
```

`MeFirstPolicy` (`provider-swift/Sources/ProviderCore/Service/MeFirstPolicy.swift`)
is the pure state machine: a count of local requests in flight, when the pause
began and when the owner's last request started or ended, on a millisecond
clock the caller supplies. `ProviderLoop+MeFirst.swift` in
`provider-swift/Sources/ProviderCore/` owns one per serving process:

| API | Behaviour |
|---|---|
| `enableMeFirst(idle:)` | Turns the pause on with the owner's idle time (`[local] me_first_idle_minutes`, 2 minutes by default). The first call wins; a changed setting applies at the next start. The local API calls it as it starts, where me first applies (below); a pair's leader enables it from `[local]` ([pairs](#pairs)). |
| `noteLocalUse(.start)` | A local request acquired a model: `acquireModelForLocal` calls it right after taking the request's reservation (on a pair's leader, `noteClusterPairLocalUse`). The first one pauses Darkbloom work. |
| `noteLocalUse(.end)` | It released the model: `releaseLocalReservation` calls it when it drops that reservation. The end of the last one starts the idle countdown. Every start is paired with one end; an unmatched end changes nothing. |
| `resumeIfOwnerIdle()` | Ends the pause once the idle time has passed. The resume timer calls it. A fresh coordinator connection makes the same check before its first heartbeat (`reassertOwnerPauseAfterReconnect`). On a pair's leader the member beat calls it too. |
| `meFirstSnapshot` | What `status` reads (`DaemonState.meFirst`). |

While paused:

| Concern | Behaviour |
|---|---|
| Heartbeat | `status: draining`, `busy_reason: owner`, `busy_since_ms` (`ProviderState.ownerPausesPublic`, `refusingDarkbloomWork`). An event heartbeat goes out when the pause begins |
| Coordinator inference | The typed `capacity / 503 / draining` refusal (`rejectIfDraining`), once per racing request |
| `load_model`, `prefetch_model` | The drain failures, which coordinators retry later. A coordinator preload never evicts the model the owner is using |
| Autopilot commands | Busy, with reason `draining` |
| Capacity quotes | Refused with `slot_state` |
| `desired_models` | Deferred; replayed when the pause ends |
| Darkbloom work accepted before the pause | Finishes once it has sent output. While one of the owner's requests waits in the same engine's queue, work that has sent nothing gives way ([below](#when-the-owners-request-waits)) |
| Local requests and models | Admitted and kept as usual |
| A fresh registration | `register` carries the owner's busy fields, and the connection's first event heartbeat repeats the draining status. A pause whose idle time passed while the connection was down ends first, so that one heartbeat says `idle` or `serving` |

When the idle time has passed with no local request in flight, the provider
clears the flag, sends an `idle` or `serving` event heartbeat, and replays the
deferred `desired_models`.

### Where it applies

`startLocalEndpoint` (`provider-swift/Sources/ProviderCore/ProviderLoop+LocalEndpoint.swift`)
calls `enableMeFirstIfConfigured` before the endpoint can take a request. It
turns me first on with the idle time `ProviderLoopConfig.meFirstIdle` gives,
which reads `[local]` from the loaded config through
`LocalSettings.meFirstIdle(local:localEndpoint:)`
(`provider-swift/Sources/ProviderCore/Config/LocalSettings.swift`):

| Provider | Me first |
|---|---|
| Both, me first (`start --me-first` or `--local-endpoint`): the local API beside the coordinator | On, mode `both`, unless `[local] me_first = false`; idle `me_first_idle_minutes` (default `2`) |
| The same with `[local] me_first = false`, or a saved `mode` other than `both` | Off: local and Darkbloom requests share the Mac, and the heartbeat is unchanged |
| Darkbloom network (plain `start`, `--network`), and a cluster member without the pair's slot | Off: no local API |
| A pair's leader with its local API beside Darkbloom | See [pairs](#pairs) |
| Only me (`start --local`, `StandaloneServer`) | None: no coordinator, so no `ProviderLoop` and nothing to pause |

With no `[local]` section it is on, so a Mac that already served with
`--local-endpoint` before this change pauses from its first start after the
update. That includes the desktop app's "Alongside the network" (Both, me
first), which starts the provider with `--local-endpoint`. To turn it off,
start once with `--no-me-first`, which saves `me_first = false` under `[local]`
in `provider.toml` (`~/.config/darkbloom/provider.toml`): the setting is read
when the provider starts.

### What counts as use

The owner's use is the local request's model reservation: from the moment
`acquireModelForLocal` takes it until `releaseLocalReservation` drops it. The
request's `OneShotRelease` drops it exactly once, whether the request
completes, fails, is cancelled or its client disconnects. Every route that
uses a model goes through that acquisition, so no route list is kept:

| Request | Counts |
|---|---|
| Chat completions (streamed or not), completions, responses and the batch route, including Nemotron Super's managed chat | Yes, while it holds the model; a stream holds it until its last token |
| A request refused after it took the model, such as an invalid `tool_choice` | Yes, briefly |
| A request refused before it holds a model: a model this Mac does not serve (404), a load refused (429), a drain or shutdown, or cancelled while its model loads | No |
| `/v1/models`, `/models`, `/health`, `/v1/health`, `/props`, `/metrics`, `/tokenize`, `/detokenize`, `/apply-template` | No: they hold no model |
| The startup self-test decode | No: it reserves the model directly, without the hooks |

### When the owner's request waits

The owner's request shares the engine and its KV memory with Darkbloom work
accepted before the pause. When the engine has no room for it, Darkbloom work
on that model that hasn't sent output gives way, and work that has sent output
finishes:

```mermaid
sequenceDiagram
  participant Owner as Owner's request
  participant Bridge as EngineV2Bridge
  participant Loop as ProviderLoop
  participant Coord as Coordinator
  Owner->>Bridge: submitted, waits in the engine's queue
  Bridge->>Bridge: still waiting two engine steps later
  Bridge->>Loop: giveWayToOwner(model)
  Loop->>Coord: capacity / 503 / draining, for each request with no output
  Note over Coord: served on another Mac, before anything reaches its client
  Note over Bridge: their memory frees and the owner's request runs
```

| Step | Behaviour |
|---|---|
| Who asks | The owner's request on a Mac with me first on: `acquireModelForLocal` gives its `AcquiredModel` (and Nemotron Super's lease) an `ownerWaits` closure, which the local engine binds (`MeFirstOwnerRequest.waits`) around the call that submits it. Coordinator requests, shared mode and Only me have none |
| When | `EngineV2Bridge.watchOwnerWait` (`provider-swift/Sources/ProviderCore/Inference/Engine/Bridge/EngineV2Bridge+OwnerWait.swift`) looks every 250 ms until the request's first token. No engine signal says that one request was admitted, so the bridge infers it. The engine admits waiting requests in arrival order (every request has the same priority), so a request waits while the engine's published waiting count is larger than the number of the bridge's live requests submitted after it. That count is published after each engine step and counts a request from its submission. The request asks only once it has stayed waiting across two steps, so one the engine admits at its next step never asks. A preempted request, requeued at the front, also reads as waiting: the inference errs toward giving way |
| Who gives way | `giveWayToOwner(modelId:)` (`ProviderLoop+MeFirst.swift`): each Darkbloom request on that model that has sent no output (`InferenceCancellationToken.yieldToOwner`), whether queued, in its prompt or generating output it hasn't sent yet. It is cancelled as a coordinator cancel would be (`handleCancellation`) |
| What it sends | One terminal: `capacity / 503 / error_reason draining`, the refusal a racing dispatch gets (`ownerYieldFailure`). A request that gave way before its stream started sends it from the handler |
| What never gives way | A request that has sent output. Its task claims the token before it sends its first content, reasoning or tool-call frame (`claimOutput`), and a request that gave way can't claim it, so it sends nothing after its refusal |

What the deployed coordinator does with that refusal, read in its code at
`d7de2162f2`:

- It serves the request on another Mac before anything reaches the client.
  Until the first content frame, the dispatch waits in `FirstWait` or
  `AcceptedWait`, where an error retries on another provider with this one
  excluded and drops the held role preamble
  ([first_wait.go](https://github.com/Layr-Labs/darkbloom-platform/blob/d7de2162f2097fc9f47ae469e7933db1121482b2/coordinator/internal/inference/attempt/first_wait.go#L121-L135),
  [accepted_wait.go](https://github.com/Layr-Labs/darkbloom-platform/blob/d7de2162f2097fc9f47ae469e7933db1121482b2/coordinator/internal/inference/attempt/accepted_wait.go#L72-L79)).
  The client's response is written only after first content commits
  ([dispatch.go](https://github.com/Layr-Labs/darkbloom-platform/blob/d7de2162f2097fc9f47ae469e7933db1121482b2/coordinator/api/inference/dispatch.go#L878-L886)),
  and `inference_accepted` changes nothing. A draining refusal doesn't use the
  transient-capacity retry allowance
  ([retry/controller.go](https://github.com/Layr-Labs/darkbloom-platform/blob/d7de2162f2097fc9f47ae469e7933db1121482b2/coordinator/internal/inference/retry/controller.go#L125-L129)).
- It doesn't count against this Mac. A capacity-coded error records no failed
  job in the reputation
  ([provider_inference.go](https://github.com/Layr-Labs/darkbloom-platform/blob/d7de2162f2097fc9f47ae469e7933db1121482b2/coordinator/api/inference/provider_inference.go#L970-L979)).
  A draining reason returns before every health breaker, the stable-identity
  ejection and the capacity cooldown
  ([providerhealth/policy.go](https://github.com/Layr-Labs/darkbloom-platform/blob/d7de2162f2097fc9f47ae469e7933db1121482b2/coordinator/internal/inference/providerhealth/policy.go#L74-L83)),
  and the inference-error breaker counts only 500, 502 and 504
  ([error_cooldown.go](https://github.com/Layr-Labs/darkbloom-platform/blob/d7de2162f2097fc9f47ae469e7933db1121482b2/coordinator/internal/registry/identitygate/error_cooldown.go#L80-L85)).
  Base rewards and the Autopilot floor come from session coverage and
  earnings, not from request outcomes
  ([rewardpolicy/uptime.go](https://github.com/Layr-Labs/darkbloom-platform/blob/d7de2162f2097fc9f47ae469e7933db1121482b2/coordinator/internal/payments/rewardpolicy/uptime.go#L10-L40)).
  The attempt's route row reads `provider_error` with `admitted_but_failed`,
  which only analytics read, and its metrics class is `capacity`.

The owner's request then waits only for requests already answering,
Darkbloom's or the owner's own, up to the engine's 120 s admission lease;
after that it fails, as before. On a pair nothing gives way: a local request
waits for one of the pair's lanes ([pairs](#pairs)).

## Pairs

A pair served through Darkbloom has one owner pause, on its leader: the member
that hosts the pair's slot and runs the pair's local API beside Darkbloom
([the pair's leader takes local requests](inference.md#the-pairs-leader-takes-local-requests-beside-darkbloom)).
The rule is "the process that owns the local API owns the pause"
(`provider-swift/Sources/ProviderCore/ProviderLoop+ClusterPairMeFirst.swift`).

```mermaid
sequenceDiagram
  participant Owner as Owner's tool
  participant Leader as Leader member (slot and local API)
  participant Coord as Coordinator
  participant Member as Every other member
  Owner->>Leader: local request starts waiting for a lane
  Leader->>Coord: event heartbeat: draining, busy_reason owner
  Note over Coord: the pair is not routable; its session stays
  Coord--xLeader: racing dispatch
  Leader->>Coord: capacity / 503 / draining
  Owner->>Leader: last local request ends
  Note over Leader: 2 idle minutes (resume timer, member beat)
  Leader->>Coord: event heartbeat: idle or serving, no busy fields
  Note over Member: control-only draining heartbeat, unchanged throughout
```

| Concern | Behaviour |
|---|---|
| Turning it on | `darkbloom cluster` starts the leader's local API when the person chooses Both, me first: the cluster service adds `--local-endpoint --port --bind` to the rank-0 part (`ClusterLocalServing.memberArguments`). `prepareClusterMemberControl` calls `enableClusterPairMeFirstIfConfigured` once `run()` admits the leader's local API, before the API can take a request. It is on unless `[local]` says `me_first = false`, with `[local]`'s idle time. Whatever single-Mac `mode` `[local]` saved, a leader's local API beside Darkbloom serves both |
| The owner's use | `noteClusterPairLocalUse` forwards to `noteLocalUse` once per local request: from when it starts waiting for one of the pair's lanes, or takes one at once, until it leaves without one or releases it. So the pause begins before the request can wait behind Darkbloom work, and a request refused while the pair isn't serving never counts |
| Heartbeat | The leader's: `draining` with `busy_reason: owner`, beside its unchanged `cluster_session` |
| Racing dispatches | The leader's client forwards them while the slot exists, and `rejectIfDraining` refuses them with `capacity / 503 / draining` before they reach the pair |
| The idle time | The resume timer, and the member beat (`clusterMemberHeartbeat`, every 5 s), because a member runs no idle monitor. A stopping leader cancels the timer |
| Every other member | Untouched. It runs no local API, so nothing calls the hook and me first stays off; its heartbeat stays control-only `draining` with no busy fields |
| Ranks | Nothing counts them: the leader is the slot's host, a role, not a rank |
| `darkbloom cluster local` | Unchanged: no member loop and no coordinator, so nothing to pause |

What the deployed coordinator does with a draining leader:

- It stops routing to the whole pair, the owner's own `self` and `prefer`
  requests included.
- It keeps the pair's session: membership is an identity and trust decision,
  not an admission one, so a draining heartbeat never ends it.
- On the deployed coordinator, while a pair is paused for its owner, both Macs
  lose their base reward for the pause plus the 2 idle minutes, counted in
  5-minute periods, whereas a single Mac keeps it. `[local] me_first = false`,
  or choosing *Darkbloom network*, avoids that. In the coordinator at
  `90ee29fc0d`:
  - A member's base reward counts only the intervals in which its pair is
    publicly serving-ready
    ([coordinator/internal/payments/rewardpolicy/uptime.go](https://github.com/Layr-Labs/darkbloom-platform/blob/90ee29fc0d158dadbc0d87146526be1b3e4e9775/coordinator/internal/payments/rewardpolicy/uptime.go#L52-L84)).
  - Every member's heartbeat re-checks that
    ([coordinator/registry/heartbeat.go](https://github.com/Layr-Labs/darkbloom-platform/blob/90ee29fc0d158dadbc0d87146526be1b3e4e9775/coordinator/registry/heartbeat.go#L271-L276)),
    a draining leader fails it
    ([coordinator/registry/cluster_public_routing.go](https://github.com/Layr-Labs/darkbloom-platform/blob/90ee29fc0d158dadbc0d87146526be1b3e4e9775/coordinator/registry/cluster_public_routing.go#L229-L246)),
    and that closes every member's interval
    ([coordinator/registry/cluster_serving_intervals.go](https://github.com/Layr-Labs/darkbloom-platform/blob/90ee29fc0d158dadbc0d87146526be1b3e4e9775/coordinator/registry/cluster_serving_intervals.go#L49-L53)).
  - Base rewards settle every 5 minutes
    ([coordinator/internal/payments/rewardpolicy/epoch.go](https://github.com/Layr-Labs/darkbloom-platform/blob/90ee29fc0d158dadbc0d87146526be1b3e4e9775/coordinator/internal/payments/rewardpolicy/epoch.go#L14)),
    and a period under 90% coverage pays nothing
    ([coordinator/payments/baserewards/machine_candidates.go](https://github.com/Layr-Labs/darkbloom-platform/blob/90ee29fc0d158dadbc0d87146526be1b3e4e9775/coordinator/payments/baserewards/machine_candidates.go#L118),
    [coordinator/payments/baserewards/floor.go](https://github.com/Layr-Labs/darkbloom-platform/blob/90ee29fc0d158dadbc0d87146526be1b3e4e9775/coordinator/payments/baserewards/floor.go#L35-L40)).
  - A single Mac's own session counts whatever its status
    ([coordinator/internal/payments/rewardpolicy/uptime.go](https://github.com/Layr-Labs/darkbloom-platform/blob/90ee29fc0d158dadbc0d87146526be1b3e4e9775/coordinator/internal/payments/rewardpolicy/uptime.go#L90-L104),
    [coordinator/registry/heartbeat.go](https://github.com/Layr-Labs/darkbloom-platform/blob/90ee29fc0d158dadbc0d87146526be1b3e4e9775/coordinator/registry/heartbeat.go#L221-L224)).

## Cost

The pause is event-driven:

- A local request's start and end are O(1) updates of the policy: no I/O, no
  heartbeat, no task. They run in the same actor turn as the reservation and
  its release, once per request, never per token.
- Heartbeats go out only when the pause begins and ends, beside the usual
  baseline.
- The end of the pause writes the daemon state file at once. Its start doesn't:
  the start lands on the owner's request, and the loop already rewrites the
  file every 2 s while serving, so `status` shows the pause within 2 s, as it
  shows the request counts.
- The one timer is armed when the owner's idle time starts counting. It sleeps
  until the deadline, wakes at most once per idle time while the owner keeps
  working, and is gone once the pause ends.
- The coordinator and quote paths read one more flag under the lock they
  already take. Nothing runs per token.
- With me first off, `noteLocalUse` returns at once, and no timer or task exists.
- An owner's request on a Mac with me first on has one more timer, from its
  submission to its first token: every 250 ms it reads the engine's published
  counts and the bridge's live requests, and only while it waits does it ask
  Darkbloom work to give way. Coordinator requests have none.
- On a pair's leader, the member beat that already runs every 5 seconds adds
  one O(1) check, and the hook adds one call to each local request.

## Invariants

1. An add-on hold outranks the pause. While both apply, the busy fields
   describe the hold. Its release hands them back to the pause, which goes on
   (`publishBusy`, `ProviderBusy.publishing`).
2. Only the end of the last drain, hold or pause replays `desired_models`. An
   update, model switch or hold that ends during the pause leaves them
   deferred, and a pause that ends under a drain or hold leaves them to it
   (`replayDesiredModels`).
3. Local admission never reads the pause: `throwIfRefusingNewLocalWork` is
   unchanged, and `ProviderState.refusingNewWork` stays apart from
   `ownerPausesPublic`.
4. A clock that goes back restarts the countdown from the new time, so the
   pause outlasts the jump by one idle time at most.
5. The pause itself cancels nothing, and has no drain bound: Darkbloom work
   accepted before it that has sent output runs to the end, unlike under an
   add-on hold. Work that has sent no output gives way only while an owner's
   request waits in the same engine's queue, and then sends nothing more.
6. The pause belongs to the serving process and isn't saved, unlike an add-on
   hold. A restart or update during a pause comes back open, and the owner's
   next request pauses again.
7. A local request starts its use once and ends it once, however it ends.
   `acquireModelForLocal` and `releaseLocalReservation` call the hooks in the
   same actor turn as the reservation and its release. Nothing after the start
   throws or suspends, so the request always gets its `OneShotRelease`, which
   releases once; a release that drops no reservation ends no use.

## Known gaps

- **`darkbloom switch` during the pause can exit with an error, though the
  switch completes.** After a switch, the coordinator reopens routing only on
  an `idle` or `serving` heartbeat ([model replacement](../reference/protocol-messages.md#models_replace--models_replace_ack--models_replace_ready--models_replace_resumed)),
  and every heartbeat of the pause says `draining`. If the pause outlasts the
  provider's 30-second readiness wait (`resumeAfterModelSwitch`), `darkbloom
  switch` exits with the error "Model selection applied locally, but
  coordinator routing readiness is unconfirmed". The new selection is already
  serving locally, and the heartbeat that ends the pause reopens Darkbloom
  routing to it: nothing needs redoing.
- **Model revision activations and MTP idle upgrades** don't wait for the
  pause. They wait for an idle model, so one can start in a gap between the
  owner's requests.
- **The owner's own coordinator requests** (`X-Darkbloom-Route: self` or
  `prefer`) look like public work to the provider. They don't pause the Mac,
  and while it is paused they don't reach it: `self` waits (on today's
  coordinator up to 120 seconds, then `429 machine_busy`), and `prefer` goes
  to other Macs.

## Tests

`MeFirstPolicyTests` pins the edges on a fake clock, including an idle time of
one minute at 59.9 s and 60 s and the two-minute default at 119.9 s and 120 s.
`OwnerPauseLoopTests` drives the loop without a serve loop, and
`OwnerPauseWireTests` checks the heartbeats on the wire against the loopback
mock coordinator. These loop tests skip the capacity rebuild
(`capacityRebuildForTesting`), which reads MLX's Metal allocator, so they run
without the GPU.

`MeFirstSettingsTests` pins where me first applies. `LocalUseOwnerPauseTests`
checks that `startLocalEndpoint` turns me first on as `[local]` says, and
sends requests through the local API's own HTTP application
(`makeLocalEndpointApplication`) to a slot whose engine the test scripts:
the pause and the resume, refused requests and the routes that are not use,
`me_first = false` with the heartbeat compared byte for byte, one start and
one end per request however it ends, and nothing per token.

`MeFirstGiveWayTests` runs encrypted coordinator requests and an owner's
request through the local engine on a scripted two-request engine. Two network
requests run, one streaming and one in its prompt, and a third waits behind
them; then the owner's request waits too. The two that haven't answered get one
`capacity / 503 / draining` terminal each and send no output, the owner's
request runs, and the streaming one finishes untouched. With me first off,
nothing is re-routed. The coordinator requests' terminals read MLX's memory
counters, so the suite replaces that read (`terminalMemoryForTesting`) and runs
without the GPU.

`ClusterPairMeFirstTests` covers pairs with a scripted pair owner: the
leader's heartbeat, the racing refusal, work in flight, the member beat's two
minutes on a fake clock, a roster of three ranks, me first off and the cost.
Its two tests that complete Darkbloom requests need a Metal device, because
each request's terminal reads MLX's memory counters, but they submit no GPU
work.
