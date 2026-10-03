# Desktop control API

> Last updated: 2026-10-02

The Electron app controls the Swift CLI/backend through its authenticated local
API. The backend owns provider operations, configuration, model state, credentials,
and coordinator requests. This contract is implemented by
`provider-swift/Sources/darkbloom/Desktop/` (`Desktop`, `DesktopHTTP`, `DesktopBackend`).

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
| `GET /control/v1/cloud` | Account and owned fleet projection through the coordinator; separates This Mac using native identity | `DesktopBackend.resource` |
| `GET /control/v1/insights-week`, `GET /control/v1/insights-month` | Settled earnings, lifetime output tokens, and 7/30-calendar-day analytics through the provider-token-authenticated coordinator endpoint | `DesktopBackend.resource` |
| `GET /control/v1/network` | Normalized public totals and approximate `provider_regions` from `/v1/stats` | `DesktopBackend.resource` |
| `GET /control/v1/release-history` | Public release notes and routing floor from `/v1/releases/desktop` | `DesktopBackend.resource` |
| `GET /control/v1/leaderboard` | Public earnings ranking over 24 hours (`metric=earnings&window=24h`); response includes `metric`, `window`, and `entries`; money and token counts remain decimal strings | `DesktopBackend.resource` |
| `GET /control/v1/release` | Latest registered runtime version and changelog | `DesktopBackend.resource` |
| `GET /control/v1/cooling` | Native fan diagnostics and helper state; concurrent and repeat reads within 10 s share one `fan status` run; a finished `cooling` action clears it | `DesktopBackend.cooling` |
| `GET /control/v1/endpoint-key` | Existing local inference credential for explicit reveal | `DesktopBackend.resource` |
| `GET /control/v1/hardware` | Chip topology and the latest whole-machine load sample (see [Hardware load](#hardware-load)); waits up to 1.5 s for a first sample | `DesktopHardware.resource` |
| `GET /control/v1/hardware/events` | One full `hardware` sample per SSE frame at 1 Hz; connection renews after 120 frames; shares the eight-stream limit with `/events` | `DesktopHardware.events`, `DesktopStreamLimiter` |

Failures return `{"error": "<message>"}` (`DesktopHTTP.errorResponse`):

| Status | Cause | Message |
|---|---|---|
| `400` | Malformed action body, or failed validation | `Invalid request body`, or the validation message verbatim (the app displays it) |
| `401` | Missing/wrong token, browser `Origin`, non-loopback authority | `Unauthorized local client` |
| `404` | Unknown route or resource | `Unknown route` / `Unknown resource` |
| `413` | Action body over 16 KiB | `Content Too Large` |
| `415` | Action without `Content-Type: application/json` | `JSON required` |
| `429` | A ninth concurrent event stream | `Too Many Requests` |
| `502` | Coordinator unreachable or returned an unusable response | `Coordinator request failed` |
| `500` | Any other internal failure | `Internal error` (details are not exposed) |

Snapshots replace client state rather than applying deltas. Reconnection always
obtains a full snapshot. Normal snapshots omit credentials. Missing/stale native
observations are not evidence of zero memory usage or zero historical activity.

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
the linked credential changes. It contains no token or token hash. The renderer
uses it to discard old account analytics; `DesktopBackend.resource` also rejects
an in-flight private response if the credential changed while awaiting it.

The insights resources map to
`GET /v1/provider/desktop/insights?window=7d|30d`. The Swift backend supplies the
provider token; Electron receives no credential or configurable request URL.
All money and token counters in the insights response cross the boundary as decimal strings. The renderer
uses `BigInt` for totals, shares, averages, milestones, and CSV serialization;
only normalized chart geometry and abbreviated labels use floating point.
The [HTTP contract](api-contracts.md#desktop-earnings-insights) defines data scope,
retention and the distinction between running work and settled inference.

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
| `provider.running` | The daemon's recorded process is current, or a local-only endpoint is live | Public |
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
| `start` | `models`; optional `local`, `endpoint` | Existing start path; local-only mode uses the same canonical provider LaunchAgent |
| `switch` | `models` | Existing validated live model-switch path |
| `stop`, `restart` | — | Existing native drain; local-only owner uses its registered native termination handler |
| `download`, `remove` | `model` | Native model management; removal refuses models reported serving/resident |
| `settings` | `revision`, `name`, `idle_minutes`, `auto_update`; optional `schedule`, `startup_preload` | Expected-revision check and mutation under the existing configuration lock |
| `link`, `unlink` | — | Native provider account linking/logout; UI does not retain the token |
| `update` | — | Existing verified native updater and lifecycle exclusion |
| `diagnose` | — | Existing `doctor` checks; result output is bounded |
| `cancel` | `operation` | Cancels supported download, diagnostic, or linking operations; does not force-stop provider work |
| `cooling` | `enabled`; optional `speed`, `temperature` | Signed native fan helper, with macOS administrator authorization |

The terminal commands remain independently usable. The API invokes validated
argument arrays in the same CLI binary for existing operations, without a shell
or parsing terminal output to determine state. Settings reuse `withMutableConfig`.
Process output is bounded diagnostic detail; the native exit status determines
operation success (`DesktopWorker`, `DesktopBackend.execute`).

## Coordinator projection

`GET /v1/provider/desktop` accepts only an active provider device token linked
to an account, and returns only that account's fleet status and earnings.
Privy JWTs, the admin key, consumer API keys and revoked tokens are rejected
(`requireDesktopProviderToken`). Revocation is checked on every request, before
the cached result is served. Requests count against the account's shared
per-account rate limiter (the same bucket as inference, reported under the
`desktop` tier); excess requests get `429` with `Retry-After` (`rateLimitDesktop`).
The projection is cached for 20 seconds per account. The optional
`X-Darkbloom-Device-Identity` header never keys that cache: each request matches
it against the cached fleet's keys to set `is_this_mac`, and it is not
authentication (`coordinator/api/desktop_handlers.go`, `handleDesktopAccount`,
`forIdentity`).

Account monetary totals are decimal integer strings in micro-USD. Per-machine
`earnings_micro_usd` is observed organic usage earnings over the last seven days,
excluding base rewards; it is omitted when attribution is unavailable. The
projection omits raw device keys, attestation evidence, and hardware control
endpoints. Remote machines are read-only in the app.

## Lifetime and updates

Closing the Electron window hides it and retains the menu bar. On first packaged
launch the GUI registers a login item; subsequent launches preserve any choice
made in macOS Login Items. The app starts hidden when macOS reports
`wasOpenedAtLogin` or `--hidden` is passed (`desktop-app/src/main/loginLaunch.ts`,
`shouldStartHidden`). Explicitly quitting Electron does not stop the provider or
CLI API process. Stop/restart
buttons call the backend. The API process checks for native updates every four
hours when the saved automatic-update setting is enabled
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
