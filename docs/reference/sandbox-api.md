# Sandbox private-alpha API

> Last updated: 2026-09-13 · commit `453b37667`

This reference defines the account-scoped sandbox control API. The service and
new-work admission default off; runtime qualification is separate from enabling
these HTTP routes. See [run a sandbox command](../consumer/sandbox-commands.md)
for the consumer workflow and [the runtime implementation](../../sandbox-macos/README.md)
for host requirements.

The [standalone sandbox client](../consumer/sandbox-cli.md) supports this control
API and verified workspace transfers on macOS and Linux.

[Workspace file transfers](sandbox-files.md) use a separate bounded data relay;
they do not encode uploads or downloads as shell commands.

## Access and service modes

The coordinator resolves each API key or Privy JWT to its account identity.

| Contract | Behavior | Code |
|---|---|---|
| Credentials | Account API keys and Privy JWTs accepted; coordinator admin keys and provider device tokens rejected | `coordinator/api/sandbox_auth.go` (`requireSandboxAuth`) |
| Service disabled | Sandbox HTTP requests return 503 after credential validation; host WebSocket returns 503; no sandbox controller or sweeper starts | `coordinator/api/server.go` (`NewServer`), `coordinator/api/sandbox_host.go` (`handleSandboxHostWS`) |
| Admission paused | New create, start, execute, and renewal requests return 503 `sandbox_draining`; owner reads, cancellation, stop, and deletion remain available | `coordinator/api/sandbox_auth.go` (`requireSandboxAdmission`), `coordinator/api/sandbox_routes.go` (`registerSandboxRoutes`) |
| Admission enabled | An explicit account allowlist is required; accounts outside it get 403 `sandbox_access_required` for new work | `coordinator/api/sandbox_config.go` (`SandboxServiceConfig.Check`, `admits`) |
| Removed account | Existing authenticated owners retain read and cleanup access; ownership is checked for every resource | `coordinator/api/sandbox_auth.go` (`requireSandboxAuth`), `coordinator/store/interface_domains.go` (`SandboxStore`) |
| Coordinator drain | Create, start, execute, and renew return the ordinary drain 429; owner reads and cleanup remain available | `coordinator/api/sandbox_routes.go` (`registerSandboxRoutes`) |
| Host credentials | Dedicated host UUID header and per-host bearer token, checked against configured SHA-256 hashes | `coordinator/sandboxhost/auth.go` (`Authenticator.Authenticate`), `coordinator/api/sandbox_host.go` (`sandboxHostCredentials`) |

**Disabling the service is not draining it.** Keep the service enabled and pause
admission until every sandbox reaches `deleted`; otherwise the coordinator
cannot accept host cleanup acknowledgements. Configuration names and defaults
live in [configuration.md](configuration.md#sandbox-private-alpha).

## Routes

All consumer routes require `Authorization: Bearer <token>`; IDs and mutation
idempotency keys use canonical UUID text. Symbols are registered in
`coordinator/api/sandbox_routes.go` (`registerSandboxRoutes`).

| Method and path | Request | Response / handler |
|---|---|---|
| `POST /v1/sandboxes` | `Idempotency-Key`; JSON `base_image_id`, `cpu_count`, `memory_gib`, `workspace_gib`, optional `gpu` (must be false) | 202 `{sandbox, operation}`; `coordinator/api/sandbox_handlers.go` (`handleCreateSandbox`) |
| `GET /v1/sandboxes` | Optional `limit`, 1–1000, default 100 | 200 `{data: [SandboxRecord]}` newest first; `coordinator/api/sandbox_handlers.go` (`handleListSandboxes`) |
| `GET /v1/sandboxes/{sandboxID}` | — | 200 `SandboxRecord`; `coordinator/api/sandbox_handlers.go` (`handleGetSandbox`) |
| `POST /v1/sandboxes/{sandboxID}/commands` | `Idempotency-Key`; JSON `arguments`, optional `environment`, `working_directory`, `timeout_seconds` | 202 `{command}`; `coordinator/api/sandbox_handlers.go` (`handleSandboxCommand`) |
| `GET /v1/sandboxes/{sandboxID}/commands` | Optional `limit`, 1–1000, default 100 | 200 `{data: [SandboxCommandSummary]}` newest first, ties by ID descending; metadata excludes argv, environment and output; `coordinator/api/sandbox_commands.go` (`handleListSandboxCommands`) |
| `GET /v1/sandboxes/{sandboxID}/commands/{commandID}` | — | 200 `{command}` including retained input/output; `coordinator/api/sandbox_handlers.go` (`handleGetSandboxCommand`) |
| `POST /v1/sandboxes/{sandboxID}/commands/{commandID}/cancel` | No body; inherently idempotent for the command | 202 `{command}` while host cleanup is pending, 200 when already complete; `coordinator/api/sandbox_commands.go` (`handleCancelSandboxCommand`) |
| `POST /v1/sandboxes/{sandboxID}/renew` | `Idempotency-Key`; no body | 202 `{operation}`; `coordinator/api/sandbox_handlers.go` (`handleRenewSandbox`) |
| `POST /v1/sandboxes/{sandboxID}/start` | `Idempotency-Key`; no body | 202 `{operation}`; `coordinator/api/sandbox_start.go` (`handleStartSandbox`) |
| `POST /v1/sandboxes/{sandboxID}/stop` | `Idempotency-Key`; no body | 202 `{operation}`; `coordinator/api/sandbox_handlers.go` (`handleStopSandbox`) |
| `DELETE /v1/sandboxes/{sandboxID}` | `Idempotency-Key`; no body | 202 `{operation}`; `coordinator/api/sandbox_handlers.go` (`handleDeleteSandbox`) |
| `GET /v1/sandbox-operations/{operationID}` | — | 200 `{operation}`; `coordinator/api/sandbox_handlers.go` (`handleGetSandboxOperation`) |

## Durable execution semantics

The response describes persisted intent; host execution and cleanup can complete later.

| Contract | Behavior | Code |
|---|---|---|
| Create replay | Same account, idempotency key and allocation return the original sandbox/operation; changed allocation conflicts | `coordinator/sandboxcontrol/controller.go` (`Create`) |
| Command replay | The body may supply `idempotency_key`; if a header is also supplied they must match. Changed command input with the same key conflicts | `coordinator/api/sandbox_handlers.go` (`handleSandboxCommand`), `coordinator/sandboxcontrol/lifecycle.go` (`Execute`) |
| Cancellation | Intent is durable before dispatch; `cancellation_pending=true` means cleanup is unconfirmed even if state is `cancelled`. Retry and reconnect redeliver; completion that wins the race keeps its original result | `coordinator/sandboxcontrol/commands.go` (`CancelCommand`), `coordinator/sandboxcontrol/dispatch.go` (`dispatchCommandCancellation`) |
| Start/resume | Only a stopped, unexpired, nonterminating allocation with no active operation/command/cancellation can start. It keeps the same host, generation, resources and lease expiry, reserves one new fencing token, and preserves all command history. The original key replays the same outcome; a new key after definitive failure creates a new attempt | `coordinator/sandboxcontrol/start.go` (`Start`), `coordinator/store/sandbox_start.go` (`applySandboxStartAuthority`, `sandboxStartMatchesLease`) |
| Observed runtime stop | An authenticated current-connection heartbeat can demote `ready` to `stopped` only when host, generation, fence, resources and lease expiry match and no lifecycle operation is pending. Command/cancellation records remain active and keep blocking Start; heartbeats never promote to ready | `coordinator/sandboxcontrol/observations.go` (`observeStoppedLeases`), `coordinator/store/postgres_sandbox_observation.go` (`ObserveSandboxStopped`) |
| Single active command | A pending cancellation blocks replacement commands, start, renewal and stop completion until host acknowledgement | `coordinator/store/sandbox.go` (`SandboxCommand.Active`), `coordinator/store/postgres_sandbox.go` (`CreateSandboxCommand`) |
| Timeout | Default and maximum command timeout is 900 seconds; deadline is measured from coordinator acceptance and must fit inside the lease | `coordinator/sandboxcontrol/controller.go` (`CommandTimeoutSeconds`), `coordinator/store/sandbox.go` (`SandboxCommand.Deadline`) |
| Command workspace | New requests default to `/workspace`; only that directory and safe descendants are allowed. Executable paths must be absolute. Input is at most 64 KiB; argument/environment values at most 16 KiB; privileged environment overrides are rejected | `coordinator/sandboxcontrol/lifecycle.go` (`Execute`), `coordinator/protocol/sandbox_codec.go` (`validateSandboxCommand`, `reservedSandboxEnvironment`) |
| Lease and capacity | Lease duration is 30 minutes; alpha maximum is two global allocations and two per account. Only `deleted` releases coordinator capacity; `stopped` retains it | `coordinator/sandboxcontrol/controller.go` (`LeaseDuration`, `MaximumActiveSandboxes`, `MaximumSandboxesPerAccount`), `coordinator/store/sandbox.go` (`ConsumesCapacity`) |
| Statuses | Sandbox: `preparing`, `ready`, `stopping`, `stopped`, `deleting`, `deleted`, `failed`. Command: `pending`, `accepted`, `running`, `succeeded`, `failed`, `timed_out`, `cancelled`, `lost` | `coordinator/store/sandbox.go` |
| Operation states | `pending`, `queued`, `preparing`, `booting`, `ready`, `stopping`, `stopped`, `deleting`, `deleted`, `failed` | `coordinator/store/sandbox.go` (`SandboxOperation.Terminal`) |
| Sweeper visibility | Failed command expiry, cancellation and lease expiry retry in bounded sweeps; one warning per phase per minute and one recovery event | `coordinator/sandboxcontrol/expiry.go` (`runLeaseSweeper`), `coordinator/sandboxcontrol/sweep_logging.go` (`recordSweepResult`) |

## Start host wire contract

Start resumes a stopped workspace and has a separate message shape from stop.

| Field or response | Contract | Code |
|---|---|---|
| Host capability | `supports_start` is optional and defaults false; new starts require it | `coordinator/protocol/sandbox_types.go` (`SandboxHostCapabilities`), `coordinator/sandboxcontrol/start.go` (`Start`) |
| Request | `sandbox_start`: `operation_id`, old `scope`, `requested_fencing_token` strictly greater than the old token, and the allocation's exact `lease_expires_at` | `coordinator/protocol/sandbox_types.go` (`SandboxStartPayload`), `sandbox-macos/Sources/SandboxCore/SandboxControlProtocol.swift` (`SandboxWireStart`) |
| Result | Existing `sandbox_operation_state` with `operation: "start"`; `preparing`, `booting`, `ready`, or `failed` | `coordinator/protocol/sandbox_codec.go` (`knownSandboxOperation`), `coordinator/store/sandbox.go` (`validSandboxOperationTransition`) |
| Scope after rotation | Ready requires the reserved new token. A failure after host rotation retains the new token for stop/delete; an earlier failure may report the old token. Later messages cannot roll authority back | `coordinator/store/sandbox_start.go` (`applySandboxStartAuthority`) |
| Reconnect | Retransmits the same operation, old scope, reserved new token and unchanged expiry; a ready lease heartbeat alone cannot establish guest readiness. Capability downgrade leaves uncertain start intent pending for a qualified reconnect, because the prior response may have been lost | `coordinator/sandboxcontrol/dispatch.go` (`dispatchOperation`), `coordinator/sandboxcontrol/reconcile.go` (`applyHeartbeatOperationObservation`) |
| Failure | Returns allocation to `stopped` only after runtime stop proof. `runtime_cleanup_failed` instead leaves it `failed` with retained authority/capacity; deletion remains available and resume is denied. Renew extends the deadline without starting the VM | `coordinator/store/sandbox.go` (`sandboxStateForOperationUpdate`), `coordinator/sandboxcontrol/lifecycle.go` (`Renew`) |

## Errors and data

| Condition | HTTP / behavior | Code |
|---|---|---|
| Unknown or non-owned resource | 404 `sandbox_not_found` | `coordinator/api/sandbox_handlers.go` (`writeSandboxAPIError`) |
| Invalid input | 400 `invalid_request_error`; oversized JSON 413 | `coordinator/api/sandbox_handlers.go` (`decodeStrictSandboxJSON`, `writeSandboxAPIError`) |
| No matching capacity | 429 with `Retry-After: 5` | `coordinator/api/sandbox_handlers.go` (`writeSandboxAPIError`) |
| State/idempotency conflict | 409; retry existing operation or inspect current state | `coordinator/api/sandbox_handlers.go` (`writeSandboxAPIError`) |
| Start host unavailable | 503 if the host is offline or does not advertise `supports_start`; already-recorded idempotency replays remain readable | `coordinator/sandboxcontrol/start.go` (`Start`, `ErrStartUnavailable`), `coordinator/api/sandbox_handlers.go` (`writeSandboxAPIError`) |
| Command data | Unexpired coordinator command records contain argv, environment, working directory and output; metadata listings omit those payloads. Expired records expose `payload_expired` and `payload_expired_at`, with cleared payload fields | `coordinator/store/sandbox.go` (`SandboxCommand`), `coordinator/store/sandbox_payload_retention.go` (`redactSandboxCommandPayload`) |
| Charging | This private-alpha controller does not charge consumer balances or create provider payouts | `coordinator/sandboxcontrol/controller.go` (`Create`), `coordinator/sandboxcontrol/lifecycle.go` (`Execute`) |

## Command payload retention

Completed command payloads become eligible for redaction after the configured
retention period; [configuration](configuration.md#sandbox-private-alpha) owns
the deployment setting.

| Contract | Behavior | Code |
|---|---|---|
| Eligibility | Terminal commands with a completion timestamp at or before the cutoff; active and cancellation-pending commands are excluded | `coordinator/store/memory_sandbox_payloads.go` (`RedactSandboxCommandPayloads`), `coordinator/store/postgres_sandbox_payloads.go` (`RedactSandboxCommandPayloads`) |
| Removed fields | `arguments`, `environment`, `working_directory`, `stdout`, `stderr` | `coordinator/store/sandbox_payload_retention.go` (`redactSandboxCommandPayload`) |
| Retained metadata | IDs, account ownership, outcome/exit code, timings, output truncation and dispatch/cancellation metadata; `payload_expired` and expiry timestamp are public | `coordinator/store/sandbox.go` (`SandboxCommand`) |
| Request replay | An internal, versioned request commitment binds account, sandbox, idempotency key and original payload. An unchanged valid request returns the original expired result; changed input conflicts and never executes again | `coordinator/store/sandbox_payload_retention.go` (`sandboxCommandRequestDigest`, `sameSandboxCommandRequest`) |
| Legacy rows | Missing commitments are computed under the redaction row lock before clearing raw request material | `coordinator/store/postgres_sandbox_payloads.go` (`RedactSandboxCommandPayloads`) |
| Late host results | Terminal transition checks cannot restore expired input or output | `coordinator/store/sandbox.go` (`applySandboxCommandTransition`) |
| Work bounds | At most 32 eligible rows each minute, with a five-second operation context; SQL skips locked rows and uses a partial completion-time index | `coordinator/sandboxcontrol/payload_retention.go` (`sweepCommandPayloads`), `coordinator/store/postgres_sandbox_payloads.go` (`RedactSandboxCommandPayloads`) |
| Client behavior | GET remains 200 with expiry metadata; the CLI explicitly reports unavailable expired output; sandbox responses use `Cache-Control: no-store` | `coordinator/api/sandbox_auth.go` (`requireSandboxAuth`), `coordinator/cmd/darkbloom-sandbox/commands.go` (`showCommand`) |

The cutoff defines eligibility, not an instantaneous physical erase deadline;
bounded batches may lag a backlog. Maintenance runs while the sandbox service
is enabled and resumes when it starts again. PostgreSQL row redaction uses
`UPDATE`; it does not delete database backups or rewrite existing WAL.
