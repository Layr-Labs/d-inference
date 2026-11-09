# Desktop control API

> Last updated: 2026-11-09

The Electron app controls the Swift CLI/backend through its authenticated local
API. The backend owns provider operations, configuration, model state, credentials,
and coordinator requests. This contract is implemented by
`provider-swift/Sources/darkbloom/Desktop/` (`Desktop`, `DesktopHTTP`, `DesktopBackend`).

The [interactive before-and-after architecture diagram](../assets/desktop-api-architecture.html)
shows the local, account, and public-network data flows.

## Transport and discovery

`darkbloom desktop ensure` installs/starts the user LaunchAgent
`io.darkbloom.desktop-api`; `darkbloom desktop serve` runs the API directly.
Both accept `--config`. `darkbloom stop --uninstall` boots out and deletes the
agent along with the provider and watchdog agents (best effort). The API binds
an allocated port on `127.0.0.1` and writes `~/.darkbloom/desktop/connection.json`
with owner-only permissions. Discovery contains `version`, `port`, `token`, `pid`,
and `instance`. The token is generated on each API start and is distinct from
provider and inference credentials.
`DesktopStorage.write` creates files with mode `0600` before writing.

`ensure` succeeds when the API answers `GET /control/v1/state` with the invoking
CLI's `version` (`DesktopService.ensure`, `nextStep`). It compares the plist on
disk, not launchd's loaded copy, with the one it would write:

| Agent state | Action |
|---|---|
| Not loaded | Write the plist, bootstrap it |
| Loaded, plist on disk differs (any key, including `ProgramArguments`) | Bootout, rewrite, bootstrap |
| Loaded and current, API reports another version or does not answer within 10 s | `launchctl kickstart -k` |
| Loaded and current, same version | Ready; nothing is restarted |
| Loaded, a restart or reinstall is due, API reports a `running` operation | Ready; nothing is restarted |
| Loaded and current, API answers with an HTTP error (for example a broken config) | Fails at once; nothing is restarted |

`ensure` never restarts an API that reports a running operation. The API reads
each CLI child's output through a pipe, so killing the API also kills the child
the next time it writes. A due restart is left to the API's replaced-executable
check (see [Lifetime and updates](#lifetime-and-updates)). A changed plist is
applied by the next `ensure` after the operation finishes. Restarting the same
plist cannot fix an API that answers with an HTTP error, so `ensure` reports the
status instead; a changed plist is still reinstalled.

At most one install, reinstall or restart happens per invocation. Afterwards a
new API instance must answer with the CLI's version within 25 s, otherwise
`ensure` fails with what it saw instead of retrying. A job that vanished before
its restart is bootstrapped instead, within the same budget. A job that is still
loaded 5 s after bootout fails `ensure` rather than being left running. A
relative `--config` is made absolute before it is written into the plist,
because launchd starts the API in `/`. The plist sets `ExitTimeOut` to 5 s so
open event streams cannot stall a restart. If an API dies anyway (crash or a
manual kill), its `running` operations are marked `interrupted` on the next start
(`DesktopBackend.init`). Inspect current state before retrying.

Every route requires `Authorization: Bearer <token>`. Browser `Origin` requests
and non-loopback authorities are rejected. The Electron main process reads
discovery and exposes a fixed preload bridge; the renderer receives no management
credential (`desktop-app/src/main/backend.ts`, `Backend`; `DesktopHTTP.authorized`).

| Method and route | Result / behavior | Owner |
|---|---|---|
| `GET /control/v1/state` | Protocol/version, local machine, provider state, models, memory, settings revision, operations, linking state, and observed activity | `DesktopBackend.state` |
| `GET /control/v1/events` | Full `state` snapshots as SSE every two seconds; connection renews after 30 snapshots; maximum eight streams | `DesktopHTTP.respond`, `DesktopStreamLimiter` |
| `POST /control/v1/actions` | Validated operation; JSON body limited to 16 KiB; returns `202` and its operation ID | `DesktopAction.validate`, `DesktopBackend.submit` |
| `GET /control/v1/request-history` | Exact metadata from the current native usage journal, with settled money joined only by job ID; verified ledger fallback on older runtimes | `DesktopBackend.requestHistory`, `localRequestHistory` |
| `GET /control/v1/cloud` | Account and owned fleet projection through the coordinator; separates This Mac using native identity | `DesktopBackend.resource` |
| `GET /control/v1/insights-week`, `GET /control/v1/insights-month` | Settled earnings, lifetime output tokens, and 7/30-calendar-day analytics through the account-session-authenticated ledger API | `DesktopBackend.resource` |
| `GET /control/v1/network` | Public totals, approximate `provider_regions`, and optional seven-day `model_earnings` from `/v1/stats` | `DesktopBackend.resource` |
| `GET /control/v1/release-history` | Latest release notes from `/v1/releases/latest`; no separate desktop release request | `DesktopBackend.resource` |
| `GET /control/v1/leaderboard` | Public earnings ranking over 24 hours (`metric=earnings&window=24h`); response includes `metric`, `window`, and `entries`; money and token counts remain decimal strings | `DesktopBackend.resource` |
| `GET /control/v1/release` | Latest registered runtime version and changelog | `DesktopBackend.resource` |
| `GET /control/v1/cooling` | Native fan diagnostics and helper state, including `enabled` and `observed_at`; concurrent and repeat reads within 10 s share one `fan status` run; a finished `cooling` action clears it | `DesktopBackend.cooling`, `projectCooling` |
| `GET /control/v1/endpoint-key` | Existing local inference credential for explicit reveal | `DesktopBackend.resource` |
| `GET /control/v1/hardware` | Chip topology and the latest whole-machine load sample (see [Hardware load](#hardware-load)); waits up to 1.5 s for a first sample | `DesktopHardware.resource` |
| `GET /control/v1/hardware/events` | One full `hardware` sample per SSE frame at 1 Hz; connection renews after 120 frames; shares the eight-stream limit with `/events` | `DesktopHardware.events`, `DesktopStreamLimiter` |
| `GET /control/v1/cluster` | This Mac's two-Mac cluster: `cluster status --json` (schema 1) as this build's own child printed it (see [Clusters, Darkbloom Sandbox and waitlists](#clusters-darkbloom-sandbox-and-waitlists)) | `DesktopBackend.clusterStatus`, `readClusterStatus` |
| `GET /control/v1/sandbox` | The Darkbloom Sandbox add-on's `sandbox status --json` document, `last_update_check` in Unix seconds | `DesktopBackend.sandboxStatus` |
| `GET /control/v1/sandbox-logs` | `{lines, observed_at}`: the agent log's last 200 lines (`sandbox logs -n 200`), sanitized | `DesktopBackend.sandboxLogs`, `DesktopText` |
| `GET /control/v1/waitlists` | `darkbloom waitlist --json` as `{data}`, or `{data: [], error, code}` | `DesktopBackend.waitlists`, `readWaitlists` |
| `POST /control/v1/cluster/session`, `GET /control/v1/cluster/session`, `POST /control/v1/cluster/session/answer`, `GET /control/v1/cluster/session/events` | The guided two-Mac setup run with the app's screens (see [Cluster setup session](#cluster-setup-session)) | `DesktopHTTP.clusterSessionRoute`, `DesktopClusterSessions` |

Failures return `{"error": "<message>"}` (`DesktopHTTP.errorResponse`):

| Status | Cause | Message |
|---|---|---|
| `400` | Malformed action body, or failed validation | `Invalid request body`, or the validation message verbatim (the app displays it) |
| `401` | Missing/wrong token, browser `Origin`, non-loopback authority | `Unauthorized local client` |
| `404` | Unknown route or resource | `Unknown route` / `Unknown resource` |
| `409` | A cluster setup session that can't start or take the answer now ([below](#cluster-setup-session)) | The session's message verbatim |
| `413` | Action body over 16 KiB | `Content Too Large` |
| `415` | Action without `Content-Type: application/json` | `JSON required` |
| `429` | A ninth concurrent event stream | `Too Many Requests` |
| `502` | Coordinator unreachable or returned an unusable response | `Coordinator request failed` |
| `500` | Any other internal failure | `Internal error` (details are not exposed) |

Snapshots replace client state rather than applying deltas. Reconnection always
obtains a full snapshot. Normal snapshots omit credentials. Missing/stale native
observations are not evidence of zero memory usage or zero historical activity.

The existing state snapshot adds `provider_status`, the fresh daemon trust status
from the coordinator (`DesktopBackend.state`). It is `null` when the daemon is
stale or only the local API is active (Only me). `readiness` retains the diagnostic
event reason for compatibility; Electron derives the primary readiness label
from lifecycle, loaded selected models, update requirements and `provider_status`
(`assessReadiness`). `untrusted` requires verification; `offline` waits for the
network. A ready Mac shows a loaded-model count, distinct from processing counts.

### Live model activity and account insights

`DaemonState.Capacity.modelActivity` and `activityObservedAt` are additive local
state-file fields, produced from the accepted native backend capacity in
`ProviderLoop.currentDaemonState`. They contain only model ID, state, running
and waiting counts. They do not change the provider/coordinator wire protocol.
`DesktopBackend.modelActivity` exposes them as `activity.models` in the local
snapshot only when daemon identity/liveness is valid and the capacity sample is
at most ten seconds old. The separate `activity.sampled_at` preserves the real
observation time; refreshing the control API cannot make old capacity fresh.
Missing fields on older runtimes remain unknown, rather than becoming zero.

`account_revision` is an opaque process-local session marker that changes when
the dashboard credential or coordinator changes. It contains no token or token hash. The renderer
uses it to discard old account analytics; `DesktopBackend.resource` also rejects
an in-flight private response if the credential changed while awaiting it.

The insights resources map to
`GET /v1/provider/account-earnings?window=7d|30d`. Swift owns the separate
dashboard account session; Electron receives no credential or configurable request URL.
Before the first dashboard sign-in, existing linked-provider earnings remain
available as a migration fallback. Signing out disables that fallback for account views.
Local session settlement backfill remains separate (`DesktopAccountCredential`, `accountReadToken`, `usageCredentialToken`).
All money and token counters in the insights response cross the boundary as decimal strings. The renderer
uses `BigInt` for totals, shares, averages, milestones, and CSV serialization;
only normalized chart geometry and abbreviated labels use floating point.
The platform coordinator's [account earnings contract](https://github.com/Layr-Labs/darkbloom-platform/blob/d7c836b71c77b09dc3fcfa9590c9307a4f2c3a55/docs/reference/api-contracts.md#account-earnings-response)
(pinned at [darkbloom-platform#23](https://github.com/Layr-Labs/darkbloom-platform/pull/23))
defines data scope, retention and the distinction between running work and settled inference.

### Hardware load

The chip view reads real machine load from the desktop API process, never from
the provider daemon (`provider-swift/Sources/DarkbloomHardwareLoad/`,
`HardwareLoadMonitor`). Sampling is demand-driven: it runs only while a
hardware stream is open or for 10 s after the last one closes or a snapshot read.
A dedicated thread polls ANE power at 10 Hz and takes one full sample per
second; one sample costs about 3 ms of CPU, mostly IOReport's blocking PMP read.
No root, entitlement or helper is needed.

`GET /control/v1/hardware` returns `{"protocol": 1, "topology": {...}, "sample": {...} | null}`.
Each `hardware/events` frame is one `sample` object. Topology:

| Field | Meaning |
|---|---|
| `chip`, `model` | `machdep.cpu.brand_string`, `hw.model` |
| `cpu.tiers[]` | `{level, name, kind, cores}` from `hw.perflevelN`, fastest first; `kind` is `super`, `performance` or `efficiency` (M5 adds `super`) |
| `cpu.clusters[]` | `{id, kind, cpus}`; `cpus` are logical CPU ids from the device tree (`IODeviceTree:/cpus`), the indices of `sample.cpu.load` |
| `gpu` | `cores`, `groups` (enabled cores per GPU partition from the driver's core masks), `max_mhz` |
| `ane.present` | The Neural Engine driver exists |
| `memory` | `total_gb`; `peak_bandwidth_gbps` from the chip table, or `null` |

Sample:

| Field | Source | Tier |
|---|---|---|
| `sampled_at`, `interval_ms` | Epoch seconds; window length | — |
| `cpu.load[]` | Busy fraction per logical CPU (`host_processor_info` tick deltas) | Public |
| `gpu.utilization`, `gpu.memory_in_use_gb` | GPU driver `PerformanceStatistics` | Public |
| `gpu.provider_share` | The provider's fraction of all GPU time in the window (per-connection `AGXDeviceUserClient` `AppUsage`); `0` while the provider is stopped | Public |
| `ane.active` | Fraction of polls with the ANE powered; the driver holds power a few seconds after work stops | Public |
| `memory.used_gb`, `memory.wired_gb`, `memory.pressure` | `host_statistics64`, `kern.memorystatus_vm_pressure_level` (`normal`, `warn`, `critical`) | Public |
| `thermal.state` | `nominal`, `fair`, `serious` or `critical` | Public |
| `provider.running` | The daemon's recorded process is current, or an Only me local API is live | Public |
| `gpu.power_w`, `gpu.frequency_mhz` | IOReport Energy Model and GPU performance-state residency over the DVFS table | IOReport |
| `memory.bandwidth_gbps`, `ane.bandwidth_gbps` | IOReport PMP DCS histograms, estimated at each bucket's upper bound | IOReport |
| `ane.power_w` | IOReport Energy Model ANE channels | IOReport |
| `capabilities` | Per IOReport field and `gpu_provider_share`: `measured`, `estimated`, `pending` or `unavailable` | — |

`null` means unknown, never zero. A source that cannot be read is `null`, and
an IOReport counter stays `null` (`pending`) until it has advanced once, because
several channels exist on chips that never drive them. IOReport is a private
library bound at runtime from one file (`IOReportLibrary.swift`); if it is
missing, every IOReport field is `null` with capability `unavailable` and the
public tier is unaffected. On an M4 Max under decode-like GEMV load the DRAM
estimate reads about 450 GB/s against 431 GB/s measured by MLX.

Privacy: hardware counters are served on this loopback API only. They are not
logged, not added to heartbeats or the daemon state file, and not sent to the
coordinator. Other processes are never named; they contribute only anonymous GPU
time to the `provider_share` denominator. `darkbloom doctor --hardware` prints
the same document from a sampler started for that command.

## Actions

Every action supplies a UUID `id` and `action`. Up to 32 operation records are
retained. Reusing an ID with the same body returns the same operation within an
API-process lifetime; different input is rejected. On process restart, previously
running operations are marked `interrupted` for reconciliation. Clients must
inspect current state before retrying; there is no exactly-once guarantee across
an API crash (`DesktopBackend.init`, `submit`).

Cancellation keeps an operation `running` with `cancellable: false` while its
child exits or its native task unwinds. The mutation slot remains occupied until
that cleanup completes, then the operation becomes `cancelled`.

| Action | Additional fields | Behavior |
|---|---|---|
| `start` | `models`; optional `local`, `endpoint`, `network`, `solo` | Existing start path; `local` (Only me, the app's "Local only") uses the same canonical provider LaunchAgent, on this Mac's one local API port (`[local] port`, else the one its local API already uses, else one chosen; `desktop start-local`), and saves Only me (`[local] mode = "local"`) and that port once the service started, `endpoint` (Both, me first, the app's "Alongside the network") passes `--local-endpoint`, and `network` (the Darkbloom network, no local API) passes `--network`; each mode flag is saved in `[local] mode`, which later starts follow. Two of `local`, `endpoint` and `network` are refused: ``Choose one way to serve: Only me, the Darkbloom network, or Both, me first.`` `models` may be empty only for a `start` without `local` on a paired Mac, which starts the pair with its own model; a pair with no model yet refuses it with the CLI's line (`DesktopBackend.startsThePair`). `solo`, only on a Mac that holds a pairing (else ``This Mac isn't in a two-Mac cluster: Start serving serves it alone.``), runs `start --solo --model <id>… [--local\|--local-endpoint\|--network]` (`local` is then `start --solo --local`). It names its models, as every start without a terminal must (`Start.requireModelsNamedWithoutTerminal`; none: ``Choose at least one model``), and while the pair runs on this Mac the CLI refuses it in its own words (`Start.pairStart`), which fails the operation (`DesktopBackend.servingFlag`, `DesktopAction.validateServingChoice`) |
| `autopilot` | `models`, `pinned`; optional `downloads`, `endpoint` | Complete selected native downloads, then verified `start --autopilot --model …`; pin only after successful start. Fail before enrollment when a download fails. Every startup model must be a network model (`models[].network`). On a paired Mac, failed before any download, with the pair's state and what works there: ``This Mac is in a pair, which is stopped; Autopilot isn't available for pairs yet. Use Start serving.`` ("serves in a pair" only while it serves; the no-model line, or the check of an unreadable pairing record, instead of "Use Start serving.") (`DesktopBackend.pairRefusedActions`, `pairAutopilotRefusal`) |
| `autopilot_pin`, `autopilot_unpin` | `models` | Existing CLI pin/unpin; pin budget is rechecked against downloaded estimates and configured slots |
| `autopilot_pause`, `autopilot_resume`, `autopilot_disable` | — | Existing CLI policy commands |
| `autopilot_models` | — | Explicit saved startup selection through `start --autopilot`; same inventory verification and drain/restart as the CLI wizard, preserving live endpoint options. Failed on a paired Mac, as `autopilot` |
| `switch` | `models` | Existing validated live model-switch path |
| `stop`, `restart` | — | Existing native drain; an Only me owner uses its registered native termination handler |
| `download`, `remove` | `model` | Native model management; removal refuses models reported serving/resident |
| `settings` | `revision`, `name`, `idle_minutes`, `auto_update`; optional `schedule`, `startup_preload` | Expected-revision check and mutation under the existing configuration lock |
| `account-signin`, `account-signout` | — | Separate dashboard session; browser approval, owner-only storage, cache clearing; provider credentials remain independent |
| `link`, `unlink` | — | Native provider account linking/logout; UI does not retain the token |
| `update` | — | Existing verified native updater and lifecycle exclusion |
| `diagnose` | — | Existing `doctor` checks; result output is bounded |
| `cancel` | `operation` | Cancels supported download, diagnostic, linking, Autopilot or `sandbox_setup` operations; does not force-stop provider work |
| `cooling` | `enabled`; optional `speed`, `temperature` | Signed native fan helper, with macOS administrator authorization |
| `cluster_leave` | — | `cluster leave --yes`: stops this Mac's part and forgets its pairing (`Cluster.Leave`) |
| `waitlist_join` | `feature` (`^[a-z0-9][a-z0-9-]{0,63}$`, else `Invalid waitlist`) | In process, what `darkbloom waitlist <feature>` does (`FeatureWaitlistCommand.join`): the catalog's waitlist the name names (a plural too), the join (`{}`), and the message in the CLI's words, such as ``You're on the Darkbloom Sandbox waitlist: #3 in line (joined …).``; an unknown name, a problem or a revoked account fails it. It makes the next `waitlists` read ask again |
| `sandbox_pause`, `sandbox_resume` | — | `sandbox pause` / `sandbox resume` |
| `sandbox_uninstall` | — | `sandbox uninstall --yes`: running jobs end unpaid |
| `sandbox_setup` | optional `linux_slots` (0–16), `macos_slots` (0–2, not both 0), `disks` (up to four different absolute paths, no `..` and no control or format characters), `wait_ready` | `sandbox setup --yes --no-browser --json-events [--linux-slots n] [--macos-slots n] [--disk p]… [--wait-ready]`, reported while it runs (see [Sandbox setup progress](#sandbox-setup-progress)). Cancellable: SIGTERM ends the setup at once, or, while its installer runs, reaches the installer as SIGINT, so an enrollment waiting for approval goes on (`SandboxSetupFlow.forwardedTermination`); the child has 30 s before SIGKILL (`DesktopBackend.sandboxSetupGrace`) |
| `route` | `route`: `this-mac`, `my-macs` or `my-macs-first` | `route <route>`: saves `[local] route`; a running local API uses it from its next request (`RouteChoiceFlow`) |
| `route_key` | `key` | `route key --stdin`, the key on standard input only, never argv (`DesktopBackend.routeKeyInput`). Refused first by `route key`'s own rules, in its words without the key (`LocalRouterAccountKeyFormat.refusal`: ``Not saved: an API key has no spaces, line breaks or non-ASCII characters.``). The key never reaches `operations.json`, an operation, a snapshot, a log or an error: the retained request holds an HMAC of it under a per-process key for idempotent retries (`DesktopAction.retained`, `requestDigest`), and the command's output is scrubbed of it (`withoutKey`) |
| `local_settings` | `me_first`, `me_first_idle_minutes` (1–120) | Saves `[local] me_first` and `me_first_idle_minutes` with the CLI's `[local]` writer (`setLocalSettings`, other keys kept). A running provider reads them when it starts (`ProviderLoopConfig.meFirstIdle`), so they apply from its next start: the message says ``Saved. Restart serving to use it now.`` while one runs (`DesktopBackend.executeLocalSettings`) |
| `tool_setup` | `tool`: `opencode` or `hermes` | `start --opencode` / `start --hermes`, which runs without a terminal: beside a running local API it sets the tool up and starts nothing; otherwise it starts as `start` does (Only me serves the models on this Mac; the network or Both without models say they need `--model`, exit 64) ([Set up OpenCode or Hermes](../provider/cli-reference.md#set-up-opencode-or-hermes)) |
| `update_rollback` | — | `update --rollback --yes`: restores the release kept for rollback and quarantines the installed one; like `update`, a success that replaced this executable exits the API for launchd to relaunch (`UpdateRollback`) |

The terminal commands remain independently usable. The API invokes validated
argument arrays in the same CLI binary for existing operations, without a shell
or parsing terminal output to determine state. Settings reuse `withMutableConfig`.
Process output is bounded diagnostic detail; the native exit status determines
operation success (`DesktopWorker`, `DesktopBackend.execute`).

Local review builds using `DARKBLOOM_DESKTOP_ATTACH_ONLY=1` run operation children
through the verified installed Darkbloom CLI, preserving the signed serving
installation (`Desktop.Serve.run`, `DesktopFanRuntime.resolve`). Normal builds
invoke their own shared CLI executable.

Each `Snapshot.models` entry reports `network`: whether the catalog lists it.
The list is the catalog plus every model found on disk, so a model outside the
catalog can be `eligible` for Only me (the app's "Local only") yet never be
advertised or enrolled in Autopilot (`DesktopBackend.state`).

Each entry also reports `registration`: what the live coordinator registration
carries for the model (`DesktopBackend.modelRegistration`).

| Value | Meaning |
|---|---|
| `routable` | In the registration's `models`. The network sends it requests. |
| `autopilot` | In `autopilot_inventory` only. Autopilot can load it. |
| `none` | In neither. The network does not know this Mac has it. |
| `null` | Not known: the daemon is stopped, stale, Only me (the app's "Local only"), not connected, a cluster member, or older. |

The daemon writes the set to `registered_models` in its state file: the
`register` sent on the live connection, plus each written `models_update`,
replaced by an accepted `models_replace` (`ProviderState.registeredModels`).
`serving` is different: it is the selection. The Models page warns when a selected
or pool model is `none` (`ModelRegistration`).

On a Mac in a two-Mac pair, `capabilities` leaves out `autopilot`, which serves one
Mac, and `Snapshot.pair` is `{ model, state, leads }` (`DesktopBackend.snapshotCapabilities`,
`pairSnapshot`, read again after 30 seconds):

- `model`: the pair's model name, or null before one was chosen;
- `state`, from this Mac's own files, with nothing asked over the cable
  (`ClusterPairSummary.appState`): `serving` only where they say the pair serves
  (the part that runs rank 0 says so), `started` where the pair runs here and
  this Mac can't tell (the Mac that follows), `not_running` for a started pair
  that doesn't run here, `stopped`, or `unreadable` when the pairing record can't
  be read;
- `leads`: whether this Mac leads the pair, and so chooses its model; null when
  not known.

It is null on a Mac that isn't paired. The app then offers its plain
**Start serving**, whose `start` starts the pair with its own model
([`darkbloom start` on a paired Mac](../provider/cli-reference.md#darkbloom-start)),
or, with no model yet or an unreadable record, the Terminal step instead.

`Snapshot.autopilot` contains `configured` (consent recorded), `enabled`, `paused`,
`selected` and `pinned`. Its `phase` is populated only by a fresh live daemon;
enrollment alone never implies active control (`DesktopBackend.autopilotSnapshot`).
`memory.pin_budget_gb` and `memory.max_model_slots` expose the shared startup
allowance and current/configured slot limit (`DesktopBackend.state`). Pins protect
from unloading while Autopilot controls residency; a cold pin is not reported as
loaded. Operations optionally report the current download `model` and `progress`
in `[0,1]` (`DesktopBackend.runAutopilot`, `downloadProgress`).

## Clusters, Darkbloom Sandbox and waitlists

These resources are read only on demand, by this build's own commands, never on
the event stream (`DesktopBackend.sharedRead`). Concurrent and repeated reads
within the time to live share one run; an action that changes what they say
makes the next read run again (`forgetSharedReads(after:)`).

| Resource | Command | Shared for | Read again after | When it can't be read |
|---|---|---|---|---|
| `cluster` | `cluster status --json [--config]`, its own 10 s wait for the leading Mac kept, under a 30 s bound | 10 s | `start`, `stop`, `restart`, `switch`, `update`, `update_rollback`, `cluster_leave` | HTTP 200, every `ClusterStatus` key `null`, `state` `unknown`, `lines` `[]`, `exit_code` `-1`, `error` the command's last stderr line or why it didn't run |
| `sandbox` | `sandbox status --json`, whatever its exit status (exit 1 with `not_installed` is normal) | 10 s | any `sandbox_*` action | `{"schema": 1, "state": "unknown", "error": …}` |
| `sandbox-logs` | `sandbox logs -n 200` | 5 s | any `sandbox_*` action | `{"lines": [], "observed_at": …, "error": …}` |
| `waitlists` | In process: the CLI's client (`FeatureWaitlistAccess.live`) with the `darkbloom login` token | 30 s per coordinator and token | `waitlist_join`, `link`, `unlink` | `{"data": [], "error": …, "code": …}` |

`cluster` passes the document of exit 0, 3, 4, 5, 6 or 7 through as it is
([`cluster status`](../provider/cli-reference.md#darkbloom-cluster-status)); a
document with any other exit, or no object with `schema` and `state`, is not
trusted (`DesktopBackend.clusterStatus`). `sandbox` keeps only a document the
CLI itself accepts (`SandboxAddonStatus`: an integer `schema` of 1 or more and a
string `state`), and rewrites `last_update_check` as the CLI reads it (seconds,
milliseconds or ISO 8601; `SandboxAddonStatus.timestamp`), else `null`
(`DesktopBackend.sandboxStatus`). Log lines drop ANSI escape sequences, other
control and format characters and line separators, keep what a carriage return
redraws last, and are cut at 1000 characters (`DesktopText`).

`waitlists` is `{data: [{feature, title, summary, start_command, status, position,
requested_at, decided_at}]}` in the coordinator's order, times in ISO 8601,
optional keys left out when absent (`FeatureWaitlistPlace`). Without a list,
`code` says what to do: `login` (401 or 403), `none` (404: no waitlists) or
`unavailable` (anything else, including the 10 s timeout); `error` is the CLI's
sentence, such as ``Link this Mac to your Darkbloom account first: darkbloom
login`` (`DesktopBackend.waitlistsProblem`, `FeatureWaitlistView.problem`).

### Sandbox setup progress

`sandbox setup --json-events` (hidden) writes one JSON object per line
(`SandboxSetupEvents`): `{"type":"line","text":…}` for each line setup says
(`"stream":"error"` for one it says on standard error at a terminal), and
`{"type":"installer","event":{…}}` for each event of the installer's
`--json-progress`, as the installer wrote it. The API follows it line by line
(`DesktopSandboxSetupTracker`) and sets on the running operation:

| Field | Value |
|---|---|
| `lines` | The last 40 lines, sanitized as log lines are; other output, such as an older runtime's usage, counts as lines |
| `message` | The newest line while it runs; all `lines` once it ends. A runtime without `--json-events` (exit 64 before any event) is named instead |
| `sandbox_setup.stage`, `step`, `steps`, `message` | The installer's latest stage event |
| `sandbox_setup.approval` | `{user_code, verification_uri, verification_uri_complete}` from the approval event; removed once `enrolled` is done |
| `sandbox_setup.waitlisted`, `background` | The waitlist event, and whether the wait goes on in the background (add-on 1.1.2 and later); both false once `enrolled` is done |
| `sandbox_setup.progress` | Image download, 0 to 1, with `wait_ready` |
| `sandbox_setup.exit_status` | Once the setup ended without success: the CLI's exit status (the installer's `2`, `3` or `4`, `130` when stopped, else the CLI's own), or `130` when the cancel's signal ended it first (`DesktopWorker.lastTermination`). Absent while it runs and after a success |

These are the renderer's own readings of the same events
(`SandboxSetupRenderer`). Both fields are kept with the operation in
`operations.json`, as `message` is.

## Local serving and capabilities

`Snapshot.local` is `[local]` in provider.toml as the CLI resolves it
(`DesktopBackend.localServing`, `LocalSettings`):

| Field | Value |
|---|---|
| `mode` | The saved `mode` (`local`, `network`, `both`); `null` before the first choice |
| `me_first`, `me_first_idle_minutes` | `me_first` unless `false`; the minutes, `2` when unset (`resolvedMeFirstIdleMinutes`) |
| `route` | Where your requests go: the saved route, else `my-macs` with an account key saved and `this-mac` without (`resolvedRoute`) |
| `route_key` | Whether an account key is saved, never the key: `Start.accountKeySaved`, read again after 30 s and after `route_key` |
| `port`, `bind` | The saved port, else `null`; the bind address, `127.0.0.1` when unset |
| `paused_until` | Unix seconds when Darkbloom comes back if you stay idle: only while a fresh provider says it is paused for you and knows when (`MeFirstSnapshot.resumesAtMs`; unknown while your request runs), else `null` (`DesktopBackend.pausedUntil`) |

`capabilities` adds `cluster` (the `cluster` resource, `cluster_leave`, `start`
with `solo`), `sandbox` (`sandbox`, `sandbox-logs`, every `sandbox_*` action),
`waitlists` (`waitlists`, `waitlist_join`), `local_serving` (`Snapshot.local`,
`route`, `route_key`, `local_settings`), `tool_setup` and `update_rollback`
(`DesktopBackend.snapshotCapabilities`). The guided cluster setup session is
separate (`cluster_session`).

## Cluster setup session

The app runs the two-Mac setup (pairing, the pair's model and how it serves,
serving) with its own screens: the API runs `darkbloom cluster` in a child that
writes its screen as JSON lines and reads the app's answers
([`--app-console`](../provider/cli-reference.md#darkbloom-cluster---app-console-the-desktop-apps-setup)),
and keeps that screen as a session (`provider-swift/Sources/darkbloom/Desktop/DesktopClusterSession.swift`,
`DesktopClusterSessions`; the app's types are `ClusterSession` and its neighbours in
`desktop-app/src/shared/cluster.ts`). A runtime that has these routes lists
`cluster_session` in `capabilities` (`DesktopBackend.snapshotCapabilities`).

| Route | Body and result | Refusals |
|---|---|---|
| `POST /control/v1/cluster/session` | `{"kind": "setup" \| "local", "model"?: string, "bind"?: string}`; `202` and the new session | `400` for a `kind` other than these, `model` or `bind` with `setup`, a `model` that fails `DesktopAction.validateModel`, or a `bind` that fails `ClusterServingScope.isValidBind`; `409` `A cluster setup is already running.`; `409` `An operation is already running. Wait for it to finish.` (`DesktopBackend.startClusterSession`) |
| `GET /control/v1/cluster/session` | The current or last session, or `null` | — |
| `POST /control/v1/cluster/session/answer` | `{"question": "<id>", "choice": <index>}`, `{"question": "<id>", "key": "q"}` or `{"cancel": true}`; the line goes to the child and the session comes back with `question` `null` until the child asks again | `409` `No cluster setup is running.` (also once the child wrote its `exit`); `409` `That question is no longer asked.`; `400` `Invalid answer` for a choice outside the options, a key not offered, or mixed fields (`DesktopClusterSessions.answer`, `answerLine`) |
| `GET /control/v1/cluster/session/events` | SSE frames `event: cluster-session` whose `data` is the whole session (or `null`): one at once, then one per change, at most five a second; the stream renews after 300 frames or 60 s and shares the eight-stream limit | `429` (`DesktopClusterSessions.events`) |

Bodies need `Content-Type: application/json` (`415` otherwise) and at most
16 KiB, as actions take (`DesktopHTTP.jsonBody`). `setup` runs `darkbloom cluster --app-console`; `local` runs
`darkbloom cluster local --app-console [--bind <bind>] [<model>]`; both add
`--config` as every child gets it, made absolute (`DesktopClusterSessionStart.arguments`).
The child has no terminal and, as every child of the API, runs with `DARKBLOOM_NO_UPDATE_CHECK=1` and `NO_COLOR=1`
(`DesktopWorker.childEnvironment`).

A running session holds the mutation slot actions use, since the setup starts
and stops this Mac's services itself: it starts only while no operation runs,
every action except `cancel` is refused with `A cluster setup is already running.`
while it runs (`DesktopBackend.submit`), and the restart for a replaced
executable waits for it (`exitWhenExecutableReplaced`). The session lives in the
API process: a restarted API has none, and its child sees its input end, which
leaves the setup as a cancel does.

| Session field | Meaning |
|---|---|
| `id`, `kind` | A UUID; `setup` or `local` |
| `state` | `running` until the child exits; then `cancelled` after a cancel, else `succeeded` (exit status 0) or `failed` |
| `started_at`, `finished_at` | Epoch seconds; `finished_at` only once ended |
| `events` | The screen in order, at most the last 600. Live work (`working`, `progress`) is only ever the last event: the next live work replaces it, and the next line or a `settle` ends it |
| `question` | What the setup waits for (below), or `null` |
| `exit_code` | Only once ended: the child's exit status, 128 + the signal for one it died of |
| `error` | Only when the child ended without its `exit` event: ``The installed Darkbloom runtime doesn’t support this yet. It needs a runtime release that includes the desktop app’s commands.`` for a runtime without `--app-console`, else its last standard-error lines, else its status (`DesktopClusterSessions.endedEarly`). The setup's own outcome is its `result` event |

Each event is the console's, with its `event` named `type` (`DesktopClusterSessions.event`);
a standard-output line that isn't JSON is a `say` of that line.

| `type` | Fields | What it is |
|---|---|---|
| `banner` | `title`, `subtitle` | The setup's opening (`Darkbloom cluster`, or with the Mac's part: `Darkbloom cluster · Leading Mac`) |
| `heading` | `text` | A step: `1/4 Connect` … `4/4 Start` in the first setup, else `Model`, `Start`, `Change model` |
| `say` | `text`; `stressed` `{lead, stressed, tail}` where a terminal shows bold | A line as Terminal shows it, its indent kept, blank lines left out. An answered list adds `  ▸ <the option's first row>`, as Terminal folds the list to it |
| `working` | `rows` | Work still running, one row per Mac while the parts load |
| `progress` | `text` | A copy's or download's whole report line |
| `result` | `ok`, `title`, `lines` | The outcome block: ✓ (`ok`) with what serves, or ✗ with why nothing does |
| `needs_terminal` | `text` | A step the app can't take (sudo where macOS shows no prompt; **Log in on this Mac**): ``Run `darkbloom cluster` in a Terminal window on this Mac.`` (`cluster local`'s line for `local`). The step then runs with nothing to read, so sudo fails at once |

| Question `type` | Fields | Asked |
|---|---|---|
| `choose` | `id`, `options` (each option's rows: its title, then its detail rows), `selected` (the default) | Every list of the setup, after the line that asks it; and the clusters waitlist's ``Join the Clusters waitlist now?`` with `Yes` and `No`, `No` selected (`Cluster.Setup.appWaitlistGate`) |
| `key` | `id`, `keys` `[{key, label}]` | While a wait acts on a key (`ClusterOnboardingWaitKey`): `q` `Cancel` in the pairing's wait and the wait for Local Network's Allow; `q` `Leave` in the start's wait and in the other Mac's start that the joining Mac follows. None in a copy or download, or while the pairing waits for the other Mac to confirm the code. Asked again when the keys change or one was taken; otherwise it stays while the waits go on |

A cancel answers as q and escape do in Terminal: the list asked now, and every
later one, returns nothing, and every wait that takes `q` gets it, so the setup
ends at its next question or wait in its own words (``Cancelled: nothing paired.``,
``Nothing changed.``, …). Work that takes no key, such as a copy, runs to its end
first, and a start then stops before its first change with ``Cancelled: nothing started.``
(`ClusterOnboardingAppConsole.guarding`). The child's input ending is a cancel too.

## Account session and refresh

`DesktopBackend.accountCloud` combines `/v1/me/providers`, `/v1/me/summary`,
and windowed `/v1/provider/account-earnings` reads. The owned fleet's SE identity
identifies This Mac; remote models come from loaded `running`/`idle` slots when
capacity exists. Missing per-machine money stays unknown. The renderer receives
only the UI projection (`DesktopAccountCloud.swift`, `projectAccountCloud`).

The account footer displays `state.account.email` with Signed in. Swift obtains
identity from the existing `/v1/provider/account-earnings` response's optional
`email`, persists it with the coordinator-scoped dashboard credential, and shares
the same cached ledger request with stats and earnings (`DesktopAccountIdentity`).
State polling hydrates older credentials even when the provider is stopped;
missing identity leaves Account as the label. Sign-out removes the identity,
and replies from another coordinator/session cannot update it. Coordinators must
include the authenticated owner's email in that response for the address to appear.

`account-signin` and `darkbloom desktop login` reuse the browser device-code flow
with `purpose=desktop_account`. The bottom-left account button opens a modal with
the snapshot's `link.code`, copy, explicit Continue in browser and cancellation controls
(`AccountControl`, `AccountSignInProgress`). Electron sets
`automaticallyOpenBrowser=false` in the shared login client; `darkbloom login` and
`darkbloom desktop login` retain the default automatic launch. Closing the dialog
preserves pending approval and Continue sign-in reopens it. Completion, failure or
cancellation hides the code; failure supports retry. No additional endpoint is needed.
The browser uses its Privy session to approve
read-only access on coordinators that acknowledge that scope. Older coordinators
that omit the purpose use their existing provider device-code grant; the browser
shows the standard device-link approval. Swift accepts only the matching token
prefix for the negotiated grant and never downgrades an acknowledged scoped grant
(`ProviderCore/Auth/DeviceLoginScope.swift`, `DeviceLoginScope`). This legacy token
has provider privileges on the server, but the dashboard uses it only for account
reads and stores it separately from the serving credential. Local dashboard use
expires after 30 days in both cases, in an owner-only, coordinator-scoped file
under `DARKBLOOM_DESKTOP_DIR`.
The renderer never receives it. Expiry or revocation requires sign-in again.
`account-signout` and `darkbloom desktop logout` clear the local credential and
account caches and attempt bounded server revocation for scoped sessions; offline
sign-out can leave them valid until expiry. Legacy coordinators have no account
revocation endpoint or server expiry, so legacy sign-out removes only local access.
Neither command changes the provider's
`AuthTokenStore` credential (`DesktopAccountCredential.swift`, `DesktopAccountCommands.swift`).

`DesktopResourceCache.swift` (`cachedResource`) coalesces reads and caches account
and public data for 30 seconds, releases for one hour. Failed reads back off
from 30 seconds to four minutes; credential changes discard old in-flight results. The local state stream
includes `resource_revision` on the native 30-second clock. Mounted views use it
as their refresh signal; unrelated pages make no resource reads (`pageResources`).
The catalog refresh runs independently of local snapshots. Legacy global identity
roster reads are cached for five minutes; authenticated account sessions use the
owned fleet instead (`refreshUsageHistoryIfNeeded`). Operation waiters consume
state events, falling back to a state read after ten seconds of stream silence
(`desktop-app/src/renderer/actions.ts`, `submitAction`).

The coordinator, now maintained in
[darkbloom-platform](https://github.com/Layr-Labs/darkbloom-platform), has no
`/v1/provider/desktop`, `/v1/provider/desktop/insights`, or `/v1/releases/desktop`
route. The app requests only the existing account, public and release reads
(`DesktopBackend.readRemoteResource`); the desktop account bearer is accepted
only on `GET /v1/me/providers`, `GET /v1/me/summary`,
`GET /v1/provider/account-earnings` and its own `DELETE /v1/device/token`
([device-code flow](https://github.com/Layr-Labs/darkbloom-platform/blob/d7c836b71c77b09dc3fcfa9590c9307a4f2c3a55/docs/reference/api-contracts.md#device-code-flow-5)).

## Lifetime and updates

Closing the Electron window hides it and retains the menu bar. On first packaged
launch the GUI registers a login item; subsequent launches preserve any choice
made in macOS Login Items. The app starts hidden when macOS reports
`wasOpenedAtLogin` or `--hidden` is passed (`desktop-app/src/main/loginLaunch.ts`,
`shouldStartHidden`). Explicitly quitting Electron does not stop the provider or
CLI API process. Stop/restart
buttons call the backend. The API process checks for native updates every four
hours when automatic updates are enabled and the serving provider is stopped
(`DesktopBackend.automaticUpdates`). The existing native updater owns verification,
draining, installation and quarantine. Electron's updater owns only the GUI.
Its feed exists only when `DARKBLOOM_DESKTOP_UPDATE_URL` is set at build time;
otherwise the app reports an explicit `unconfigured` update state and never
reads the provider's GitHub releases (`desktop-app/src/main/updateFeed.ts`).

The API restarts itself after its executable is replaced out of band (terminal
`darkbloom update`, provider self-update, the app's repair path). It records the
executable's identity (inode, size, modification date) at startup and checks it
every 30 seconds. When it differs and no operation is `running`, the API persists
its operations and exits, and launchd's `KeepAlive` relaunches the replacement.
A running operation defers the exit to a later check. An unreadable identity
never triggers an exit (`DesktopBackend.exitWhenExecutableReplaced`,
`shouldRestartForReplacedExecutable`). A `desktop serve` started by hand is not
relaunched; it just exits. Updates submitted through the API still exit as soon
as the update operation succeeds. The app's event stream drops, so it reconnects
and re-runs `desktop ensure`.

See [desktop development](../developer/desktop-app.md) for validation and current
release qualification gates, and [the implementation plan](../design/macos-electron-app.md)
for the intended full product.
