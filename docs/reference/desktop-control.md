# Desktop control API

> Last updated: 2026-10-01

The Electron app controls the Swift CLI/backend through its authenticated local
API. The backend owns provider operations, configuration, model state, credentials,
and coordinator requests. This contract is implemented by
`provider-swift/Sources/darkbloom/Desktop/` (`Desktop`, `DesktopHTTP`, `DesktopBackend`).

## Transport and discovery

`darkbloom desktop ensure` installs/starts the user LaunchAgent
`io.darkbloom.desktop-api`; `darkbloom desktop serve` runs the API directly.
Both accept `--config`. The API binds an allocated port on `127.0.0.1` and writes
`~/.darkbloom/desktop/connection.json` with owner-only permissions. Discovery
contains `version`, `port`, `token`, `pid`, and `instance`. The token is generated
on each API start and is distinct from provider and inference credentials.
`DesktopStorage.write` creates files with mode `0600` before writing.

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
| `GET /control/v1/network` | Normalized public totals from `/v1/stats` | `DesktopBackend.resource` |
| `GET /control/v1/leaderboard` | Public ranking by generated tokens | `DesktopBackend.resource` |
| `GET /control/v1/release` | Latest registered runtime version and changelog | `DesktopBackend.resource` |
| `GET /control/v1/cooling` | Native fan diagnostics and helper state | `DesktopBackend.resource` |
| `GET /control/v1/endpoint-key` | Existing local inference credential for explicit reveal | `DesktopBackend.resource` |

Snapshots replace client state rather than applying deltas. Reconnection always
obtains a full snapshot. Normal snapshots omit credentials. Missing/stale native
observations are not evidence of zero memory usage or zero historical activity.

## Actions

Every action supplies a UUID `id` and `action`. Up to 32 operation records are
retained. Reusing an ID with the same body returns the same operation within an
API-process lifetime; different input is rejected. On process restart, previously
running operations are marked `interrupted` for reconciliation. Clients must
inspect current state before retrying; there is no exactly-once guarantee across
an API crash (`DesktopBackend.init`, `submit`).

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

`GET /v1/provider/desktop` accepts an active provider device token and returns
only that account's fleet status and earnings. Consumer API keys and revoked
tokens are rejected. Revocation is checked before serving the cached result.
The optional `X-Darkbloom-Device-Identity` header is matched only against the
already-owned fleet to identify This Mac; it is not authentication
(`coordinator/api/desktop_handlers.go`, `handleDesktopAccount`).

Account monetary totals are decimal integer strings in micro-USD. Per-machine
`earnings_micro_usd` is observed organic usage earnings over the last seven days,
excluding base rewards; it is omitted when attribution is unavailable. The
projection omits raw device keys, attestation evidence, and hardware control
endpoints. Remote machines are read-only in the app.

## Lifetime and updates

Closing the Electron window hides it and retains the menu bar. On first packaged
launch the GUI registers a login item; subsequent launches preserve any choice
made in macOS Login Items. Explicitly
quitting Electron does not stop the provider or CLI API process. Stop/restart
buttons call the backend. The API process checks for native updates every four
hours when the saved automatic-update setting is enabled
(`DesktopBackend.automaticUpdates`). The existing native updater owns verification,
draining, installation and quarantine. Electron's updater owns only the GUI.

See [desktop development](../developer/desktop-app.md) for validation and current
release qualification gates, and [the implementation plan](../design/macos-electron-app.md)
for the intended full product.
