# Configuration reference

> Last updated: 2026-10-09

Provider CLI and native-runtime environment variables, compiled defaults and reading symbols. Secrets are named, never valued. Unless specified otherwise, values are read at process start.

Coordinator and web-application settings belong to the [platform configuration reference](https://github.com/Layr-Labs/darkbloom-platform/blob/48a198c71a2d30feec5597bacf1101120f7f955d/docs/reference/configuration.md).

## Runtime metallib snapshots

The provider creates an anonymous snapshot before binding the runtime metallib.

| Variable | Default / accepted values | Consumer |
|---|---|---|
| `TMPDIR` | When absent, Foundation's temporary directory. When present, an absolute path without NUL bytes to an existing writable directory; invalid or inaccessible values fail snapshot creation without fallback. Read when creating the snapshot. | `provider-swift/Sources/ProviderCore/Security/BinaryHasher.swift` (`makeRuntimeMetallibSnapshot`) |

Set `TMPDIR` in the environment of the process that serves inference. A shell
export applies to `darkbloom start --foreground` and `darkbloom start --local`.
For background `darkbloom start`, it applies to the invoking CLI's startup
snapshot, but is not copied into the installed provider's launchd environment:
`TMPDIR` is not in `LaunchAgent.passthroughEnvKeys`
(`provider-swift/Sources/ProviderCore/Service/LaunchAgent.swift`,
`passthroughEnvironment`). See [LaunchAgent environment passthrough](../provider/cli-reference.md#launchagent-environment-passthrough).
This setting does not grant sandbox permissions or change snapshot binding checks.

## Provider drain deadline

| Setting | Default / bounds | Consumer |
|---|---|---|
| `darkbloom start/stop/restart/update --timeout` | `600` seconds; 0–3600 | `provider-swift/Sources/darkbloom/ServiceDrain.swift` (`DrainOptions`) |
| `darkbloom switch --timeout` | `600` seconds; 0–3600; `0` means no waiting for unfinished work, with a 30-second barrier allowance when already settled; no force mode | `provider-swift/Sources/darkbloom/SwitchCommand.swift` (`Switch`); `provider-swift/Sources/ProviderCore/ProviderLoop+ModelSwitch.swift` (`drainForModelSwitch`) |
| `darkbloom restart --startup-timeout` | `180` seconds; 1–3600 | `provider-swift/Sources/darkbloom/RestartCommand.swift` (`Restart`) |
| `DARKBLOOM_DRAIN_TIMEOUT_SECONDS` | `600` seconds when missing/invalid; valid 1–3600 | Signal/AppKit and planned metadata-reconnect drain in `provider-swift/Sources/ProviderCore/Service/ProviderTermination.swift` (`timeoutSeconds`); launchd environment allowlist preserves it |
| launchd `ExitTimeOut` | `3660` seconds on install or CLI restart | `provider-swift/Sources/ProviderCore/Service/LaunchAgent.swift` (`makeServicePlist`, `refreshTerminationAllowance`) |

A start/stop/restart/update CLI deadline expiry leaves a running, non-admitting
process and disables watchdog/login restart. A `switch` timeout also keeps
accepted work alive and admission closed, but never changes recovery settings.
Signal-only shutdown preserves configured login startup. See [lifecycle commands](../provider/cli-reference.md#graceful-stop-and-restart)
for recovery and explicit force semantics. Existing loaded launchd jobs must be
restarted to adopt the new allowance. Local mailbox files are owner-only under
`lifecycle/` beside the daemon state file and bind PID plus kernel process-start
time; they are not network control endpoints or serving credentials.

## Provider model selection

| Setting | Default / precedence | Consumer |
|---|---|---|
| `backend.enabled_models` | `[]` means all eligible local models; a successful `switch` pins its complete nonempty selection | `provider-swift/Sources/ProviderCore/Service/ProviderModelSelection.swift` (`save`) |
| launchd-managed `start --foreground --model` | Explicitly pinned `enabled_models` overrides stale baked arguments, including restart and watchdog recovery | `provider-swift/Sources/darkbloom/Start/StartCommand.swift` (`usesPinnedModelSelection`); `provider-swift/Sources/darkbloom/Start/StartCommand+Modes.swift` (`runForeground`) |
| direct manual `start --foreground --model` | Explicit command-line IDs still override the saved selection | `provider-swift/Sources/darkbloom/Start/StartCommand+Modes.swift` (`runForeground`) |
| later scheduled serving windows | Read full current Autopilot settings/consent plus saved selection. Disabling between windows restores ordinary `enabled_models` even if unchanged; otherwise keep the initial foreground selection until a live switch or saved selection change. Resolve an empty ordinary list to eligible local models, validate/hash before reopening and retain the original window end. All other inputs remain frozen | `provider-swift/Sources/darkbloom/ScheduledWindowSelection.swift` (`ScheduledWindowSelection`); `provider-swift/Sources/darkbloom/Start/StartCommand+Modes.swift` (`runScheduled`) |

Ordinary non-enrolled `start` saves its selected models under the lifecycle lease before disabling
recovery or draining/stopping the current daemon; persistence failure leaves it
running. Live [`switch`](../provider/cli-reference.md#darkbloom-switch) uses the running
daemon's resolved config path and does not optimistically write from the CLI.
The daemon persists the accepted selection using a stable config sidecar lock,
reloading before saving so unrelated settings survive concurrent config writes.
`darkbloom autoupdate enable` and `disable` use that lock and reload before
saving `provider.auto_update`, so they preserve a concurrent switch selection
(`provider-swift/Sources/darkbloom/AutoUpdateCommand.swift`, `setAutoUpdate`).
Other config changes remain process-start settings unless documented otherwise.
For replacement start, the same sidecar lock covers saving and synchronous
drain setup. Setup failure restores the original bytes or file absence, so
legacy unpinned selections stay unpinned; a timeout after publication retains
the new intent. The lock is released before waiting for drain completion
(`ProviderModelSelection.withReplacement` in
`provider-swift/Sources/ProviderCore/Service/ProviderModelSelection.swift`).
Missing explicit config paths use the already-resolved startup/loop configuration,
never another path's canonical config. Live switch stages a presence-aware
rollback snapshot, releases the lock for the network wait, and restores only its
model-selection key when other settings changed concurrently. A newer selection
causes a reported conflict instead of being overwritten (`stageReplacement`,
`restore` in the same module).


## Provider CLI (`darkbloom`)

Parsing convention: affirmative values are `1`/`true`/`yes`/`on`, negative values `0`/`false`/`no`/`off`, case-insensitive. Only the variables named in the LaunchAgent allow-list above reach an installed daemon; everything else applies to `darkbloom start --foreground` and to the benchmark and test binaries.

### Startup model preload

Serving concurrency is resolved after the model's KV backend and verified
artifact are known. `BackendSettings.engineV2MaxConcurrentIsExplicit`
distinguishes an absent `engine_v2_max_concurrent` key (automatic, legacy
default `4` until an exact reviewed profile applies) from any existing literal
operator cap. Serialization preserves that distinction; historical literal
values are not silently raised. Per-model overrides remain explicit limits.
Daemon and standalone engines use the same profile resolver and preserve
narrower architecture and physical memory constraints. `darkbloom status` and
`doctor` explain the selection. See [qualification](../developer/serving-performance-qualification.md).

Startup loading is independent of the idle-unload policy. The default
preloads selected models on coordinator-connected and standalone `--local`
starts and at each scheduled window opening, never before that opening; an
explicit list takes precedence within the selected serving set. All loads retain
the normal memory and slot admission checks, and a failed preload remains
request-loadable. The [availability wizard](../provider/cli-reference.md#darkbloom-schedule)
sets the existing `startup_preload` key, not a separate scheduling preload key.

| `provider.toml` key | Default | Effect and reader |
|---|---|---|
| `[backend] startup_preload` | `true` | Enable startup/window-opening loading in `ProviderLoop.runStartupPreloadGate` and `Start.runLocalStandalone`; wizard on-demand mode sets `false`, skipping preload but not coordinator load commands or request-triggered loads (`provider-swift/Sources/ProviderCore/Config/ProviderConfig.swift`, `BackendSettings`). |
| `[backend] preload_models` | `[]` | Explicit startup order when nonempty; otherwise selected models, with the previously loaded set first on coordinator starts (`ProviderLoop.startupPreloadPlan`, `StandaloneServer.startupPreloadPlan`). |
| `[backend] startup_preload_timeout_secs` | `120` | Maximum delay before coordinator registration; remaining loads continue in the background. Standalone `--local` finishes its preload before opening the listener (`ProviderLoop.runStartupPreloadGate`, `Start.runLocalStandalone`). |
| `[backend] startup_selftest` | `true` | Coordinator-connected startup runs a one-token serving-path decode after each load; standalone `--local` loads weights and the engine but does not run this decode (`ProviderLoop.runStartupPreloadGate`, `StandaloneServer.preloadSelectedModels`). |
| `[backend] startup_selftest_fail_closed` | `false` | Coordinator-connected self-test failures can retire the model when enabled; there is no synthetic self-test or fail-closed retirement in standalone `--local` (`ProviderLoop.runStartupPreloadGate`, `StandaloneServer.preloadSelectedModels`). |
| `[backend] idle_timeout_mins` | `60` | Controls later idle unloading for coordinator serving, not whether models load at startup (`provider-swift/Sources/ProviderCore/ProviderLoop+IdleTimeout.swift`, `ProviderLoop.startupPreloadPlan`). |

### Provider availability

Weekly availability lives in `provider.toml`; command behavior and presets are
in the [schedule CLI reference](../provider/cli-reference.md#darkbloom-schedule).

| `provider.toml` key | Default / accepted values | Effect and reader |
|---|---|---|
| `[schedule] enabled` | Schedule absent by default; `ScheduleConfig.enabled = false` | Disabled/absent means available while running. Enabled requires valid windows; disabled schedules retain windows without validating them (`provider-swift/Sources/ProviderCore/Scheduling/ScheduleConfig.swift`, `ScheduleConfig.validate`; `provider-swift/Sources/ProviderCore/Scheduling/Schedule.swift`, `Schedule.from`) |
| `[[schedule.windows]] days` | Nonempty array of case-insensitive short/full day names, `mon`/`monday` through `sun`/`sunday` | Days when the window starts; wizard shorthands/ranges are expanded before saving (`provider-swift/Sources/ProviderCore/Scheduling/Schedule.swift`, `DayOfWeek.parse`; `provider-swift/Sources/darkbloom/Scheduling/ScheduleWizard.swift`, `ScheduleWizard.parseDays`) |
| `[[schedule.windows]] start` | Required `HH:MM`, `00:00`-`23:59` | Inclusive opening in this Mac's local time (`provider-swift/Sources/ProviderCore/Scheduling/ScheduleConfig.swift`, `ScheduleWindow`; `provider-swift/Sources/ProviderCore/Scheduling/Schedule.swift`, `TimeOfDay.parse`, `Schedule.isActive`) |
| `[[schedule.windows]] end` | Required `HH:MM`, `00:00`-`23:59` | Exclusive close; earlier end crosses midnight, equal start/end spans a local-calendar day (`provider-swift/Sources/ProviderCore/Scheduling/Schedule.swift`, `Schedule.from`; `provider-swift/Sources/ProviderCore/Scheduling/ScheduleIntervals.swift`, `Schedule.intervals`) |

```toml
[schedule]
enabled = true

[[schedule.windows]]
days = ["mon", "tue", "wed", "thu", "fri"]
start = "22:00"
end = "08:00"
```

`darkbloom schedule --disable` preserves windows and `startup_preload`.
The editor changes only availability and `startup_preload`, retaining
`preload_models`, selected models and idle timeout (`ScheduleSettings.apply`
in `provider-swift/Sources/darkbloom/Scheduling/ScheduleSettings.swift`).
Both `schedule` and `start --schedule` support `--config`. Edits require the
next start/restart; they are not a live daemon update. Availability applies to
coordinator serving and attached `--local-endpoint`, not standalone `--local`
(`Start.run` in `provider-swift/Sources/darkbloom/Start/StartCommand.swift`).
There is no saved timezone or wake-up setting: keep the Mac awake and use its
local timezone. [Scheduling architecture](https://github.com/Layr-Labs/darkbloom-platform/blob/48a198c71a2d30feec5597bacf1101120f7f955d/docs/architecture/scheduling.md#provider-availability-windows)
defines DST adjustment, merged windows, full-week coverage and fail-closed parsing.

### Model cache location

Model-cache changes require explicit operator selection, not a beta flag.
Discovery, downloads, hashing and removal share `ModelScanner.resolveCache`
(`provider-swift/Sources/ProviderCoreFoundation/ModelScanner+CacheDirectory.swift`).
The selected directory is a hub root containing
`models--<org>--<name>/snapshots/<revision>`, not a single model snapshot.

Snapshot discovery accepts a directory symlink only when its canonical target
is a directory. It retains the original snapshot entry's modification-date
ordering and returns the canonical target. Broken, file, FIFO, hidden and cyclic
snapshot entries do not become model directories
(`provider-swift/Sources/ProviderCoreFoundation/ModelScanner.swift`, `findLatestSnapshot`).

| Runtime setting | Cache directory | Reader |
|---|---|---|
| `[backend] model_cache_directory` in `provider.toml` | Explicit saved path; unset by default | `ConfigManager.modelCacheDirectory`, `provider-swift/Sources/ProviderCore/Config/ModelCacheConfiguration.swift` |
| No saved location | Unchanged `~/.cache/huggingface/hub` | `ModelScanner.homeCacheDirectory` |

**Existing providers keep the legacy cache until a location is explicitly saved,**
even when Hugging Face/XDG variables are already exported. Those variables are
not runtime cache overrides and are not forwarded into the provider LaunchAgent.
Status, inspection, menu cancellation, and upgrading do not save a location.

[`darkbloom models location`](../provider/cli-reference.md#darkbloom-models-location)
saves an absolute path from a direct argument or confirmed menu selection.
`--from-env` explicitly imports the current environment-selected directory once
and saves its concrete path. Only that import uses `ModelScanner.resolveEnvironmentCache`
with the following first-valid-value precedence:

| Import priority | Variable | Candidate directory | Reader |
|---|---|---|---|
| 1 | `HF_HUB_CACHE` | The value itself | `ModelScanner.resolveEnvironmentCache` |
| 2 | `HUGGINGFACE_HUB_CACHE` | The value itself (legacy alias) | `ModelScanner.resolveEnvironmentCache` |
| 3 | `HF_HOME` | `<value>/hub` | `ModelScanner.resolveEnvironmentCache` |
| 4 | `XDG_CACHE_HOME` | `<value>/huggingface/hub` | `ModelScanner.resolveEnvironmentCache` |

No valid variable means the import fails without saving. Blank, NUL-containing
or unexpandable `~user` values are ignored; other paths retain significant
whitespace. The selected candidate must be an existing readable, searchable,
writable directory. A missing/unusable higher-priority path does not silently
fall through to another directory. Later environment changes never redirect a
saved path; import again explicitly if that is intended. Hugging Face tools do
not read Darkbloom's TOML key.

`--reset` removes the saved setting and restores the legacy default, regardless
of ambient variables. Hand-written relative config paths are relative to the
TOML file. Invalid saved paths fail loading; reset or an explicit valid selection
can repair them. Inspection with `--check PATH` is independent of saved config.
Missing or empty selected caches never cause fallback to another cache. Symlink
resolution preserves filesystem traversal failures rather than erasing a missing
or non-directory component before `..`.

The command never moves weights or restarts a provider. Apply a saved change with
`darkbloom restart` (or `darkbloom start` if stopped). The CLI reports its selected
config, not proof that an already-running daemon has adopted a new setting.

The selected cache root also holds `.artifact-writer-locks`, whose persistent
per-model lock files coordinate downloads, revision activation and
[`models remove`](../provider/cli-reference.md#darkbloom-models-remove-id).
They remain outside removed model directories; do not delete them while a
provider or model command is running. Code:
`provider-swift/Sources/ProviderCore/Models/ModelArtifactWriteLease.swift`
(`openDescriptor`).

### Operator-facing: daemon, paths, updates

| Variable | Values / type | Default | Read in | Effect |
|---|---|---|---|---|
| `DARKBLOOM_NO_UPDATE_CHECK` | any value | unset | `provider-swift/Sources/darkbloom/Darkbloom.swift`; `provider-swift/Sources/darkbloom/Start/StartCommand+Modes.swift`; `provider-swift/Sources/darkbloom/WatchdogCommand.swift`; `provider-swift/Sources/ProviderCore/ProviderLoop+AutoUpdate.swift`; forwarded by `provider-swift/Sources/ProviderCore/Service/WatchdogAgent.swift` | Skips the startup version banner, the in-daemon auto-update loop, the start-mode check and the watchdog's update check; `scripts/install.sh` sets it for the runtime smoke test. |
| `DARKBLOOM_AUTH_TOKEN_PATH` | file path | `~/.darkbloom/auth_token` | `provider-swift/Sources/ProviderCore/Auth/DeviceAuth.swift` | A nonempty explicit path replaces the token path. Without it, the token is read only from `~/.darkbloom/auth_token` (for `sudo darkbloom report`, the invoking user's, read-only through `AuthTokenStore.loadReadOnly`); there is no legacy-path fallback. |
| `DARKBLOOM_LOCAL_DIR` | directory | `~/.darkbloom` | `provider-swift/Sources/ProviderCore/Server/LocalEndpoint.swift` | Directory for `local_token` and `local.json` (direct mode). |
| `DARKBLOOM_STATE_FILE` | file path | `~/.darkbloom/daemon-state.json` | `provider-swift/Sources/ProviderCore/Service/DaemonStateFile.swift` | Daemon state snapshot read by `status`, `doctor` and the watchdog. |
| `DARKBLOOM_LOADED_MODELS_FILE` | file path | `~/.darkbloom/loaded-models.json` | `provider-swift/Sources/ProviderCore/Service/LoadedModelsStore.swift` | Warm-model journal. |
| `DARKBLOOM_PID_FILE` | file path | `~/.darkbloom/provider.pid` | `provider-swift/Sources/ProviderCore/Service/ProcessLifecycle.swift` | Daemon PID file. |
| `DARKBLOOM_WATCHDOG_STATE` | file path | `~/.darkbloom/watchdog-state.json` | `provider-swift/Sources/ProviderCore/Service/WatchdogState.swift` | Watchdog arm/disarm state. |
| `DARKBLOOM_KV_BACKEND_GUARD` | absolute file path | `~/.darkbloom/kv-backend-guard.json` | `provider-swift/Sources/ProviderCore/Service/KVBackendGuard.swift` | Crash-loop guard record; on the LaunchAgent allow-list so the watchdog and daemon share one file. |
| `DARKBLOOM_R2_CDN_URL` | URL | `https://models.darkbloom.ai` | `provider-swift/Sources/ProviderCore/Models/ModelDownloader.swift` | Mirror model weights are downloaded from. |
| `DARKBLOOM_KEYCHAIN_ACCESS_GROUP` | access group | `SLDQ2GJ6TL.io.darkbloom.provider` | `provider-swift/Sources/ProviderCore/Security/PersistentEnclaveKey.swift` | Keychain access group for the Secure Enclave key items. |
| `DARKBLOOM_MLX_RESOURCE_DEBUG` | `0` quiets | unset (telemetry on) | forwarded only, `provider-swift/Sources/ProviderCore/Service/LaunchAgent.swift` | MLX resource telemetry switch consumed by `mlx-swift-lm`. |

### Engine and scheduler

Serving acceptance is config-backed, not an environment override. Its default
and rollback are defined in the [provider configuration reference](../provider/cli-reference.md#providertoml-keys-read-by-the-cli).

| Config key | Default | Read in | Effect |
|---|---|---|---|
| `[backend] mtp_acceptance`, `mtp_acceptance_by_model` | unset resolves to `typical` (delta `0.2`); model map `{}` | `provider-swift/Sources/ProviderCore/Inference/MTP/MTPAcceptancePolicy.swift` (`resolve`) | Exact model override precedes global, then the built-in default. Eligible sampled target-prefix MTP output is approximate, not distribution-exact; explicit `exact` opts out and invalid values safely resolve to `exact`. Greedy behavior and native MiMo exact acceptance are unchanged. Does not enable disabled MTP or widen eligibility. |

| Variable | Values / type | Default | Read in | Effect |
|---|---|---|---|---|
| `DARKBLOOM_CBV2_PAGED_KV` | `0` forces contiguous | unset (policy decides) | `provider-swift/Sources/ProviderCore/Inference/Engine/EngineV2KVBackendPolicy.swift` (`preferredBackend`, `killSwitchDisabled`) | Kill switch for paged KV; beats the `provider.toml` setting. The [owned Flash-Next candidate](qwen4-next-support.md#identity-and-serving-policy) joins the exact automatic policy; a default is not runtime qualification. |
| `DARKBLOOM_CBV2_PAGED_KV_DTYPE` | `float16`, `float32` | unset: observed native per-layer types | `provider-swift/Sources/ProviderCore/Inference/Engine/Factory/EngineV2Factory+BackendPreparation.swift` | Optional assertion for resolved paged storage; a nonempty value must match every measured native layer. Unsupported values or mismatches refuse explicit paged construction. |
| `DARKBLOOM_CBV2_SOLO_PREFILL_STRIPE` | tokens | engine default | `provider-swift/Sources/ProviderCore/Inference/Engine/Factory/EngineV2Factory+Configuration.swift` | Solo-prefill stripe size. |
| `DARKBLOOM_CBV2_MIXED_PREFILL_CAP` | nonnegative tokens | reviewed profile cap; otherwise uncapped | `provider-swift/Sources/ProviderCore/Inference/Performance/MixedPrefillPolicy.swift` (`resolve`) | Caps prompt tokens in steps that also decode. Positive Gemma caps have a 128-token minimum; `0` defers prefill while decode is active. Does not change the pure-prefill stripe. Foreground/local only. |
| `DARKBLOOM_CBV2_MIXED_PREFILL_CAP_BY_MODEL` | comma-separated `model-id=tokens` | unset | `provider-swift/Sources/ProviderCore/Inference/Performance/MixedPrefillPolicy.swift` (`resolve`) | Exact model-ID overrides take precedence over the global cap, then the reviewed profile. Same nonnegative parsing and Gemma minimum; malformed entries are ignored. Foreground/local only. |
| `DARKBLOOM_CBV2_MAX_PARTIAL_PREFILLS` | integer (`0` = unlimited) | `1` | `provider-swift/Sources/ProviderCore/Inference/Engine/Factory/EngineV2Factory+Configuration.swift` | Maximum concurrent partial prefills. |
| `DARKBLOOM_CBV2_LEGACY_REQUEST_TIMEOUT` | affirmative | off | `provider-swift/Sources/ProviderCore/Inference/Engine/Factory/EngineV2Factory+Configuration.swift` | Restores the legacy per-request timeout. |
| `DARKBLOOM_CBV2_MTP` | negative disables | unset (beta flag decides) | `provider-swift/Sources/ProviderCore/SpecDec/SpecDecArtifactFunnel.swift`; `provider-swift/Sources/ProviderCore/Config/BetaFeatures.swift` | Kill switch for MTP speculation; beats the `provider.toml` beta flag. See [`../provider/beta-features.md`](../provider/beta-features.md). |
| `DARKBLOOM_MTP_MAX_RECTANGULAR_TOKENS` | integer | policy default | `provider-swift/Sources/ProviderCore/Inference/MTP/MTPAutomaticVerificationPolicy.swift` | Tighten-only cap on rectangular MTP verification tokens. |
| `DARKBLOOM_NEMOTRON35_MTP_CAPTURE_VERIFY` | exact `0` disables | on | `libs/mlx-swift-lm/Libraries/MLXLLM/Models/NemotronH35MTP.swift` (`requiredVerificationMode`) | Captured rectangular verification with every-prefix recurrent state; `0` uses serial target verification. Not forwarded to LaunchAgents. |
| `DARKBLOOM_NEMOTRON35_MTP_BATCHED_M1` | exact `0` disables | on | `libs/mlx-swift-lm/Libraries/MLXLLM/Models/NemotronH35MTPExactRows.swift` (`NemotronMTPExecution`) | Batch-axis projection dispatch that retains matrix M=1. No change to target precision; not forwarded to LaunchAgents. |
| `DARKBLOOM_NEMOTRON35_MTP_KV_ONLY_HISTORY` | exact `0` disables | on | `libs/mlx-swift-lm/Libraries/MLXLLM/Models/NemotronH35MTP.swift` (`NemotronH35MTPAssistant`) | Trusted-history replay may compute only the embedded assistant's K/V. Prefix save/restore uses the separate typed history codec. Not forwarded to LaunchAgents. |
| `DARKBLOOM_NEMOTRON35_MTP_MAX_DRAFT_TOKENS` | integer `1`…`7` | `7` | `libs/mlx-swift-lm/Libraries/MLXLLM/Models/NemotronH35MTP.swift` (`NemotronH35MTPAssistant`) | Upper proposal limit for adaptive depth; invalid selected limits fall back to seven. This is not a fixed proposal count. Not forwarded to LaunchAgents. |
| `DARKBLOOM_MTP_VERIFICATION_MODE` | `rectangular`, `serial`, `serial_target`, `automatic` | `automatic` | `provider-swift/Sources/ProviderBenchmark/MTPProductionSession.swift` | MTP verification strategy (benchmark session). |
| `DARKBLOOM_MTP_ACCEPTANCE` | `exact`, `typical`, `typical:<delta>` (finite positive delta) | `exact` | `provider-swift/Sources/ProviderBenchmark/MTPProductionSession.swift`; `provider-swift/Sources/ProviderCore/Inference/MTP/MTPAcceptancePolicy.swift` (`benchmarkOverride`) | MTP draft acceptance rule (benchmark session only). An unrecognized value uses `exact`. Serving reads no environment variable for this rule; it reads `[backend] mtp_acceptance` and `mtp_acceptance_by_model` in [`provider.toml`](../provider/cli-reference.md#providertoml-keys-read-by-the-cli). |
| `DARKBLOOM_PREFILL_DEADLINE_MODE` | `off`, `enforce` | `off` | `provider-swift/Sources/ProviderCore/Inference/Engine/PrefillDeadlineMode.swift` | Prefill-deadline admission on the provider. |
| `DARKBLOOM_GEMMA4_PREFILL_CHUNK_EVAL` | integer layers | projected from `provider.toml` (`18`) | `provider-swift/Sources/ProviderCore/Config/GemmaOptimizationEnvironment.swift` | Gemma-4 prefill chunk-eval layers; the provider sets it for the engine, `scripts/install.sh` sets `18` for the smoke test. |
| `DARKBLOOM_ENGINE_V2_VLM_PARITY_CHECK` | `0` skips | on | `provider-swift/Sources/ProviderCore/Inference/Vision/EngineV2VLMTextExtraction.swift` | VLM text-extraction parity check. |

### Native MiMo V2.6 candidate

These controls affect the dedicated [native MiMo path](../architecture/inference.md#native-mimo-v26-candidate).
They do not add a catalog entry, bypass the advertised-model allowlist, grant
media/audio capabilities or qualify a performance route. Except for the
`DARKBLOOM_MIMO_PERSISTENT_WIRED_RESIDENCY` and
`DARKBLOOM_MIMO_COMPLETE_PREFIX` controls, the three short-forward
decode-kernel rollbacks and the three exact-verification rollbacks, none of
the `DARKBLOOM_MIMO_*` names below is a LaunchAgent passthrough entry; install process-scoped settings before first use
and restart for latched kernel flags.

| Control | Accepted enabling value | Default | Read in / effect |
|---|---|---|---|
| `backend.mtp_mode` for `mimo_v2` | `auto` or `on`, subject to genuine native head inspection and existing kill switch | `auto` requests embedded MTP by default; `off` disables it | `provider-swift/Sources/ProviderCore/Config/ProviderConfig.swift` (`MTPMode.enablesMTP`); `MiMoV26ServingLoad.hasEmbeddedMTP` derives intent from the validated native inventory; actual native assembly proves activation. No external assistant download. The default verification is exact rectangular (`EngineV2SlotFactory.nativeMiMoVerificationMode`): scalar-dense rows, row-exact affine projections and serialized attention reproduce serial decode while scoring all draft columns in one forward; a tracked engine that cannot arm the scalar-dense scratch never drafts. Under the serial-target rollback the adaptive controller keeps plans target-only (`nativeMiMoMTPConfig`, `allowsAdaptiveSerialRounds: false`), because each serial draft column costs one ordinary target forward. Media rows stay target-only |
| `DARKBLOOM_MIMO_RECTANGULAR_VERIFY` | unset enables; rollback: trimmed, case-insensitive `0`, `false`, `no`, `off` | on (exact rectangular verification when MTP is enabled); rollback selects serial target | `provider-swift/Sources/ProviderCore/Inference/Engine/Factory/EngineV2SlotFactory+Native.swift` (`nativeMiMoVerificationMode`); does not itself enable MTP; the provider never selects the bulk rectangular trunk. Forwarded to the launchd provider job |
| `DARKBLOOM_MIMO_RECTANGULAR_SCALAR_DENSE` | unset enables; same rollback values | on | `libs/mlx-swift-lm/Libraries/MLXLLM/Models/MiMo/MiMoV26RectangularDense.swift` (`enabled(environment:)`); separately charged scalar-shape rows only in genuine admitted rectangular verification. Its rollback also selects serial target in the provider. Forwarded to the launchd provider job |
| `DARKBLOOM_MIMO_ROW_EXACT_PROJECTION` | unset enables; same rollback values | on | `libs/mlx-swift-lm/Libraries/MLXLLM/Models/MiMo/MiMoV26RowExactProjection.swift`; scalar-dense affine 8-bit projections stream each weight tile once for up to seven rows with one-row `qmv_fast` arithmetic; rollback keeps one matmul per row (same output, slower). Forwarded to the launchd provider job |
| `DARKBLOOM_MIMO_NATIVE_PAGED_TARGET` | exact `1` with an explicit paged backend | off | `provider-swift/Sources/ProviderCore/Inference/Engine/Factory/EngineV2SlotFactory+Native.swift`; separately issued asymmetric target-only or explicit serial-MTP paging, including authenticated complete-prefix composition; rectangular verification and managed media remain refused in this profile |
| `DARKBLOOM_MIMO_PERSISTENT_WIRED_RESIDENCY` | rollback: trimmed, case-insensitive `0`, `false`, `no`, `off` | on (standing residency for the native weight payload, bounded by the safe ceiling) | `provider-swift/Sources/ProviderCore/Inference/Engine/Factory/MiMo/MiMoV26WiredResidency.swift` (`isEnabled`, `Bounds`, `Policy`); shared-manager, owned-lifetime acceleration only, never load admission or physical-page coverage proof. Without it a 256 GiB M3 Ultra measured ~0.4 tok/s decode versus ~38 tok/s. Forwarded to the launchd provider job so the rollback reaches installed providers |
| `DARKBLOOM_MIMO_COMPLETE_PREFIX` | unset or trimmed-empty uses the model default; exact `1` enables this gate; any other nonempty value disables; unlisted IDs also require affirmative `DARKBLOOM_PREFIX_CACHE`; global cache disable wins | on only for the [exact MiMo identities](../architecture/prefix-cache.md#mimo-complete-state) | `provider-swift/Sources/ProviderCore/Inference/PrefixCache/PrefixCachePolicy+Activation.swift` (`isMiMoCompletePrefixEnabled`); `EngineV2SlotFactory.nativeMiMoPrefixRefusal` gates text-only COMPLETE checkpoints with exact store/process/loaded-owner binding. Forwarded to the launchd provider job. Media requests remain uncached; native paging still needs its separate explicit opt-in |

NAX attention, admitted block grouping and the three short-forward decode
kernels below default on; the other kernel controls remain off. A requested flag is not effective
dispatch: module ownership, actual device/stream, native dtype, shape,
quantization, mask and admission checks still apply. Unsupported cases retain
the existing implementation; required execution failures are not silently
converted into successful fallback.

| Variable | Values / type | Reader / scoped candidate |
|---|---|---|
| `DARKBLOOM_MIMO_FUSED_DECODE_NORMS` | unset enables; rollback: trimmed, case-insensitive `0`, `false`, `no`, `off` | `libs/mlx-swift-lm/Libraries/MLXLLM/Models/MiMo/MiMoV26Text.swift` (`fusedDecodeNormsEnabled`); native residual/norm tail, also row-local inside the scalar-dense verifier. Forwarded to the launchd provider job |
| `DARKBLOOM_MIMO_DECODE_ROUTER_GEMV` | unset enables; same rollback values | `libs/mlx-swift-lm/Libraries/MLXLLM/Models/MiMo/MiMoV26DecodeRouter.swift` (`enabledByEnvironment`); eligible short-forward router. Forwarded to the launchd provider job |
| `DARKBLOOM_MIMO_DECODE_EXPERTS` | unset enables; same rollback values | `libs/mlx-swift-lm/Libraries/MLXLMCommon/Models/MiMo/MiMoV26DecodeExperts.swift` (`requested`); distinct-expert short-forward reuse. Forwarded to the launchd provider job |
| `DARKBLOOM_MIMO_FP32_WEIGHTED_REDUCE` | trimmed, case-insensitive `1`, `true`, `on` | `libs/mlx-swift-lm/Libraries/MLXLMCommon/Models/MiMo/MiMoV26FP32WeightedReduction.swift` (`isEnabled`); native FP32 weighted combine |
| `DARKBLOOM_MIMO_V26_DECODE_ROWS` | exact `1` | `libs/mlx-swift-lm/Libraries/MLXLMCommon/Models/MiMo/MiMoV26DecodeRows.swift` (`requested`); eligible singleton full-attention verification rows |

| NAX variable | Values / type | Reader / scoped candidate |
|---|---|---|
| `DARKBLOOM_MIMO_V26_NAX_GATHER` | trimmed, case-insensitive `1`, `true`, `yes`, `on` | `libs/mlx-swift-lm/Libraries/MLXLMCommon/Models/MiMo/MiMoV26NAXGatherQMM.swift` (`requested`); sorted native MXFP4 projection |
| `DARKBLOOM_MIMO_V26_NAX_GATE_UP` | same affirmative values | `libs/mlx-swift-lm/Libraries/MLXLMCommon/Models/MiMo/MiMoV26NAXGateUp.swift` (`requested`); dual-input projection without resident weight concatenation |
| `DARKBLOOM_MIMO_V26_NAX_SWIGLU` | exact `1` | `MiMoV26NAXGateUp.activationRequested`; epilogue preserves the original native rounding stages |
| `DARKBLOOM_MIMO_V26_NAX_ROW_MAP` | exact `1` | `MiMoV26NAXGateUp.rowMapRequested`; requires the eligible SwiGLU path, reuses sorted route/inverse without repeated input-row materialization |
| `DARKBLOOM_MIMO_V26_NAX_ATTENTION` | unset enables; trimmed, case-insensitive `1`, `true`, `yes`, `on`, `auto` enable; `0` disables | `libs/mlx-swift-lm/Libraries/MLXLMCommon/Models/MiMo/MiMoV26NAXAttention.swift` (`requested`); three score passes preserve native Q/score/probability rounding and existing q128 visibility |
| `DARKBLOOM_MIMO_BLOCK_BATCH_PREFILL` | unset enables; same affirmative values; `0` disables | `libs/mlx-swift-lm/Libraries/MLXLMCommon/Models/MiMo/MiMoV26BlockBatchAttention.swift` (`requested`); separately admitted grouping of existing exact query blocks; also requires the NAX attention path |
| `DARKBLOOM_MIMO_V26_SPLITKEY_QK` | exact `1` | `libs/mlx-swift-lm/Libraries/MLXLMCommon/Models/MiMo/MiMoV26SplitKeyAttention.swift` (`requested`); isolated helper, not wired to managed attention |

The ordered key-range helper
`libs/mlx-swift-lm/Libraries/MLXLMCommon/Models/MiMo/MiMoV26NAXAttentionKeyRanges.swift`
requires the genuine native process owner, bound policy, actual per-step work
and extra allocation reservation. Source presence or requested flags do not
prove a benchmark took that path. The native factory requests an eligible
default solo-text stripe of 4096, or 8192 only with matching oversized gather.
Actual loaded geometry, NAX hardware and authenticated scratch installation
decide whether it is accepted. Explicit stripe overrides remain authoritative;
MTP is repriced for the selected width without reducing other charges or reserves.
Controls are process-latched: a contradictory injected factory setting throws
`MiMoV26PrefillPolicy.ProcessControlMismatch` before slot assembly. Restart with
the desired process controls for actual rollback. See the
[SDK fast-prefill policy](https://github.com/Layr-Labs/mlx-swift-lm/blob/3fd4944c3b3ee5cb45c5cbfac8805876332d3a29/docs/mimo-v26/FAST-PREFILL-POLICY.md)
for eligibility, fallback and still-required qualification. Port-specific eligibility and licenses are in the
[SDK port map](https://github.com/Layr-Labs/mlx-swift-lm/blob/3fd4944c3b3ee5cb45c5cbfac8805876332d3a29/docs/mimo-v26/implementation-references.md).

### Native Flash-Next candidate

These controls belong to the [private candidate contract](qwen4-next-support.md),
not a public catalog activation. They are read in foreground/local processes;
these model-specific controls are not forwarded by `LaunchAgent.inferencePassthroughEnvKeys`.
Installed processes still use the source defaults.

| Variable | Values / type | Default | Read in | Effect |
|---|---|---|---|---|
| `DARKBLOOM_QWEN4_MODEL_PATH` | absolute existing native Qwen4 snapshot directory with config and weight index | unset; normal HF cache resolution | `provider-swift/Sources/ProviderCoreFoundation/Qwen4LocalModelPath.swift` (`directory`); `provider-swift/Sources/ProviderCoreFoundation/ModelScanner.swift` (`resolveLocalPath`); `provider-swift/Sources/ProviderCore/Models/ModelScanner+Discovery.swift` (`scanAllModels`) | Selects an isolated directory only for exact `DarkBloom/Qwen3.8-Flash-Next-Q4-mtp`. Scanner and load resolution agree. An invalid explicit override hides/refuses this model instead of using its old cached snapshot; other IDs are unchanged. Normal artifact hashing, admission and runtime checks remain active. No HOME or cache mutation. |
| `DARKBLOOM_QWEN4_LISTING_CONTEXT` | positive integer, lower-only | positive native context; `262_144` fallback for the qualified IDs without metadata | `provider-swift/Sources/ProviderCore/Inference/Qwen4SupportPolicy.swift` (`configuredContextTokens`, `contextLimit`) | Bounds prompt plus resolved output reservation. Unset, empty, invalid, zero and negative values retain native capacity; a positive override can only lower it. Unknown native artifacts without metadata have no invented fallback. Coordinator SLA policy and physical-memory admission remain independent. |
| `DARKBLOOM_QWEN4_PLE_SSD_OFFLOAD` | negative spellings disable the SDK mmap path | on | `libs/mlx-swift-lm/Libraries/MLXLLM/Models/Qwen4Exp.swift` (`Qwen4ExpPLEResidency.mmapFlag`, `useMmap`) | Immutable learned PLE weights remain SSD-backed independently of request prefix caching. Keep this enabled for candidate qualification; disabling request caching does not disable PLE. |
| `DARKBLOOM_QWEN4_QSA_PARALLEL_FULL_KV` | unset or exact `1` enables; explicit `0` disables | on | `libs/mlx-swift-lm/Libraries/MLXLLM/Models/Qwen4ExpParallelQSA.swift` (`fullKVEnabled`) | Existing parallel QK/ordered-PV path for eligible native full-KV widths 1–6. Larger prefill retains existing dispatch. Other explicit spellings stay disabled. Separate compact-KV experiments remain opt-in. |
| `DARKBLOOM_QWEN4_QSA_PARALLEL_VALUE_PARTITIONS` | `1`, `2`, `4`, `8`, `16`, `32` | `32` for full KV; caller fallback for compact KV | `libs/mlx-swift-lm/Libraries/MLXLLM/Models/Qwen4ExpParallelQSA.swift` (`valuePartitions`) | A valid explicit caller argument wins over the environment. Invalid explicit values retain the caller fallback. This changes scheduling, not arithmetic order, precision or MTP depth. |
| `DARKBLOOM_QWEN4_LAYER_ASYNC` | unset or exact `1` enables; explicit `0` disables | on | `libs/mlx-swift-lm/Libraries/MLXLLM/Models/Qwen4ExpLayerSubmission.swift` (`enabled`, `plan`) | Early singleton text layer submission on valid native paged caches at widths 1–6. Media/explicit positions, wider/batched shapes and faulted or unknown caches retain the existing scheduling. Other explicit spellings stay disabled. |

### Native DiffusionGemma expert reduction

These controls affect native DiffusionGemma inference, not its weights,
denoising recipe or autoregressive MTP capability. Set overrides before starting
a foreground provider or benchmark. These variables are not forwarded by
`LaunchAgent.inferencePassthroughEnvKeys`; installed processes retain the source
default unless their own environment supplies an override.

| Variable | Values / type | Default | Read in | Effect |
|---|---|---|---|---|
| `DARKBLOOM_DIFFUSION_EXPERT_UNSORT` | unset enables; case-insensitive `1`, `true`, `yes`, `on` enable; any other explicit value disables | on for eligible inference | `libs/mlx-swift-lm/Libraries/MLXLLM/Models/DiffusionGemmaExpertReduction.swift` (`enabled`, `eligible`, `shaderIndexFits`, `reduce`); `libs/mlx-swift-lm/Libraries/MLXLLM/Models/DiffusionGemmaBlocks.swift` (`DiffusionGemmaExperts.callAsFunction`) | Reuses the ordered weighted-unsort kernel for sorted BF16 outputs/weights with hidden size 2816, eight selected experts, at least 64 assignments and a matching uint32 inverse permutation on the ordinary GPU device/stream. Flattened output addresses must fit the shader's uint32 range, with checked host multiplication. Avoids materializing the restored expert-output intermediate. Training, CPU/custom streams, oversized shader indices, other shapes/dtypes and explicit rollback retain the original scatter/multiply/reduce graph. No context-capacity, sampler, attention or precision change. |
| `DARKBLOOM_DIFFUSION_SOFT_EMBEDDING` | case-insensitive `1`, `true`, `yes`, `on` enable; unset or any other value disables | off; qualification candidate | `libs/mlx-swift-lm/Libraries/MLXLLM/Models/DiffusionGemmaSoftEmbedding.swift` (`enabled`, `eligible`, `project`) | Uses the existing non-transposed affine matrix math with a 64-row GPU tile for the 256-by-262144 soft-conditioning input and 2816-wide Q8/group64 embedding. Native BF16 inference on the ordinary GPU stream only; training, traced/retained graphs, other geometry/quantization and missing resources retain original `quantizedMM`. Input-view preparation, weights and native sampler are unchanged. |
| `DARKBLOOM_DIFFUSION_COMPILED_SAMPLER` | exact `1` enables; unset or any other value disables | off; qualification candidate | `libs/mlx-swift-lm/Libraries/MLXLMCommon/DiffusionGemmaCompiledSampler.swift` (`enabled`, `eligible`, `graph`); `libs/mlx-swift-lm/Libraries/MLXLMCommon/DiffusionGemmaSampler.swift` (`stepNative`) | Compiles native entropy/acceptance and sampling-state operations for the eligible single-row, 256-position, 262144-vocabulary FP32 path. Preserves key ordering, integer draws, exact RNG/clamp constants and validation before state mutation; arbitrary callbacks, CPU/custom streams, other geometry/storage and nondefault stability/entropy/confidence policies retain the original sampler. Request arrays are explicit inputs to bounded compiled variants. Weights, diffusion recipe and context are unchanged. Account separately for first-use compilation and warmed latency. |

The following observer affects benchmarks only, not serving dispatch.

| Variable | Values / type | Default | Read in | Effect |
|---|---|---|---|---|
| `DARKBLOOM_DIFFUSION_DESCRIPTOR_PROBE` | exact `1` enables | off | `provider-swift/Sources/ProviderCore/Inference/Engine/Factory/DiffusionBenchmarkRouteProbe.swift` (`isEnabled`, `begin`, `end`) | Emits descriptor, DiffusionGemma weighted-reduction, soft-conditioning and compiled-sampler dispatch counts from the first iteration, then requires unchanged disarmed counters. Does not select a route or alter serving. Use exclusive ownership, report first-use latency separately and exclude that iteration from warmed comparisons. |

### Bonsai performance qualification

These SDK controls default on for eligible paths of the unchanged schema-2
Ternary Bonsai 2 27B artifact. They are not a weight conversion, MTP capability
or deployment action. Source defaults apply to foreground and daemon processes.
Set any overrides before startup; these names are not in the LaunchAgent shell
environment passthrough. See `libs/mlx-swift-lm/docs/bonsai2.md` for the
artifact contract and qualification limits.

| Variable | Values / type | Default | Read in | Effect |
|---|---|---|---|---|
| `DARKBLOOM_BONSAI_PREFILL_CARRY_ASYNC` | unset or exact `1` enables; `0` disables | on | `libs/mlx-swift-lm/Libraries/MLXLLM/Models/PrismHadamardPrefillCarry.swift` (`isEnabled`, `enabled`, `withScope`, `submit`) | Earlier submission of compact recurrent carry during eligible packed text prefill; native arithmetic, deferred input fills, write-fault checks and engine retirement remain unchanged. Short/decode, media positions and captured windows retain existing scheduling. Other explicit spellings remain disabled. |
| `DARKBLOOM_BONSAI_F16_CONSTANT_CACHE` | unset or exact `1` enables; `0` disables | on | `libs/mlx-swift/Source/MLXNN/Hadamard.swift` (`float16ConstantReuseEnabled`, `permitsFloat16ConstantReuse`); `libs/mlx-swift/Source/MLX/ConstantArrayCastCache.swift` (`cachedCast`) | Reuses the native FP16-to-FP32 scale/offset conversion for eligible 2-bit/group128/block1024 packed projections. Adds approximately 1.60 GB of retained constants for the selected pack; weights and native precision do not change. Descriptor/stream changes invalidate reuse; tracing falls back. Other explicit spellings remain disabled; the generic cache rollback remains effective. |

See the [matched performance report](https://github.com/Layr-Labs/darkbloom-platform/blob/48a198c71a2d30feec5597bacf1101120f7f955d/docs/reports/2026-09-18-bonsai2-lossless-performance.md)
for measured gains, tradeoffs and open gates. Neither control authorizes model
uploads, catalog changes, signing or production promotion.

### Memory and media budgets

| Variable | Values / type | Default | Read in | Effect |
|---|---|---|---|---|
| `DARKBLOOM_MLX_CACHE_LIMIT_GB` | GiB (floor 1) | `8` | `provider-swift/Sources/ProviderCore/Inference/Memory/MLXMemoryGuard.swift` | MLX buffer-cache limit, applied by serving and the throughput sweep before model loading. |
| `DARKBLOOM_MLX_MEMORY_RESERVE_GB` | GiB | `provider.toml` `memory_reserve_gb` | `provider-swift/Sources/ProviderCore/Inference/Memory/MLXMemoryGuard.swift` | Overrides the whole-machine memory reserve. |
| `DARKBLOOM_MEM_CAP_FRACTION` | fraction | `0.90` | `provider-swift/Sources/ProviderCore/Inference/Memory/UnifiedMemoryCap.swift` | Share of unified memory the engine may address. |
| `DARKBLOOM_MEMORY_AVAILABILITY` | `reclaimable` / `free-only` | `reclaimable` | `provider-swift/Sources/ProviderCore/Inference/Memory/SystemMemory.swift` | Process-start policy shared by admission, KV budgets and diagnostics; persisted into the provider launchd plist on background start. `reclaimable` counts Mach free + inactive pages; `free-only` excludes inactive pages and fails closed if sampling fails. Unknown/empty explicit values select `free-only`. See [shared-host admission](https://github.com/Layr-Labs/darkbloom-platform/blob/48a198c71a2d30feec5597bacf1101120f7f955d/docs/architecture/scheduling.md#shared-host-memory-admission). |
| `DARKBLOOM_ACTIVATION_RESERVE_GB` | GiB (raise-only) | `5.5` | `provider-swift/Sources/ProviderCore/Inference/Memory/UnifiedMemoryCap.swift` | Activation headroom kept out of the weight budget. |
| `DARKBLOOM_VISION_MAX_TOWER_PATCHES` | integer (lower-only) | model default | `provider-swift/Sources/ProviderCore/Inference/Vision/VisionTowerBudget.swift` | Caps vision-tower patches. |
| `DARKBLOOM_MAX_IMAGE_MEGAPIXELS`, `DARKBLOOM_MAX_REQUEST_IMAGE_MEGAPIXELS` | megapixels | `100`, `384` | `provider-swift/Sources/ProviderCore/Inference/Vision/MediaIngest.swift` | Per-image and per-request pixel caps. |
| `DARKBLOOM_MAX_MEDIA_MIB` | MiB | `25` | `provider-swift/Sources/ProviderCore/Inference/Vision/MediaIngest.swift` | Per-request media bytes. |
| `DARKBLOOM_MAX_VIDEO_SECONDS` | seconds | `600` | `provider-swift/Sources/ProviderCore/Inference/Vision/MediaIngest.swift` | Per-video duration cap. |
| `DARKBLOOM_MAX_IMAGES_PER_REQUEST`, `DARKBLOOM_MAX_VIDEOS_PER_REQUEST` | integers | `16`, `8` | `provider-swift/Sources/ProviderCore/Inference/Vision/MediaIngest.swift` | Attachment count caps. |
| `DARKBLOOM_MAX_REQUEST_VIDEO_FRAME_MEGAPIXELS` | megapixels | `384` | `provider-swift/Sources/ProviderCore/Inference/Vision/MediaIngest.swift` | Per-request decoded video-frame pixel cap. |

### Model verification I/O

The default reusable-buffer reader and bounded parallel hashing change full-file
reading and scheduling, not the verified
bytes or model arithmetic. Discovery remains hash-free. Fresh pre/post-load
verification and delayed identity publication retain their existing rules.

| Variable | Values / type | Default | Read in | Effect |
|---|---|---|---|---|
| `DARKBLOOM_EXPERIMENT_HASH_STREAM_FIRST` | Unset or `1` enables; `0` and other explicit values disable | ON when unset | `provider-swift/Sources/ProviderCoreFoundation/WeightHasher.swift` (`prefersStreamReader`, `hashSingleFile`) | Try the reusable-buffer InputStream reader before FileHandle; retain full SHA and all existing fallbacks. |
| `DARKBLOOM_EXPERIMENT_HASH_WORKERS` | Integers `1`, `2`, `4`; other explicit values select `1` | `4` when unset | `provider-swift/Sources/ProviderCoreFoundation/WeightHasher.swift` (`resolvedHashWorkers`, `hashFilesWithRelativeKey`) | Bound independent file readers per invocation by file count and the selected limit, then combine every raw digest in the original sorted-key order. Any failed file prevents a successful aggregate. |

Concurrent invocations each have their own worker bound; this is not a global
thread budget. A warm resident request that does not hash gets no direct benefit.
Leave both controls unset for the optimized default on every model. For the
original reading path and serial order, explicitly set
`DARKBLOOM_EXPERIMENT_HASH_STREAM_FIRST=0` and `DARKBLOOM_EXPERIMENT_HASH_WORKERS=1`.
The existing variable names and invalid-value fallbacks remain compatible.
The controls do not enable caches, alter attestation policy or skip load checks.

### SSD prefix cache

The optional `[cache]` table in `provider.toml` is saved by
`darkbloom cache set` and read by `Start.run` before serving. It applies to both
attention blocks and complete checkpoints. It does not enable a model's cache
capability or alter the TTL, encryption or memory safeguards.

| Key | Type / default | Effect | Source |
|---|---|---|---|
| `cache.daily_write_gb` | Optional nonnegative finite decimal GB; absent uses environment/default below | `0` explicitly means unlimited. A positive value must represent at least one byte and fit in `Int`; saved values win over the environment after restart | `provider-swift/Sources/ProviderCore/Config/CacheSettings.swift` (`validate`), `provider-swift/Sources/ProviderCore/KVCacheSSD/CacheStorage.swift` (`dailyWriteBytes`) |
| `cache.directory` | Optional absolute existing directory | Payloads use its `darkbloom/kv3` child; absent retains the built-in cache directory. No automatic migration or fallback when configured storage is unavailable | `CacheStorage.swift` (`root`), `provider-swift/Sources/ProviderCore/KVCacheSSD/CacheVolume.swift` (`inspect`) |
| `cache.volume_uuid` | Optional UUID, required with `cache.directory` | Written by the CLI and checked against opened directories; a different filesystem at the same path is refused | `CacheStorage.swift` (`validateOpenedDirectory`) |

Preparation and commands: [provider cache storage](../provider/cache-storage.md).

Internals and file format: [`ssd-kv-cache.md`](ssd-kv-cache.md).

| Variable | Values / type | Default | Read in | Effect |
|---|---|---|---|---|
| `DARKBLOOM_PREFIX_CACHE` | affirmative opts in; non-affirmative nonempty disables | on for the exact cohorts in the [backend/default table](../architecture/prefix-cache.md#kv-layouts), including Bonsai 2, MiMo and the owned Flash-Next candidate; off otherwise | `provider-swift/Sources/ProviderCore/Inference/PrefixCache/PrefixCachePolicy+Activation.swift` (`isEnabled`) | Unset/empty uses the model default. Explicit affirmative values permit other models subject to capability/identity gates; resident payloads require the separate memory opt-in. Source enablement does not prove cache restoration. |
| `DARKBLOOM_PREFIX_CACHE_MEMORY` | affirmative (`1`, `true`, `yes`, `on`) | off | `provider-swift/Sources/ProviderCore/Inference/PrefixCache/PrefixCachePolicy+Activation.swift` (`isMemoryEnabled`) | Explicit opt-in for both paged resident blocks and the recurrent RAM bank; global disable wins. Forwarded by LaunchAgent. |
| `DARKBLOOM_PREFIX_CACHE_STATS_INTERVAL_SECS` | seconds (`0` off) | `120` | `provider-swift/Sources/ProviderCore/Inference/PrefixCache/PrefixCachePolicy.swift` | Cadence of the local SSD stats line and typed per-store heartbeat observation; `0` omits the observation. Sample age still advances between ticks; see [telemetry](../architecture/telemetry.md#durable-prefix-cache-observations). |
| `DARKBLOOM_PREFIX_CACHE_DISK_GB` | GiB | Half the currently available space; `20` if space cannot be measured | `provider-swift/Sources/ProviderCore/Inference/PrefixCache/PrefixCachePolicy.swift` (`ssdDiskBudgetBytes`) | Box-wide on-disk budget across all models, with no fixed default ceiling. A valid positive override is used verbatim. The separate 20 GiB free-space write reserve still applies. |
| `DARKBLOOM_PREFIX_CACHE_ALLOW_EPHEMERAL` | affirmative | off | `provider-swift/Sources/ProviderCore/KVCacheSSD/SSDPrefixCacheFactory.swift` | Allows an in-memory KEK fallback and the isolated test root. Ephemeral ciphertext cannot be reused after process exit. |
| `DARKBLOOM_PREFIX_CACHE_TEST_ROOT` | directory | unset | `provider-swift/Sources/ProviderCore/KVCacheSSD/SSDPrefixCacheFactory.swift` | Isolated payload root, accepted only with `DARKBLOOM_PREFIX_CACHE_ALLOW_EPHEMERAL`; normally forces an ephemeral key. |
| `DARKBLOOM_PREFIX_CACHE_TEST_PERSISTENT_KEY` | exactly `1` | off | `provider-swift/Sources/ProviderCore/KVCacheSSD/SSDPrefixCacheFactory.swift` (`forceEphemeralKey`) | Benchmark-only: use the normal persistent KEK path within an accepted test root. Fallback is still possible; the benchmark SPI defaults to requiring actual persistent mode. Not forwarded to LaunchAgents. |
| `DARKBLOOM_PREFIX_CACHE_SSD_TTL_SECONDS` | seconds ≤ 1800 | `1800` | `provider-swift/Sources/ProviderCore/KVCacheSSD/SSDPrefixCachePolicy.swift` | Entry time-to-live. |
| `DARKBLOOM_PREFIX_CACHE_SSD_MAX_WRITE_GB_PER_DAY` | GB/day (`0` unlimited) | `750` | `provider-swift/Sources/ProviderCore/KVCacheSSD/SSDPrefixCachePolicy.swift` | Persistent rolling-day write budget; includes serialized cache-file framing. A saved `cache.daily_write_gb` takes precedence. Forwarded to newly installed launchd jobs. See [accounting and limits](ssd-kv-cache.md#size-and-eviction-rules). |
| `DARKBLOOM_PREFIX_CACHE_SSD_MIN_EFFECTIVE_TOKENS` | tokens | `1024` | `provider-swift/Sources/ProviderCore/KVCacheSSD/SSDPrefixCachePolicy.swift` | Smallest prefix worth persisting. |
| `DARKBLOOM_PREFIX_CACHE_SSD_WINDOW_SIDECAR` | affirmative | off | `provider-swift/Sources/ProviderCore/KVCacheSSD/SSDPrefixCachePolicy.swift` | Persists the sliding-window sidecar. |
| `DARKBLOOM_PREFIX_CACHE_SSD_MAX_STAGE_MB`, `DARKBLOOM_PREFIX_CACHE_SSD_MAX_STAGE_MS` | MiB, ms | `1024`, `1000` | `provider-swift/Sources/ProviderCore/KVCacheSSD/SSDPrefixCachePolicy.swift` | Attention staging byte/time caps. Complete checkpoints use the byte value as a payload-read cap; native destination plus bounded scratch is separately reserved before allocation, with no permanent RAM carve. |
| `DARKBLOOM_PREFIX_CACHE_SSD_STRICT_FSYNC` | affirmative | off | `provider-swift/Sources/ProviderCore/KVCacheSSD/SSDPrefixCachePolicy.swift` | `fsync` after every write. |

### Resident recurrent prefix cache

These overrides are read at slot construction in foreground/local and test
processes; neither is on the LaunchAgent environment allow-list. Both require
`DARKBLOOM_PREFIX_CACHE_MEMORY=1` first; that opt-in and the global cache switch
are forwarded to the LaunchAgent. Backend/model/assistant
eligibility, measured publication limits, and the conservative reservation after
a slot shrink are described in
[`../architecture/prefix-cache.md#resident-tiers`](../architecture/prefix-cache.md#resident-tiers).
Provider cache enablement does not enable coordinator preference; the independent
`EIGENINFERENCE_CACHE_ROUTING_MODE` default remains `off`
([coordinator/registry/config.go](https://github.com/Layr-Labs/darkbloom-platform/blob/48a198c71a2d30feec5597bacf1101120f7f955d/coordinator/registry/config.go), `ReadConfig`).

| Variable | Values / type | Default | Read in | Effect |
|---|---|---|---|---|
| `DARKBLOOM_CBV2_HYBRID_PREFIX_CACHE` | exact `0` disables | unset (eligible only after memory opt-in) | `provider-swift/Sources/ProviderCore/Inference/PrefixCache/PrefixCachePolicy+Hybrid.swift` (`hybridConfig`) | Disables recurrent checkpoint retention without changing paged/SSD policy or MTP mode. |
| `DARKBLOOM_CBV2_HYBRID_PREFIX_BYTES` | integer bytes | `min(1 << 30, max(0, kvBytesCapacity / 8))` | `provider-swift/Sources/ProviderCore/Inference/PrefixCache/PrefixCachePolicy+Hybrid.swift` (`hybridConfig`) | Reservation inside the existing slot KV grant; parsed values outside `0 < bytes < kvBytesCapacity` disable the bank, malformed values use the default. |

`CBv2HybridPrefixCacheConfig` defaults to `maximumEntries = 32` and
`maximumCheckpointsPerRequest = 2`; these have no CLI environment overrides
(`libs/mlx-swift-lm/Libraries/MLXLMCommon/ContinuousBatchingV2/Prefix/HybridPrefixCacheContract.swift`).

### Benchmark, harness and tests

Ordinary teacher-forced scoring is selected by CLI input, with no new environment
variable; its required input and backend are documented in the
[CLI reference](../provider/cli-reference.md#teacher-forced-scores)
(`provider-swift/Sources/darkbloom/BenchmarkCommand.swift`, `teacherForcedOptionError`).

| Variable | Values / type | Default | Read in | Effect |
|---|---|---|---|---|
| `DARKBLOOM_ARRIVAL_TOLERANCE_MS` | ms | harness default | `provider-swift/Sources/ProviderBenchmark/ArrivalInvarianceBenchmark.swift` | Arrival-invariance tolerance. |
| `DARKBLOOM_QWEN_FCFS_LIVE` | `1` | unset | `provider-swift/Sources/ProviderBenchmark/SchedulerPrefillDecisionCLI.swift` | Enables the live Qwen FCFS harness. |
| `DARKBLOOM_QWEN_FCFS_MODEL_PATH`, `DARKBLOOM_QWEN_FCFS_MODEL_ID`, `DARKBLOOM_QWEN_FCFS_EXPECTED_MODEL_HASH`, `DARKBLOOM_QWEN_FCFS_SOURCE_SHA`, `DARKBLOOM_QWEN_FCFS_ITERATIONS`, `DARKBLOOM_QWEN_FCFS_KV_BACKEND`, `DARKBLOOM_QWEN_FCFS_OUTPUT` | strings | unset | `provider-swift/Sources/ProviderBenchmark/SchedulerPrefillDecisionCLI.swift` | Harness inputs. |
| `DARKBLOOM_QWEN_MTP_SERIAL` | affirmative | off | `provider-swift/Tests/ProviderCoreTests/Inference/Live/Fixtures/Qwen38ProductionCanarySupport.swift` (tests only) | Forces serial MTP verification in the Qwen canary. |

### Retired (parsed only to warn)

`provider-swift/Sources/ProviderCore/Inference/Engine/Factory/EngineV2Config.swift` recognises these and logs a warning; they have no effect: `DARKBLOOM_ENGINE_V2`, `DARKBLOOM_ENGINE_V2_MODELS`, `DARKBLOOM_COMPILED_DECODE`, `DARKBLOOM_GEMMA_B1_FAST_PATH`, `DARKBLOOM_B1_GREEDY_FAST_PATH`, `DARKBLOOM_KV_GPTOSS_KERNEL`, `DARKBLOOM_ADAPTIVE_PREFILL_ALLOW_8192`, `DARKBLOOM_KV_CAPTURE_MAX_INFLIGHT`, `DARKBLOOM_PREFIX_CACHE_MIN_PERSIST_TOKENS`. Six more names appear only in comments because `mlx-swift-lm` reads them, not the provider (`DARKBLOOM_CBV2_ATTN_QUERY_BLOCK`, `DARKBLOOM_CBV2_PAGED_PTOK_TARGET`, `DARKBLOOM_CBV2_COMPILED`, `DARKBLOOM_GEMMA4_PREFILL_TAIL_ROWS`, `DARKBLOOM_GEMMA4_PREFILL_LAST_QUERY`, `DARKBLOOM_CBV2_MIXED_PREFILL_CAP`); none is on the LaunchAgent allow-list, so they only apply under `start --foreground`.

### Non-`DARKBLOOM_` variables the provider honours

| Variable | Values / type | Default | Read in | Effect |
|---|---|---|---|---|
| `MLX_GEMMA4_FUSED_WEIGHTED_UNSORT` | flag | set by the provider | `provider-swift/Sources/ProviderCore/Config/GemmaOptimizationEnvironment.swift`; `provider-swift/Sources/darkbloom/ServeRuntimePreparer.swift` | Provider-set MLX fused-unsort switch for Gemma 4. |
| `MLX_GATHER_QMM_EXPERT_SLICES` | `1` (drain) or config-backed `0`/`trust` | `trust` | `provider-swift/Sources/ProviderCore/Config/GemmaOptimizationEnvironment.swift`; `provider-swift/Sources/ProviderCore/Inference/Engine/PackagedRuntimeSmoke.swift` | Expert-slice route mode; only an exact `1` is persisted into the LaunchAgent plist. |
| `SUDO_UID` | uid | set by `sudo` | `provider-swift/Sources/darkbloom/Fan/FanServiceManager.swift` | Resolves the invoking user when `darkbloom fan` runs under `sudo`. |
| `SUDO_USER` | user name | set by `sudo` | `provider-swift/Sources/darkbloom/Diagnostics/ReportAppAttestEvidence.swift` | Under `sudo darkbloom report`, selects the invoking user's state, config and read-only canonical token lookup instead of root's; explicit config/token overrides retain precedence. |
| `GITHUB_SHA` | commit | unset | `provider-swift/Sources/ProviderBenchmark/SchedulerPrefillDecisionCLI.swift` | Fallback source SHA in benchmark reports. |
| `DYLD_INSERT_LIBRARIES`, `DYLD_LIBRARY_PATH`, `DYLD_FRAMEWORK_PATH`, `LD_PRELOAD`, `MallocStackLogging`, `MallocStackLoggingNoCompact`, `MallocScribble`, `MallocGuardEdges`, `MallocLogFile`, `MallocErrorAbort`, `NSZombieEnabled`, `OBJC_DEBUG_POOL_ALLOCATION`, `CFNETWORK_DIAGNOSTICS` | — | — | `provider-swift/Sources/ProviderCore/Security/EnvironmentScrubber.swift` | Removed from the daemon's environment at start; reported as the `env_scrubbed` capability. |

`scripts/install.sh` additionally reads `COORD_URL` (substituted by the coordinator when it serves `/install.sh`; required when the script is run from source), `HOME` (install root `$HOME/.darkbloom`), `TMPDIR` (enrollment-profile temp dir only) and the two code-signing requirement constants `DARKBLOOM_DESIGNATED_REQUIREMENT` and `DARKBLOOM_FAN_HELPER_REQUIREMENT`. See [`../provider/installation.md`](../provider/installation.md).

## GPT-OSS performance controls

These library controls apply to foreground processes and benchmark runs; they are not added to the provider LaunchAgent environment allow-list. Prefix reuse is independent of these changes.

| Variable | Values | Default | Reader and effect |
|---|---|---|---|
| `DARKBLOOM_GPTOSS_PREFILL_OUTPUT` | `full`, `intermediate`, `last`, `last-layer` | `last` | `libs/mlx-swift-lm/Libraries/MLXLLM/Models/GPTOSS+PrefillOutput.swift` (`GPTOSSPrefillOutputPolicy`): skip unused intermediate vocabulary projections and project only the final hidden position. `full` restores full projections; `intermediate` preserves the final full-shape head; `last-layer` additionally narrows the last full-attention layer when its cache supports it. |
| `DARKBLOOM_GPTOSS_FUSED_GATE_UP` | `0` disables; otherwise enabled | enabled for hidden/intermediate width 2880 and 32 experts | `libs/mlx-swift-lm/Libraries/MLXLLM/Models/GPTOSS.swift` (`useFusedGateUp`): concatenate compatible gate/up checkpoint rows. Conflicting quantization policies remain split; incremental materialization bounds the added load transient. |
| `MLX_QUANTIZED_CONSTANT_CACHE` | `0`, `false`, `no`, `off` disable | enabled | `libs/mlx-swift/Source/MLX/ConstantArrayCastCache.swift` (`ConstantArrayCastCache`): bounded reuse of unchanged BF16-to-FP32 constants; updates invalidate and transforms bypass reuse. |
| `MLX_GPTOSS_MXFP4_DECODE_FAST_TAIL` | `1` enables, other explicit values disable | enabled only on physical `applegpu_g16s` | `libs/mlx-swift/Source/Cmlx/mlx/mlx/backend/metal/quantized.cpp` (`gather_qmv`): width-2880 MXFP4 gathered matrix-vector path with a masked 320-element tail. Exact shape/dtype gates retain the general fallback. |
| `MLX_GPTOSS_MXFP4_PREFILL_TILE` | `m32n32k32`; other values use legacy | legacy | `libs/mlx-swift/Source/Cmlx/mlx/mlx/backend/metal/gptoss_mxfp4_policy.h` (`gptoss_mxfp4_prefill_tile`): optional 32-row tile for matching sorted expert prefill shapes. Small workstation gains do not establish a universal default. |
| `DARKBLOOM_GPTOSS_COMPILED_EXPERTS` | `1` enables | disabled | `libs/mlx-swift-lm/Libraries/MLXLLM/Models/GPTOSS+CompiledExperts.swift` (`GPTOSSCompiledExpertsPolicy`): compile single-token B=1/2/4 expert graphs for exact 20B shapes. The global `MLX_COMPILED_DECODE=0` rollback still disables this path. Batch-dependent timing is mixed; weights remain live through weak updatable state. |
