# Provider CLI reference

> Last updated: 2026-09-03 · commit `5d400cf75`

Every `darkbloom` subcommand, flag, path and runtime constant, as declared in
`provider-swift/Sources/darkbloom/` (`Darkbloom`, version `ProviderCore.version`
= `0.8.16` in `provider-swift/Sources/ProviderCore/ProviderCore.swift`). Types
and defaults are the ArgumentParser declarations; `—` means required.

## Global options

| Option | Type | Default | Effect | Source |
|---|---|---|---|---|
| `-c`, `--config <path>` | `String?` | `~/.config/darkbloom/provider.toml` | Provider TOML path. Accepted by the commands marked ✓ below | `provider-swift/Sources/darkbloom/Darkbloom.swift` (`ConfigOptions`); `provider-swift/Sources/ProviderCore/Config/ProviderConfig.swift` (`defaultConfigPath`) |
| `--version` | flag | — | Prints `ProviderCore.version` | `Darkbloom.configuration` |
| `-h`, `--help` | flag | — | Help; `darkbloom` with no subcommand prints help | `Darkbloom.run` |

Before most subcommands run, `runUpdateBannerIfEnabled`
(`provider-swift/Sources/darkbloom/Darkbloom.swift`) checks for a newer release
with a 2 s hard timeout and prints a one-line banner; `DARKBLOOM_NO_UPDATE_CHECK`
set to any value skips it. Logging goes to stderr so launchd captures it in
`~/.darkbloom/provider.log`.

## Subcommands

Declaration order of `Darkbloom.configuration.subcommands` (21):

| Command | Purpose | `--config` | Source (`provider-swift/Sources/darkbloom/…`) |
|---|---|---|---|
| `start` | Serve. Default: install and start the LaunchAgent; `--local` for a coordinator-less server | ✓ | `StartCommand.swift` (`Start`) |
| `stop` | Stop the LaunchAgent; `--uninstall` removes both plists | | `StopCommand.swift` (`Stop`) |
| `restart` | Restart the service in place and re-arm the watchdog | ✓ | `RestartCommand.swift` (`Restart`) |
| `status` | Config, hardware, schedule, live daemon state (including the coordinator's last `Trust: <level> / <status>` message), per-slot KV/MTP posture | ✓ | `StatusCommand.swift` (`Status`) |
| `doctor` | Diagnostics (see [troubleshooting](./troubleshooting.md#doctor-checks)) | ✓ | `DoctorCommand.swift` (`Doctor`) |
| `models` | `list`, `catalog`, `download`, `remove` | ✓ | `ModelsCommand.swift` (`Models`) |
| `local` | Print the direct-mode endpoint and API key | | `LocalCommand.swift` (`Local`) |
| `login` | Link the machine to an account (RFC 8628 device code) | ✓ | `LoginCommand.swift` (`Login`) |
| `logout` | Delete the device token | | `LogoutCommand.swift` (`Logout`) |
| `benchmark` | Inference benchmarks and harnesses | ✓ | `BenchmarkCommand.swift` (`Benchmark`) |
| `update` | Self-update | ✓ | `UpdateCommand.swift` (`Update`) |
| `verify` | `doctor --strict` | ✓ | `VerifyCommand.swift` (`Verify`) |
| `enroll` | Fetch and open the MDM enrollment profile | ✓ | `EnrollCommand.swift` (`Enroll`) |
| `unenroll` | Open System Settings to remove the profile; delete local data | | `UnenrollCommand.swift` (`Unenroll`) |
| `logs` | Unified logs for subsystem `dev.darkbloom.provider` | | `LogsCommand.swift` (`Logs`) |
| `report` | Upload recent unified logs to the coordinator | ✓ | `ReportCommand.swift` (`Report`) |
| `autoupdate` | Toggle `provider.auto_update` | ✓ | `AutoUpdateCommand.swift` (`AutoUpdate`) |
| `beta` | `list`, `status`, `enable`, `disable` beta features | ✓ | `BetaCommand.swift` (`Beta`) |
| `fan` | Experimental fan control (`status`, `diagnose`, `enable`, `configure`, `disable`, `uninstall`) | | `Fan/FanCommand.swift` (`Fan`) |
| `watchdog` | Internal, hidden: crash-recovery watchdog process | ✓ | `WatchdogCommand.swift` (`Watchdog`) |
| `runtime-smoke` | Internal, hidden: load packaged Metal runtime and exit | | `RuntimeSmokeCommand.swift` (`RuntimeSmoke`) |

### `darkbloom start`

| Flag | Type | Default | Effect |
|---|---|---|---|
| `--coordinator-url <url>` | `String?` | `coordinator.url` (`wss://api.darkbloom.dev/ws/provider`) | Override the coordinator WebSocket URL |
| `--model <id>` | `[String]`, repeatable | `[]` | Serve exactly these models; skips the picker |
| `--all` | flag | `false` | Serve every local model the runtime supports; skips the picker |
| `--idle-timeout <mins>` | `UInt64?` | `backend.idle_timeout_mins` (`60`) | Override the idle unload timeout for this run |
| `--foreground` / `--no-foreground` | flag, **hidden** | `false` | Serve in this process instead of installing the LaunchAgent; launchd passes it |
| `--local` | flag | `false` | Coordinator-less OpenAI-compatible server ([direct mode](./direct-mode.md)) |
| `--local-endpoint` | flag | `false` | Local endpoint alongside the coordinator; mutually exclusive with `--local` |
| `--port <n>` | `UInt16` | `8000` | Local server port |
| `--bind <addr>` | `String` | `127.0.0.1` | Local server bind address |
| `--no-auth` | flag | `false` | Disable the local bearer-token check |

Exit 1 (`ExitCode.failure`) when `--local` and `--local-endpoint` are combined,
a debugger is attached, RAM is below 8 GB, Metal is unavailable, hardware
detection fails, no model is selected, or the local server does not bind within
5 s (`StartCommand+Preflight.swift`, `StartCommand+Modes.swift`).

### `darkbloom stop`

| Flag | Type | Default | Effect |
|---|---|---|---|
| `--uninstall` | flag | `false` | Also delete `io.darkbloom.provider.plist` and `io.darkbloom.watchdog.plist` |

Disarms the watchdog first, removes `~/.darkbloom/watchdog-state.json`, then
stops the service and disables it in launchd; `darkbloom start` re-enables
auto-start.

### `darkbloom restart`

Only `--config`. Restarts the loaded service in place with its recorded
coordinator URL and models; starts it if installed but not running; exit 1 if
not installed. Re-arms the watchdog when `provider.auto_restart` is `true`,
disarms it when `false`.

### `darkbloom status`

Only `--config`. Read-only. Prints the daemon snapshot (refresh cadence under
[Runtime constants](#runtime-constants)) and the last trust message the
coordinator sent; what the levels mean is in
[attestation](./attestation.md#trust-levels).

### `darkbloom doctor`

| Flag | Type | Default | Effect |
|---|---|---|---|
| `--strict` | flag | `false` | Exit 1 on any WARN as well as FAIL |
| `--coordinator <url>` | `String?` | config URL | Coordinator for the network checks |
| `--support` | flag | `false` | Append coordinator URL, token presence, MDM state, PID-file path |
| `--clear-backend-guard` | flag | `false` | Delete `~/.darkbloom/kv-backend-guard.json`, reset the crash-loop counter in `watchdog-state.json`, exit |

Exit 1 when any detailed check or diagnosis line is FAIL (or WARN with
`--strict`). The check names are listed in
[troubleshooting](./troubleshooting.md#doctor-checks).

### `darkbloom verify`

| Flag | Type | Default | Effect |
|---|---|---|---|
| `--coordinator <url>` | `String?` | config URL | Coordinator for the network checks |

Same checks as `doctor`; any WARN or FAIL exits 1.

### `darkbloom models`

| Subcommand | Flag / positional | Type | Default | Effect |
|---|---|---|---|---|
| `list` | `--json` | flag | `false` | Raw output |
| `list` | `--all` | flag | `false` | Include models filtered out by `backend.enabled_models` |
| `list` | `--hash <model-id>` | `String?` | `nil` | Compute the aggregate SHA-256 of one model |
| `catalog` | `--coordinator <url>` | `String?` | config URL | Catalog source |
| `catalog` | `--json` | flag | `false` | Raw output |
| `catalog` | `--type <t>` | `String?` | `nil` | Filter by `model_type` (e.g. `text`) |
| `download` | `<modelID>` | `String` | — | Catalog id (or S3 name) |
| `download` | `--coordinator <url>` | `String?` | config URL | Resolve the catalog entry |
| `download` | `--r2-cdn <url>` | `String?` | `DARKBLOOM_R2_CDN_URL`, else `https://models.darkbloom.ai` (`provider-swift/Sources/ProviderCore/Models/ModelDownloader.swift`, `defaultR2CDNURL`) | Mirror base URL |
| `remove` | `<modelID>` | `String` | — | Model to delete from `~/.cache/huggingface/hub` |
| `remove` | `--force` | flag | `false` | Skip confirmation |

### `darkbloom local`

| Flag | Type | Default | Effect |
|---|---|---|---|
| `--json` | flag | `false` | Print the raw `~/.darkbloom/local.json` record |

Exit 1 (and `{}` in JSON mode) when no live local server is recorded
(`LocalEndpoint.readLiveInfo`, `provider-swift/Sources/ProviderCore/Server/LocalEndpoint.swift`).

### `darkbloom login` / `darkbloom logout`

`login` takes `--config` only and runs `performDeviceCodeLogin`
(`provider-swift/Sources/ProviderCore/Auth/DeviceAuth.swift`): `POST
/v1/device/code`, print URL and code, poll `POST /v1/device/token`, write
`~/.darkbloom/auth_token`. `logout` takes no flags and deletes that file.

### `darkbloom benchmark`

| Group | Flags (type = default) |
|---|---|
| Throughput | `--model <id>` (`String?`), `--prompt <text>` (`ModelBenchmark.defaultPrompt`), `--iterations <n>` (`ModelBenchmark.defaultIterations`), `--max-tokens <n>` (`ModelBenchmark.defaultMaxTokens`) |
| Scheduler prefill decision | `--scheduler-prefill-decision`, `--expected-model-aggregate-sha256`, `--expected-registered-binary-sha256`, `--expected-version`, `--source-sha`, `--decision-iterations` (`SchedulerPrefillDecisionReport.minimumLiveIterations`), `--output <path>` (`BenchmarkCommand+SchedulerPrefillDecision.swift`) |
| Sweep | `--sweep`, `--prefill-lengths` (`"128,512,2048"`), `--max-batch` (`6`), `--batch-sizes` (`String?`), `--decode-tokens`, `--decode-prompt-tokens`, `--decode-iterations` (`ThroughputSweep` defaults), `--kv-backend` (`"auto"`) (`BenchmarkCommand+Sweep.swift`) |
| Scheduler prefill | `--scheduler-prefill`, `--prefill-iterations` (`2`) |
| Arrival invariance | `--arrival-invariance`, `--arrival-prompt-tokens` (`512`), `--arrival-decode-tokens` (`64`), `--arrival-iterations` (`3`) |
| Backend parity | `--parity`, `--assistant-model <id>` (`String?`), `--parity-max-tokens` (`48`), `--parity-prefix-tokens` (`28672`) (`BenchmarkCommand+Parity.swift`) |

Environment inputs for the harnesses are in
[`reference/configuration.md`](../reference/configuration.md).

### `darkbloom update`

| Flag | Type | Default | Effect |
|---|---|---|---|
| `--coordinator <url>` | `String?` | config URL | Release source |
| `--check-only` | flag | `false` | Report; do not install |
| `--override-quarantine` | flag | `false` | Reinstall a version quarantined after 3 failed starts |

Exit 1 on `quarantined`, `busy`, `cancelled`, `downloadFailed`, `hashMismatch`,
`replaceFailed`, or a failed check (`UpdateResult`, `provider-swift/Sources/ProviderCore/Update/SelfUpdater.swift`).
See [installation → Update](./installation.md#update).

### `darkbloom enroll` / `darkbloom unenroll`

| Command | Flag | Type | Default | Effect |
|---|---|---|---|---|
| `enroll` | `--coordinator <url>` | `String?` | config URL | Coordinator to request the profile from |
| `enroll` | `--no-open` | flag | `false` | Save the `.mobileconfig`; do not open System Settings |
| `unenroll` | `--force` | flag | `false` | Delete config dir, `auth_token` and legacy keys without asking |
| `unenroll` | `--no-open` | flag | `false` | Do not open System Settings |

### `darkbloom logs`

| Flag | Type | Default | Effect |
|---|---|---|---|
| `--file` | flag | `false` | Tail `~/.darkbloom/provider.log` instead of unified logging |
| `-f`, `--follow` | flag | `false` | Stream new lines |
| `--last <duration>` | `String?` | `nil` | `log show --last <duration>`; with `--follow`, history first then live stream |
| `--debug` | flag | `false` | Include debug-level entries (unified logging only) |
| `-l`, `--lines <n>` | `Int` | `50` | Lines to show; only with `--file` |

Without flags: `log stream --predicate 'subsystem == "dev.darkbloom.provider"' --level info`.

### `darkbloom report`

| Flag | Type | Default | Effect |
|---|---|---|---|
| `--last <duration>` | `String` | `24h` | Window of unified logs to collect |
| `--dry-run` | flag | `false` | Print the report; do not upload |

Collects only subsystem `dev.darkbloom.provider` at info level with macOS
privacy redaction intact; uploads only when invoked and prints the `report_id`.

### `darkbloom autoupdate <action>`

| Positional | Type | Default | Effect |
|---|---|---|---|
| `action` | `String` | — (required) | `enable`/`on`/`true`, `disable`/`off`/`false`, or `status`; anything else exits 1 |

Writes `provider.auto_update` to the config file.

### `darkbloom beta`

| Subcommand | Flag / positional | Type | Default | Effect |
|---|---|---|---|---|
| `list` (default) | `--json` | flag | `false` | Table or JSON of every feature with `on`/`off`/`auto` |
| `status` | `[feature]` | `String?` | all | Details for one or all features |
| `enable` | `<feature>` | `String` | — | Write the feature's config key on |
| `disable` | `<feature>` | `String` | — | Write it off |

Feature ids and semantics: [beta features](./beta-features.md).

### `darkbloom fan`

| Subcommand | Flag | Type | Default | Effect | Needs `sudo` |
|---|---|---|---|---|---|
| `status` (default) | `--json` | flag | `false` | Helper install/load state, policy, temperatures | no |
| `diagnose` | `--json` | flag | `false` | Fans and GPU sensors detected | no |
| `enable` | `--speed <pct>` | `Double` | `80` | Target, % of each fan's maximum; `60`–`90` accepted | yes |
| `enable` | `--temperature <C>` | `Double` | `45` | Engage threshold; release is `--temperature − 5` | yes |
| `configure` | `--speed <pct>` | `Double?` | `nil` | Change speed only | yes |
| `configure` | `--temperature <C>` | `Double?` | `nil` | Change threshold only; at least one of the two is required | yes |
| `disable` | — | | | Restore automatic control; keep the helper installed | yes |
| `uninstall` | — | | | Restore automatic control; remove helper and LaunchDaemon | yes |
| `test-lease` (**debug builds only, hidden**) | `--seconds <n>` | `Int` | `30` | Hold a provider activity lease for 1–300 s | no |

Mutations exit 1 with `fan: …` on error; details in [fan control](./fan-control.md).

### `darkbloom watchdog`, `darkbloom runtime-smoke`

Hidden (`shouldDisplay: false`). `watchdog` is the LaunchAgent
`io.darkbloom.watchdog` process; it reads `DARKBLOOM_NO_UPDATE_CHECK`,
`DARKBLOOM_STATE_FILE`, `DARKBLOOM_WATCHDOG_STATE`, `DARKBLOOM_KV_BACKEND_GUARD`
from its plist (`provider-swift/Sources/ProviderCore/Service/WatchdogAgent.swift`).
`runtime-smoke` is dispatched in `provider-swift/Sources/darkbloom/main.swift`
before ArgumentParser, accepts internal positional `shapes`, and is what
`scripts/install.sh` runs against a staged app.

## Exit codes

| Code | Meaning |
|---|---|
| `0` | Success, `--help`, `--version` |
| `1` | `ExitCode.failure` — every runtime error listed above |
| `64` | swift-argument-parser validation error (unknown flag, missing positional, `fan configure` with no option) |

## Paths and identifiers

| Item | Value | Source |
|---|---|---|
| Install root | `~/.darkbloom/` | `scripts/install.sh` (`INSTALL_DIR`) |
| App bundle | `~/.darkbloom/Darkbloom.app`; swapped atomically, backup in `.install-backup-*` during the swap | `scripts/install.sh` (`commit_staged_app`) |
| CLI symlinks | `~/.darkbloom/bin/darkbloom`, `darkbloom-enclave`, `mlx.metallib` → `../Darkbloom.app/Contents/MacOS/*`; `eigeninference-enclave → darkbloom-enclave`; best-effort `/usr/local/bin/darkbloom` | `scripts/install.sh` |
| Capability markers | `Darkbloom.app/Contents/Resources/darkbloom-runtime-capabilities/{paged-kernel-v1,fan-helper-v1}` | `scripts/install.sh` (`verify_staged_app`, `verify_fan_helper_capability`) |
| Config | `~/.config/darkbloom/provider.toml`; a config at a legacy path is copied here on the next run | `provider-swift/Sources/ProviderCore/Config/ProviderConfig.swift` (`defaultConfigPath`); `provider-swift/Sources/darkbloom/Darkbloom.swift` (`migrateConfigIfNeeded`) |
| Device token | `~/.darkbloom/auth_token` (`DARKBLOOM_AUTH_TOKEN_PATH`) | `provider-swift/Sources/ProviderCore/Auth/DeviceAuth.swift` |
| Local-mode token / discovery | `~/.darkbloom/local_token`, `~/.darkbloom/local.json` (`DARKBLOOM_LOCAL_DIR`), both `0600` | `provider-swift/Sources/ProviderCore/Server/LocalEndpoint.swift` |
| Daemon state | `~/.darkbloom/daemon-state.json` (`DARKBLOOM_STATE_FILE`) | `provider-swift/Sources/ProviderCore/Service/DaemonStateFile.swift` |
| PID file | `~/.darkbloom/provider.pid` (`DARKBLOOM_PID_FILE`) | `provider-swift/Sources/ProviderCore/Service/ProcessLifecycle.swift` |
| Warm-model journal | `~/.darkbloom/loaded-models.json` (`DARKBLOOM_LOADED_MODELS_FILE`) | `provider-swift/Sources/ProviderCore/Service/LoadedModelsStore.swift` |
| Watchdog state | `~/.darkbloom/watchdog-state.json` (`DARKBLOOM_WATCHDOG_STATE`) | `provider-swift/Sources/ProviderCore/Service/WatchdogState.swift` |
| KV-backend crash-loop guard | `~/.darkbloom/kv-backend-guard.json` (`DARKBLOOM_KV_BACKEND_GUARD`) | `provider-swift/Sources/ProviderCore/Service/KVBackendGuard.swift` |
| Provider LaunchAgent | label `io.darkbloom.provider`; `~/Library/LaunchAgents/io.darkbloom.provider.plist`; `RunAtLoad = true`, `KeepAlive = false`; stdout/stderr → `~/.darkbloom/provider.log` | `provider-swift/Sources/ProviderCore/Service/LaunchAgent.swift` (`label`, `plistPath`, `logPath`) |
| Watchdog LaunchAgent | label `io.darkbloom.watchdog`; `~/Library/LaunchAgents/io.darkbloom.watchdog.plist`; log `~/.darkbloom/watchdog.log` | `provider-swift/Sources/ProviderCore/Service/WatchdogAgent.swift` |
| Unified-log subsystem | `dev.darkbloom.provider` | `provider-swift/Sources/darkbloom/LogsCommand.swift` (`Logs.subsystem`) |
| Model cache | `~/.cache/huggingface/hub` (HuggingFace hub layout) | `provider-swift/Sources/ProviderCore/Models/ModelDownloader.swift` |
| Keychain KEK item | service `io.darkbloom.kv.kek.v1`; access group `SLDQ2GJ6TL.io.darkbloom.provider` (`DARKBLOOM_KEYCHAIN_ACCESS_GROUP`) | `provider-swift/Sources/ProviderCore/KVCache/WrappedKEKStorage.swift` (`defaultService`); `provider-swift/Sources/ProviderCore/Security/PersistentEnclaveKey.swift` (`defaultAccessGroup`) |
| Secure Enclave key labels | `io.darkbloom.provider.attestation-signing.v2`; legacy `…v1` migrated on first use | `provider-swift/Sources/ProviderCore/Security/PersistentEnclaveKey.swift` (`defaultLabel`, `legacyLabelV1`) |
| Apple Team ID | `SLDQ2GJ6TL` (pinned in installer requirements and fan IPC) | `scripts/install.sh`; `provider-swift/Sources/DarkbloomFanProtocol/FanIPC.swift` (`teamID`) |
| Fan helper files | `/Library/PrivilegedHelperTools/io.darkbloom.fan-helper`, `/Library/LaunchDaemons/io.darkbloom.fan.plist`, `/Library/Application Support/Darkbloom/fan-policy.json`, `…/fan-session.json` | `provider-swift/Sources/DarkbloomFanService/FanServiceConfiguration.swift` |

### `provider.toml` keys read by the CLI

Defaults are the `ProviderConfig` initialisers
(`provider-swift/Sources/ProviderCore/Config/ProviderConfig.swift`); a missing
key decodes to its default. The full schema, including startup preload,
per-model tables and every environment variable, is in
[`reference/configuration.md`](../reference/configuration.md).

| Key | Default | Effect |
|---|---|---|
| `[provider] memory_reserve_gb` | `4` | Unified memory withheld from model admission |
| `[provider] auto_update` | `true` | Startup + periodic self-update |
| `[provider] auto_restart` | `true` | Arm the watchdog LaunchAgent |
| `[provider] update_jitter_seconds` | `300` | Max random delay before an automatic install |
| `[backend] enabled_models` | `[]` | Advertise only these ids; empty = all serveable |
| `[backend] idle_timeout_mins` | `60` | Unload a model idle this long; `0` disables |
| `[backend] max_model_slots` | `3` | Resident models |
| `[backend] engine_v2_max_concurrent` | `4` (clamped to `[1, 8]`) | Concurrent requests per engine |
| `[backend] engine_v2_kv_backend` | `"auto"` | `auto` / `paged` / `contiguous`; per-model table `engine_v2_kv_backend_by_model` |
| `[backend] mtp_mode` | `auto` | Written by `darkbloom beta enable|disable mtp` |
| `[backend] startup_preload` | `true` | Load advertised models at start |
| `[coordinator] url` | `"wss://api.darkbloom.dev/ws/provider"` | |
| `[coordinator] heartbeat_interval_secs` | `5` | Heartbeat; state file refresh is half of it |
| `[coordinator] private_only` | `false` | Serve only the owner's [self-route](./self-route.md) traffic |
| `[gemma_optimizations] prefill_layer18`, `weighted_r1` | `true` | See [beta features](./beta-features.md) |
| `config_version` | written by the CLI | Schema stamp for one-time migrations |
| `[backend] continuous_batching`, `adaptive_prefill`, `engine_v2`, `legacy_compiled_decode`, `kv_quant` | retired | Parsed for presence only; one startup WARN each (`RetiredCodingKeys`) |

## LaunchAgent environment passthrough

`darkbloom start` copies only these variables from the invoking shell into the
provider plist's `EnvironmentVariables`
(`provider-swift/Sources/ProviderCore/Service/LaunchAgent.swift`,
`passthroughEnvKeys` + `inferencePassthroughEnvKeys`,
`passthroughEnvironment`). Every other variable — including `PATH` and all the
media, prefix-cache-SSD and memory-cap tunables — reaches the engine only under
`darkbloom start --foreground` or `--local`. Effects and defaults are specified
once in [`reference/configuration.md`](../reference/configuration.md).

| Variable | Read by |
|---|---|
| `DARKBLOOM_PREFIX_CACHE` | `provider-swift/Sources/ProviderCore/Inference/PrefixCachePolicy.swift` (`environmentFlag`) |
| `DARKBLOOM_MLX_RESOURCE_DEBUG` | forwarded to `mlx-swift-lm` |
| `DARKBLOOM_CBV2_PAGED_KV` | `provider-swift/Sources/ProviderCore/Inference/EngineV2KVBackendPolicy.swift` |
| `DARKBLOOM_CBV2_MTP` | `provider-swift/Sources/ProviderCore/SpecDec/SpecDecArtifactFunnel.swift` |
| `DARKBLOOM_MTP_MAX_RECTANGULAR_TOKENS` | MTP verification policy (tighten-only cap) |
| `DARKBLOOM_KV_BACKEND_GUARD` | `provider-swift/Sources/ProviderCore/Service/KVBackendGuard.swift` |
| `DARKBLOOM_MLX_CACHE_LIMIT_GB` | `provider-swift/Sources/ProviderCore/Inference/MLXMemoryGuard.swift` (default `defaultCacheLimitGB = 8`) |
| `DARKBLOOM_MLX_MEMORY_RESERVE_GB` | `provider-swift/Sources/ProviderCore/Inference/MLXMemoryGuard.swift` |
| `DARKBLOOM_CBV2_MAX_PARTIAL_PREFILLS` | `provider-swift/Sources/ProviderCore/Inference/EngineV2Factory+Production.swift` (`maxPartialPrefillsKey`) |
| `DARKBLOOM_PREFILL_DEADLINE_MODE` | `provider-swift/Sources/ProviderCore/Inference/PrefillDeadlineMode.swift` (`environmentKey`) |
| `MLX_GATHER_QMM_EXPERT_SLICES` | only when the shell value is exactly `1` (`GemmaOptimizationEnvironment.daemonDrainPassthrough`, `provider-swift/Sources/ProviderCore/Config/GemmaOptimizationEnvironment.swift`) |

The watchdog plist carries its own list: `DARKBLOOM_NO_UPDATE_CHECK`,
`DARKBLOOM_STATE_FILE`, `DARKBLOOM_WATCHDOG_STATE`, `DARKBLOOM_KV_BACKEND_GUARD`
(`provider-swift/Sources/ProviderCore/Service/WatchdogAgent.swift`).
`DARKBLOOM_NO_UPDATE_CHECK` is **not** forwarded to the provider daemon; disable
automatic updates with `darkbloom autoupdate disable`.

## Runtime constants

| Constant | Value | Source |
|---|---|---|
| Coordinator reconnect backoff | `ExponentialBackoff(base: 1.0, max: 30.0)` s | `provider-swift/Sources/ProviderCore/Coordinator/CoordinatorClient+Connection.swift` |
| WebSocket ping interval / pong timeout | `pingInterval = 10.0` s / `pongTimeout = 30.0` s | same |
| Heartbeat | `heartbeat_interval_secs` = `5` | `provider-swift/Sources/ProviderCore/Config/ProviderConfig.swift` |
| State-file and capacity refresh | every `max(1, heartbeat / 2)` s → 2 s | `provider-swift/Sources/ProviderCore/ProviderLoop+Capacity.swift` |
| State-file stale threshold | `isStale(maxAge: 90)` s; `doctor` calls the daemon wedged after `max(8 × refresh period, 90)` s | `provider-swift/Sources/ProviderCore/Service/DaemonStateFile.swift`; `provider-swift/Sources/darkbloom/Diagnostics/KVBackendPosture.swift` (`wedgedAfterSeconds`) |
| Idle unload | `idle_timeout_mins = 60`; polled every 60 s; unloads the model, the daemon keeps running | `provider-swift/Sources/ProviderCore/ProviderLoop+IdleTimeout.swift` |
| Watchdog check interval | `checkIntervalSeconds = 60` | `provider-swift/Sources/ProviderCore/Service/WatchdogAgent.swift` |
| Crash-loop guard trip | `crashLoopTripThreshold = 3` restarts | `provider-swift/Sources/ProviderCore/Service/WatchdogDecision.swift` |
| Auto-update first check / interval / drain | `300` s / `1800` s / `120` s | `provider-swift/Sources/ProviderCore/ProviderLoop+AutoUpdate.swift` (`autoUpdateInitialDelay`, `autoUpdateInterval`, `updateDrainTimeout`) |
| Update quarantine | `rollbackThreshold = 3`; `defaultStabilizationSeconds = 600` | `provider-swift/Sources/ProviderCore/Update/UpdateRecoveryState.swift` |
| Release endpoint | `GET /v1/releases/latest?platform=macos-arm64` | `provider-swift/Sources/ProviderCore/Update/SelfUpdater.swift` |
| Update banner timeout | 2 s | `provider-swift/Sources/ProviderCore/Update/UpdateBanner.swift` |
| Local chat body cap | `localInferenceMaxUploadBytes = 32 * 1024 * 1024` | `provider-swift/Sources/ProviderCore/Server/LocalChatUploadResponder.swift` |
| Local bind wait | 5 s | `provider-swift/Sources/darkbloom/StartCommand+Modes.swift` (`waitUntilBound`) |
| Fan lease / renewal | `leaseDurationSeconds = 15` / `renewalIntervalSeconds = 5` | `provider-swift/Sources/DarkbloomFanProtocol/FanIPC.swift` |
| Fan policy defaults | trigger `45` °C, release `40` °C, speed `80` %, engage after `3` samples, release after `30`; speed range `60`–`90` | `provider-swift/Sources/DarkbloomFanCore/FanPolicy.swift` |
| Minimum RAM to serve | 8 GB | `provider-swift/Sources/darkbloom/StartCommand+Preflight.swift` |

## Related

- [Installation](./installation.md) · [Quickstart](./quickstart.md) · [Troubleshooting](./troubleshooting.md)
- [Direct mode](./direct-mode.md) · [Self-route](./self-route.md) · [Fan control](./fan-control.md) · [Beta features](./beta-features.md)
- [`reference/configuration.md`](../reference/configuration.md) — every environment variable and config key.
- [Attestation](./attestation.md) — trust levels; [`architecture/security/attestation.md`](../architecture/security/attestation.md) for the mechanism.
