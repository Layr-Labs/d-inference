# No fixed session lifetime: rank lease, member grant lease, keep-warm

> 2026-10-10. Owner: "the 300 second lifetime should never have existed, nobody uses a model for just 300
> seconds"; "The models should only unload when we want it to and be ready for use or serving just like
> current darkbloom or other engines"; "pull from thundermlx on heartbeat items if it's there and latent metal
> keepwarm so no delay in requests".

A loaded two-Mac cluster model now stays resident and serving until an explicit unload or stop (operator,
`darkbloom stop`, an autopilot model switch) or a real failure. There is no fixed lifetime, no request count,
no idle unload and no rotation anywhere in the runtime, the worker, the owners or the provider.
"No orphaned memory" still holds: every process that holds a model holds a renewable lease, and the S00
last resorts (the JACCL guard, the forced exit with its wired-memory release and 20 s dead-man) are unchanged.

## What was removed

| Where | Removed |
|---|---|
| Capability record (`ClusterRuntimeCapability`) | `maxLifetimeSeconds` (1...300, 1...1800 for MiMo) and `maxRequests` (1...16), their validation bounds and the per-adapter `maximumLifetimeSeconds` |
| Adapters (Qwen, Gemma 4, GPT-OSS, MiMo), catalog | `maximumLifetimeNanoseconds`, `maximumRequests`; admissions bounded a load by a per-model lifetime and a request by the process deadline |
| Resident control, cohort lifecycle | the sixteen-request caps (`QwenResidentControl`, `QwenLayerStageResidentLifecycle`); replay protection is now a window of 4,096 recent IDs, never a count |
| Worker session protocol | the per-epoch request limit (`requestsPerEpoch`); a 4,096-ID replay window instead |
| Worker | its fixed lifetime (`--deadline-uptime-nanoseconds` is the lease's first grant, at most 120 s away); the 32 MB / 8 MB lifetime byte totals on its pipes |
| `ClusterWorkerPair` | `maximumRequests`, the lifetime check on readiness and the cap of a request's deadline at the workers' lifetime |
| Owner service / remote endpoint | the configured owner lifetime and the cap of a request's deadline at it |
| Installed session / local server | the 300 s lifetime, teardown at the deadline (`DistributedLocalServer+Monitoring`), rotation after sixteen requests (`DistributedLocalServer+Rotation`, removed), `httpSessionExhausted`, "remaining requests" |
| Member session | the 900 s cap on a grant |
| Status, console, CLI | "Lifetime remaining" and "admissions remaining"; replaced by requests served and keep-warm exchanges |

Rotation is removed rather than replaced by a key-epoch rekey: it existed only to replace a session that had
used its sixteen admissions or its 300 seconds. A rekey becomes necessary only when the authenticated record
channel (`ClusterRecordTransferAccounting`, per-direction record and byte limits) carries data-plane traffic,
which this build does not (the authenticated bootstrap is refused in `NativeWorkerRuntime`); that is the place
to add a key epoch, not the session.

## S03: the rank lease

Between a worker's owner and the worker. Renewed every 5 s, each renewal good for 30 s from its arrival
(`ClusterWorkerLease`).

- Armed before weights load: the worker arms `ProcessDeadline` on a `ClusterLeaseDeadline` whose first value is
  the launch deadline (at most 120 s away), before any native initialization.
- The worker's control reader starts at launch (`WorkerCoordinator.startReading`), not after readiness, so the
  owner's `extendDeadline` lines are read while the model loads. A renewal moves the deadline (never earlier) and
  re-arms the alarm. Any other input before readiness still ends the worker.
- `extendDeadline` is outside the request sequence: it carries the epoch, an ordinal and the time to live, no
  sequence number and no request ID (`ClusterWorkerCodec.encode(_: ClusterWorkerLeaseRenewal)`,
  `decodeControl`).
- An owner that stops renewing (fenced, stopped, died, lost its link) leaves the worker to end by itself within
  the time to live: the deadline thread takes the one forced exit, which releases MLX's wired limit and cache
  first (status 124, reason `lease-expired`).
- Owners: `ClusterWorkerProcess` (local child) renews from its pump while it keeps the child; a fence stops the
  renewals. `PairWorkerEndpoint` (qualification driver) renews both ranks, the remote one through `ssh`'s input.
  The leader's `ClusterRemoteWorkerEndpoint` renews each remote owner's lease with `renew` frames on the owner
  wire; the owner service (`ClusterOwnerLeaseState.renewLease`) moves its own deadline, and when it lapses the
  state fences the child, whose supervisor then stops renewing the worker.
- A request's deadline is no longer capped by any lease or lifetime: the lease is renewed while the request runs;
  only the request protocol's own one-hour bound applies.

## S15: the member side of the coordinator's grant lease

`NativePairMemberSession` accepts `native_pair_lease` (DBNL v1: renewal ordinal, new expiry, repeated in the
frame's `expires_at_unix_nano`) once committed, and moves its deadline: a grant or renewal that leaves more than
120 s plus 5 s of clock allowance on the member's clock is refused. The member's owner is opened with one rank
lease grant and renewed until the session stops it; the session stops it at the coordinator's last expiry.
An established session (committed, keys exchanged, owner launched) survives a dropped control connection for the
90 s grace (`detached`), and the member registers `resume` (epoch, generation) in its rank registration on the
next connection (`ClusterMembership.Resume`, `CoordinatorClientCodec`); the session moves to the new connection
(`reattach`). The coordinator side is in darkbloom-platform `work/no-fixed-lifetime` (`a0e9dfde`); its vector is
`coordinator/tests/protocol/testdata/native_pair_lease_vector.json`.

## Heartbeats, from the owner's prior work

| Owner design | Here |
|---|---|
| ThunderMLX `run_with_watchdog.py`: dead-man on a heartbeat that must tick during prefill; `os._exit` after clearing Metal | the rank lease: renewals travel on the control pipe from the owner, independent of the executor, so a long prefill never starves them; the S00 forced exit clears wired memory before exit |
| `auto_restart.sh`: restart budget, backoff 15-300 s | the coordinator's formation backoff (2 s doubling to 15 min) and S18 supervision; unchanged here |
| `m3_warmup.py` warmup canary | the pair-check warm-up request; S28 start-up gates, unchanged |
| oMLX `liveness.py` 10 s / stale 45 s; PeerWatchdog 3 s, two misses + 5 s grace | the rank lease 5 s / 30 s; the coordinator's member heartbeat limit 30 s |
| oMLX supervision stall watchdog max(240, tokens/60+120) s | the collective progress guard (60 s installed) and per-request deadlines; unchanged |
| Never RDMA collectives as control during prefill (S06 refined) | renewals and the keep-warm command go over pipes and the owner wire; the only data-plane traffic keep-warm adds is between requests, sequenced like a request |

## S27: keep-warm, on by default

- Tier 1, GPU (owner's `omlx-pr-latent-metal-keepwarm/omlx/keepwarm.py`, upstream MLX #3974): on each worker's
  own executor thread, a one-element add submitted asynchronously on a dedicated stream every 0.5 s while idle;
  armed by the first real request, disarmed by shutdown; a submission over 1 s backs off for 60 s
  (`ClusterKeepWarm.pulse`, `WorkerCoordinator.keepWarmPulseIfIdle`).
- Tier 2, data plane (owner's ThunderMLX 1190a32, `distributed_dataplane_ping`): about once a second while idle
  the pair's owner sends `keepWarm(ordinal)` to both ranks; each runs one 1x16 int32 exchange (rank 0 sends then
  receives, rank 1 receives then sends) on its executor and answers `keptWarm`. Requests wait out an exchange
  (milliseconds); a failed exchange invalidates the pair, which its owner shuts down cleanly
  (`ClusterWorkerPair.keepWarmTick`). Single-executor rule: no second thread issues MLX work or a collective.
- On by default in the product (installed session) and in `darkbloom-cluster-pair-check`; `--keep-warm off`
  (driver) and the worker's `--keep-warm off` turn both tiers off for comparison.

## Measurements (two Macs over the cable; Mac A rank 0 / listener)

Idle latency, first token after an idle gap, median of three per gap, 512-token prompt, 32 outputs, one session
per run (1 warm-up + 18 requests), keep-warm off vs on (`T/evidence/nolife-20261010/hw/idle-*.json`):

| Model | Keep-warm | after 0 s | 1 s | 2 s | 5 s | 15 s | 60 s |
|---|---|---|---|---|---|---|---|
| 9B (cut 4) | off | 0.216 | 0.239 | 0.240 | 0.243 | 0.247 | 0.242 |
| 9B (cut 4) | on | 0.218 | 0.232 | 0.237 | 0.233 | 0.239 | 0.234 |
| 27B (cut 16) | off | 0.819 | 0.831 | 0.849 | 0.846 | 0.844 | 0.850 |
| 27B (cut 16) | on | 0.818 | 0.831 | 0.843 | 0.841 | 0.841 | 0.833 |

On this stack there is no multi-second first-token penalty after idle to remove (ThunderMLX measured ~3 s from
sleeping queue pairs): keep-warm moves the 60 s figure by 8 ms (9B) and 17 ms (27B). Every run returned identical
tokens on every repetition, with 249 keep-warm exchanges interleaved in the keep-warm runs. The first request of
each keep-warm run was slower (9B 0.71 s vs 0.30 s; 27B 1.29 s vs 0.96 s), one sample each; not explained.

Lease and no-lifetime evidence: a session served past 300 s and past sixteen requests on renewals alone (54 to 61
renewals per rank per run); renewals stopped 40 s after launch with the inputs open ended both workers with
status 124 `lease-expired` 64.2 to 64.7 s after launch (within the 30 s time to live of the last renewal), memory
back on both Macs; SIGKILL of the driver (the leader's owner, holding no model) ended both workers within 0.5 s
through their closed inputs, memory back on both Macs.

Endurance (9B, keep-warm on, `hw/endurance-9b.*`): one session of about 33 minutes served 310 of 310 requests
(2,048-token prompt, 64 outputs, idle gaps cycling 0/1/2/5/15 s) with no relaunch or teardown: identical tokens
on all 310, first token median 0.886 s (p95 0.895 s, max 0.965 s), decode median 66.8 tok/s, 400 lease renewals
and 1,412 keep-warm exchanges per rank, then a clean stop (shutdown acknowledged, exit 0 both, no signals, memory
back).

Model-free: `Tests/ProcessChecks/LongSessionCheck.swift` (run by `run.sh` when `PROCESS_CHECKS_LONG_SECONDS` is
set) keeps a fake-worker pair 343 s on renewals alone: 22 requests, 68 renewals per child, 342 keep-warm exchanges,
clean shutdown. The fake worker's own 60 s safety alarm is now pushed out by each renewal, like a real lease.

## Merge notes

- `work/long-context` (9877694de..d5dd98b27) adds per-adapter session lifetime ceilings and reports the installed
  session's lifetime; with no lifetime they are moot: drop the lifetime parts (keep its context and budget work).
- `work/cluster-setup-wizard` shows "N of M requests left in this session" (`ClusterSetupWizardContent`,
  `ClusterSetupWizardChild`, `ClusterSetupWizardState.remainingRequests`) and the console's "Lifetime remaining /
  admissions remaining" line; remove them on merge (the status now carries requests served and keep-warm
  exchanges).
- `SoloDriver` (the single-Mac reference tool) keeps its bounded `--lifetime-seconds`: a tool run, not a session.
