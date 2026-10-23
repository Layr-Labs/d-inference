# Configuration reference

> Last updated: 2026-10-22

Provider CLI, native-runtime and retained-console environment variables, compiled defaults and reading symbols. Secrets are named, never valued. Unless specified otherwise, values are read at process start.

Coordinator and admin settings belong to the [platform configuration reference](https://github.com/Layr-Labs/darkbloom-platform/blob/48a198c71a2d30feec5597bacf1101120f7f955d/docs/reference/configuration.md).
Pinned platform links on this page are immutable evidence snapshots, not claims
about current platform behavior. For current settings and behavior, consult the
latest default branch of [darkbloom-platform](https://github.com/Layr-Labs/darkbloom-platform).

## Local GLM qualification

This process-local opt-in is independent of the coordinator supported-model set.

| Variable / field | Default / behavior | Consumer |
|---|---|---|
| `DARKBLOOM_EXPERIMENTAL_GLM5_NEXT` | Unset: disabled. Otherwise an absolute path to a regular JSON selection file, at most 4 MiB; not a boolean and not forwarded to launchd | `provider-swift/Sources/ProviderCore/Inference/Models/GLM5Next/GLM5NextLocalQualification.swift` (`selection`) |
| `catalog`, `manifest` | Required complete `CatalogModel` and `ModelManifest` objects using their ordinary JSON keys; dates are ISO-8601. Both identify exactly `EigenLabs/GLM-5.3-Flash-MLX-NVFP4-mtp`. The catalog's Hugging Face artifact binds that repository and a concrete revision. No network catalog request is made | `GLM5NextLocalQualification.selection` |
| `expectedAggregateSHA256` | Required lowercase 64-digit SHA-256 pin; must equal both catalog and manifest aggregates. This is the exact local artifact selection, not an assertion that bytes are verified or published | `GLM5NextLocalQualification.validate` |
| `maximumContextLength` | Optional positive enforced context bound, default `4096`; must not exceed the source model's maximum. Read once per LOAD together with the artifact plan; controls engine sizing and request admission, not source metadata. A request that omits `max_tokens` gets the smaller of the model's default output budget (4,096 for the pinned artifact) and half the bound. A prompt plus output budget above the bound is refused with HTTP 400 `advertised_context_exceeded` before native admission | `GLM5NextLocalQualification.LocalPlan.boundedSizing`; `EngineV2Factory.makeBridge` |
| `tokenizer` | Not supported. A present field refuses the whole selection: the LOAD quotation covers only the tokenizer shipped in the pinned weight snapshot | `GLM5NextLocalQualification.Selection` |
| `DARKBLOOM_GLM_PERSISTENT_WIRED_RESIDENCY` | On: a published GLM engine holds standing wired residency for its weights, bounded by the MiMo safe ceiling (physical memory minus max(16 GiB, 10%)) and released only after proven retirement. Rollback: trimmed, case-insensitive `0`, `false`, `no`, `off`. Acceleration only, never load admission; without it 512-token prefill chunks measured 263–367 instead of 1,246 tok/s on a 256 GiB M5 Ultra. Forwarded to the launchd provider job | `provider-swift/Sources/ProviderCore/Inference/Models/GLM5Next/GLM5NextWiredResidency.swift` (`isEnabled`, `prepare`) |

The weight snapshot's `chat_template.jinja` must be the reviewed template
shipped in `EigenLabs/GLM-5.3-Flash-MLX-NVFP4-mtp`
(`GLM5NextPromptPolicy.templateSHA256`); any other template refuses the LOAD
even when it renders (`GLM5NextLocalQualification.requireShippedTemplate`).

The provider rechecks the selection before local LOAD, and the managed loader
verifies manifest-pinned bytes under ordinary pending-load admission. A stale
discovery hash refuses selection. The opt-in does not change coordinator
advertisement, MTP defaults or performance cohorts. Only use an isolated local
process and explicitly reviewed artifacts; publication and full-model numerical
or throughput qualification remain separate gates.

GLM serves only through its embedded-MTP engine with a native operation owner;
target-only GLM has no checked completion receipt. MTP is therefore on for GLM
without any setting: the default `[backend] mtp_mode = "auto"` enables it, as
does `"on"` (`MTPMode.enablesMTP`). `mtp_mode = "off"` or the process kill switch
`DARKBLOOM_CBV2_MTP=0` (also `false`, `no`, `off`) disables it; local startup then skips the
model with a message, and the local server's model list omits it
(`GLM5NextLocalServing.partition`); any LOAD fails before weight allocation.
When a selection is missing or invalid, startup prints the specific reason
(`GLM5NextLocalQualification.localSelectionRefusal`).
Coordinator-connected mode needs no setting: it serves only catalog build
`glm-5.3-flash` with a 262,144-token enforced context, on Apple M5 Max or
M5 Ultra with at least 256 GiB, and only while MTP is enabled
(`ProviderLoop.coordinatorGLM5NextPlan`). The selection file is ignored there.
There is no assistant-floor,
post-build or wedge-recovery fallback to target-only: those paths unload or
refuse the GLM slot instead.

For the pinned local identity and `glm-5.3-flash` the encrypted SSD prefix store defaults on;
`DARKBLOOM_PREFIX_CACHE=0` disables it
(`provider-swift/Sources/ProviderCore/Inference/PrefixCache/PrefixCachePolicy+Activation.swift`,
`PrefixCachePolicy.isEnabled`). The KV backend needs no setting: automatic
selection is paged, and `contiguous` or `DARKBLOOM_CBV2_PAGED_KV=0` refuses the
load (`EngineV2Factory.prepareProductionBackend`).

The local `/metrics` endpoint exports these gauges from
`provider-swift/Sources/ProviderCore/Inference/Models/GLM5Next/GLM5NextLoadFaultState.swift`
(`GLM5NextLoadFaultState`):

| Metric | Meaning |
|---|---|
| `darkbloom_glm5_next_retained_fault` | `1` after any unproven GLM native retirement |
| `darkbloom_glm5_next_retained_owner_objects` | Distinct in-process objects kept alive by GLM faults (bridges, newcomer containers, leases, activity markers); not a model count |
| `darkbloom_glm5_next_retained_resident_bytes` | Unpublished weight and KV bytes charged to retained owners; subtracted from fleet KV budgets |

A retained fault refuses new GLM work until process restart. Retained native
roots, the pending-load lease and memory claims are never refunded by that
signal. Other model families keep loading and reclaiming under their own
admission and native health gates when capacity remains, but their re-sliced
grants exclude the charged bytes, so survivors cannot regrow into memory a
retained GLM owner may hold. When a lone GLM slot held the whole fleet KV
budget, the retained charge leaves none, so other loads are refused. A
published GLM slot whose unload, eviction or shutdown cannot prove retirement
stays in place: its KV claim is charged, its grant is frozen, eviction skips
it and shutdown stays draining.

## Console UI

The retained console uses build-time public variables. Rebuild after changing
them; never place private credentials in `NEXT_PUBLIC_*` values.

| Variable | Default / behavior | Consumer |
|---|---|---|
| `NEXT_PUBLIC_COORDINATOR_URL` | `https://api.darkbloom.dev` when missing or empty; server-side upstream for same-origin API routes | `console-ui/src/lib/server/coordinator.ts` (`coordinatorUrl`), `console-ui/src/lib/coordinator-url.ts` |
| `NEXT_PUBLIC_PRIVY_APP_ID` | Missing or `placeholder` selects mock authentication; configure a real app for a hosted deployment | `console-ui/src/components/app-providers/PrivyClientProvider.tsx` (`IS_PRIVY_CONFIGURED`) |
| `NEXT_PUBLIC_GA_MEASUREMENT_ID` | Built-in measurement ID when missing; empty string disables analytics | `console-ui/src/lib/google-analytics.ts` (`getGoogleAnalyticsMeasurementId`) |
| `NEXT_PUBLIC_DD_APPLICATION_ID`, `NEXT_PUBLIC_DD_CLIENT_TOKEN` | Both required to enable Datadog RUM | `console-ui/src/components/DatadogRUM.tsx` |
| `NEXT_PUBLIC_DD_SITE` | `datadoghq.com` | `console-ui/src/components/DatadogRUM.tsx` |
| `NEXT_PUBLIC_DD_ENV` | `production` | `console-ui/src/components/DatadogRUM.tsx` |
| `NEXT_PUBLIC_APP_VERSION` | `dev` | `console-ui/src/components/DatadogRUM.tsx` |

The Settings API-example URL is a display preference, not an upstream routing
override. Request headers, cookies and browser storage cannot choose the
server's coordinator origin. See [console architecture](../architecture/components/console-ui.md#coordinator-url-resolution).

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
| `darkbloom start/stop/restart/update/logout --timeout` | `600` seconds; 0–3600 | `provider-swift/Sources/darkbloom/ServiceDrain.swift` (`DrainOptions`) |
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

## Provider endpoint resumption and logout

The separate physical diagnostic uses `DARKBLOOM_NATIVE_SERVE_QUALIFICATION`:
only exact `1` enables it; unset and every other value refuse before any proof
or model work. `NativeServeQualification.run` in
`provider-swift/Sources/ProviderCore/Diagnostics/NativeServeQualification.swift`
accepts no caller-provided signing key, binary hash, hardware or privacy claims.
It uses normal serving safeguards with private state, target-only contiguous
inference, no SSD prefix cache and no updater. This opt-in is not forwarded to
launchd and does not enable production coordinator resumption. See
[native serving qualification](../developer/test.md#native-serving-qualification).

| Setting | Behavior | Consumer |
|---|---|---|
| Endpoint-resumption capability | No new environment variable or config key. Normal serving installs a fixed process-key responder; registration advertises protocol 1 and a fresh nonce per socket. No responder means both fields are omitted. | `provider-swift/Sources/ProviderCore/ProviderLoop+Serve.swift` (`run`); `provider-swift/Sources/ProviderCore/Coordinator/CoordinatorClientCodec.swift` (`registrationMessage`) |
| `darkbloom logout --config` | Accepted for CLI compatibility, not used to retarget revocation. Logout uses issuer metadata bound to the saved token; missing metadata means local-only logout with a warning. Config parsing cannot block logout. | `provider-swift/Sources/darkbloom/LogoutCommand.swift` (`Logout.run`, `revokeSavedToken`); `provider-swift/Sources/ProviderCore/Auth/DeviceAuth.swift` (`AuthTokenStore.issuer`) |

The [wire contract](protocol-messages.md#app-attest-endpoint-resumption-candidate)
does not create local trust or change proof validity. The
[logout contract](../provider/cli-reference.md#darkbloom-login--darkbloom-logout)
defines stop-before-delete, force handling and remote confirmation. No worker
mode or update configuration changes are part of this addition.

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

Parsing convention: affirmative values are `1`/`true`/`yes`/`on`, negative values `0`/`false`/`no`/`off`, case-insensitive. Only the variables named in the [LaunchAgent environment passthrough](../provider/cli-reference.md#launchagent-environment-passthrough) reach an installed daemon; everything else applies to `darkbloom start --foreground` and to the benchmark and test binaries.

### Scheduler-prefill benchmark prompts

| CLI setting | Default / behavior | Consumer |
|---|---|---|
| `benchmark --scheduler-prefill --prefill-fixed-prompt` | Off by default: measured prompts rotate by `iteration * 17`. Enabled: warmup and measured prompts start at seed offset `0`, with identical inputs per length. CLI-only; no environment or `provider.toml` key. Other benchmark modes reject the flag before runtime loading. | `provider-swift/Sources/darkbloom/BenchmarkCommand.swift` (`prefillFixedPrompt`); `provider-swift/Sources/darkbloom/BenchmarkCommand+Sweep.swift` (`schedulerPrefillOptionError`, `runSchedulerPrefillBenchmark`); `provider-swift/Sources/ProviderBenchmark/SchedulerPrefillBenchmark.swift` (`run`, `makePrompt`) |

The [benchmark report metadata](../provider/cli-reference.md#darkbloom-benchmark) distinguishes
fixed repeated-input runs from rotating-fixture runs. This option does not
change the prefill stripe or enable prefix caching.

Scheduler prefill applies the existing `MLXMemoryGuard` memory/cache settings
before direct model loading, as serving and the throughput sweep do. It logs
the applied limits without changing their defaults, reserves or override rules.

### App Attest worker qualification

These are internal qualification opt-ins, **not production-ready configuration**.
They use exact `1`, not the general boolean parsing convention above. Only the
worker opt-in is forwarded by `darkbloom start` into the installed LaunchAgent;
native diagnostic and fault-injection flags are not. No `provider.toml` setting enables them.

| Variable | Values / default | Read in | Effect |
|---|---|---|---|
| `DARKBLOOM_APP_ATTEST_WORKER_QUALIFICATION` | Exact `1` enables; unset or anything else is `false` | `provider-swift/Sources/ProviderAppAttest/Worker/WorkerProtocol.swift` (`AppAttestWorkerSelection`); `provider-swift/Sources/ProviderCore/ProviderLoop.swift` (`usesAppAttestWorker`); `provider-swift/Sources/ProviderCore/Service/LaunchAgent.swift` (`passthroughEnvironment`) | Select the supervised worker candidate in foreground or background serving. Exact `1` is persisted in the provider plist; stop/start without it restores the default in-process path. Candidate failures do not fall back to in-process Apple calls or restart inference for a worker stall |
| `DARKBLOOM_NATIVE_APP_ATTEST_QUALIFICATION` | Exact `1` enables; unset or anything else is `false` | `provider-swift/Sources/darkbloom/AppAttestQualificationCommand.swift` (`runIfRequested`); `scripts/nativequalification/stage-signed-app.sh` | Opt in to local signed-app staging/the private diagnostic entry; the diagnostic also requires the worker flag, signed resources and isolated loopback inputs. Does not enable serving or approve a build |

The [worker security boundary](../architecture/security/identity-binding.md#supervised-app-attest-worker-candidate)
and [native qualification status](../../scripts/nativequalification/README.md#qualification-status)
remain separate from configuration selection. Endpoint-resumption capability is
[advertised independently](protocol-messages.md#app-attest-endpoint-resumption-candidate);
setting either flag creates no local trust and changes no proof lifetime.

### Startup model preload

Serving concurrency is resolved after the model's KV backend and verified
artifact are known. `BackendSettings.engineV2MaxConcurrentIsExplicit`
distinguishes an absent `engine_v2_max_concurrent` key (automatic, legacy
default `4` until an exact reviewed profile applies) from any existing literal
operator cap. Without a profile, models on the native `auto` paged allowlist
(`EngineV2KVBackendPolicy.preferredBackend`) start at the legacy ceiling `8` on
M5 Pro, Max and Ultra and return to `4` under Low Power Mode or thermal pressure
(`ServingPerformanceProfiles.automaticConcurrency`); a model paged only by an
explicit backend or live packed quantization keeps `4`. Serialization
preserves that distinction; historical literal values, including a stamped `4`,
are not silently raised. Per-model overrides remain explicit limits.
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
| `DARKBLOOM_R2_CDN_URL` | URL | build default `BuildEnvironment.current.modelCDNURL`: `https://models.darkbloom.ai` for prod and dev builds | `provider-swift/Sources/ProviderCore/Models/ModelDownloader.swift` (`resolveCDNURL`) | Mirror model weights are downloaded from. On the LaunchAgent allow-list, so the daemon downloads from the same mirror. |
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
| `DARKBLOOM_CBV2_KV_QUANTIZATION` | `balanced`, `k8v4`, `k8v8`, `native` (aliases in the [CLI reference](../provider/cli-reference.md#providertoml-keys-read-by-the-cli)) | `native` | `provider-swift/Sources/ProviderCore/Inference/Engine/EngineV2KVQuantizationPolicy.swift` (`resolve`, `.live`) | Overrides exact-model and global live precision settings. Only explicit live packed precision requires paged execution; native retains the model's automatic backend policy. MiMo resolves native before parsing. Forwarded to the LaunchAgent. |
| `DARKBLOOM_CBV2_CHECKPOINT_QUANTIZATION` | Same four precision values and aliases | `balanced` | `provider-swift/Sources/ProviderCore/Inference/Engine/EngineV2KVQuantizationPolicy.swift` (`resolve`, `.checkpoint`) | Overrides exact-model and global checkpoint settings independently. Eligible native paged/contiguous complete stores use lossy older-row encoding and native restore; unsupported cases retain native encoding, and live-packed stores keep their existing format. Does not enable caching, force a backend or grant serving RAM. MiMo resolves native before parsing. Forwarded to the LaunchAgent. |
| `DARKBLOOM_CBV2_PAGED_KV` | `0`, `false`, `no`, `off` disable paging | unset (policy decides) | `provider-swift/Sources/ProviderCore/Inference/Engine/EngineV2KVBackendPolicy.swift` (`preferredBackend`, `killSwitchDisabled`) | Kill switch for paged KV; beats the backend setting. Nemotron Super, which serves paged KV only, fails its load instead (`DARKBLOOM_NEMOTRON_SUPER_KV_BACKEND`). Native live precision can serve contiguous; non-MiMo live-packed precision refuses construction when paging is unavailable. See [backend and precision controls](../provider/cli-reference.md#providertoml-keys-read-by-the-cli). A backend default is not runtime qualification. |
| `DARKBLOOM_CBV2_PAGED_KV_DTYPE` | `float16`, `float32` | unset: observed native per-layer types | `provider-swift/Sources/ProviderCore/Inference/Engine/Factory/EngineV2Factory+BackendPreparation.swift` | Optional assertion for resolved paged storage; a nonempty value must match every measured native layer. Unsupported values or mismatches refuse explicit paged construction. |
| `DARKBLOOM_CBV2_PREFILL_CHUNK` | positive tokens | family policy: `2048` (`widePrefillChunkTokens`) for Gemma 4, otherwise the SDK's `512` | `provider-swift/Sources/ProviderCore/Inference/Engine/Factory/EngineV2Factory+Configuration.swift` (`prefillChunkTokens`, `prefillGeometry`) | Plain prefill chunk, including prompt work beside decode rows, for every model except where a family policy replaces it: GLM5Next (`glm5NextServingScheduler`) and Nemotron Super local serving (`DARKBLOOM_NEMOTRON_SUPER_PREFILL_CHUNK`, `NemotronSuperLocalPrefill.Policy.apply`) set their own chunk and step, and calibrated Nemotron models cap the chunk at their calibrated prefill limit (`calibratedPrefillTokenLimit`). Requests with bidirectional media blocks (Gemma 4 images and video) keep `512` whenever the chunk is wider. On Gemma 4 a value that leaves `max(chunk, stripe)` below its largest media block is raised to `1120` (`gemma4MaximumMediaBlockTokens`), because a block rides one chunk. Zero, negative or malformed values restore `512`. The paged pool sizes windowed rings from `max(chunk, stripe)`, so a value above the default stripe raises KV charges. Set it to `512` with `DARKBLOOM_CBV2_STEP_TOKENS=2048` to roll Gemma 4 back. `2048` with `DARKBLOOM_CBV2_STEP_TOKENS=4096` opts GPT-OSS or dense Qwen into the measured wide geometry, which raises their long-context activation peaks above their floors ([prompt geometry](../architecture/inference.md#prompt-geometry)). Forwarded to the LaunchAgent. |
| `DARKBLOOM_CBV2_STEP_TOKENS` | tokens, at least the plain chunk | twice the plain chunk, at least `2048` | `provider-swift/Sources/ProviderCore/Inference/Engine/Factory/EngineV2Factory+Configuration.swift` (`stepTokenBudget`) | Token budget per scheduler step. Smaller, zero, negative or malformed values restore `2048`, raised to the plain chunk. On Gemma 4 a budget below `1120` is raised to `1120`, because submit validation refuses a media block longer than the step budget. GLM5Next and Nemotron Super local serving replace it with their own budgets. Forwarded to the LaunchAgent. |
| `DARKBLOOM_CBV2_SOLO_PREFILL_STRIPE` | tokens | engine default: `4096` for dense Qwen3.5/3.8, otherwise `2048` | `provider-swift/Sources/ProviderCore/Inference/Engine/Factory/EngineV2Factory+Configuration.swift` (`soloPrefillStripeTokens`) | Solo-prefill stripe size; arms only above the plain chunk, so the 2,048-token default is off under Gemma 4's 2,048-token chunk. Malformed values and values not above the plain chunk, including zero, disable it. |
| `DARKBLOOM_CBV2_MIXED_PREFILL_CAP` | nonnegative tokens | reviewed profile cap; otherwise uncapped | `provider-swift/Sources/ProviderCore/Inference/Performance/MixedPrefillPolicy.swift` (`resolve`) | Caps prompt tokens in steps that also decode. Positive Gemma caps have a 128-token minimum; `0` defers prefill while decode is active. Does not change the pure-prefill stripe. Foreground/local only. |
| `DARKBLOOM_CBV2_MIXED_PREFILL_CAP_BY_MODEL` | comma-separated `model-id=tokens` | unset | `provider-swift/Sources/ProviderCore/Inference/Performance/MixedPrefillPolicy.swift` (`resolve`) | Exact model-ID overrides take precedence over the global cap, then the reviewed profile. Same nonnegative parsing and Gemma minimum; malformed entries are ignored. Foreground/local only. |
| `DARKBLOOM_CBV2_MAX_PARTIAL_PREFILLS` | integer (`0` = unlimited) | `1` | `provider-swift/Sources/ProviderCore/Inference/Engine/Factory/EngineV2Factory+Configuration.swift` | Maximum concurrent partial prefills. |
| `DARKBLOOM_TTFT_FUSED_CAUSAL_PREFILL` | exact `0` disables | on | `libs/mlx-swift-lm/Libraries/MLXLMCommon/ContinuousBatchingV2/AttentionV1.swift` (`CBv2AttentionV1.fusedCausalPrefillEnabled`, `usesFusedCausalPrefill`) | Full-attention prompt chunks whose head geometry MLX serves with a fused kernel take one `.causal` SDPA call on either KV backend, except live packed paged KV ([eligible chunks](../architecture/inference.md#scheduler-and-loop-configuration)); `0` returns them to 128-query blocks. Read once per process; not forwarded to LaunchAgents. |
| `DARKBLOOM_CBV2_LEGACY_REQUEST_TIMEOUT` | affirmative | off | `provider-swift/Sources/ProviderCore/Inference/Engine/Factory/EngineV2Factory+Configuration.swift` | Restores the legacy per-request timeout. |
| `DARKBLOOM_CBV2_MTP` | negative disables | unset (beta flag decides) | `provider-swift/Sources/ProviderCore/SpecDec/SpecDecArtifactFunnel.swift`; `provider-swift/Sources/ProviderCore/Config/BetaFeatures.swift` | Kill switch for MTP speculation; beats the `provider.toml` beta flag. See [`../provider/beta-features.md`](../provider/beta-features.md). |
| `DARKBLOOM_MTP_MAX_RECTANGULAR_TOKENS` | integer | policy default | `provider-swift/Sources/ProviderCore/Inference/MTP/MTPAutomaticVerificationPolicy.swift` | Tighten-only cap on rectangular MTP verification tokens. |
| `DARKBLOOM_TTFT_QWEN_MTP_CHAINED` | `0`, `false`, `no`, `off` disable | on | `libs/mlx-swift-lm/Libraries/MLXLMCommon/ContinuousBatchingV2/MTP/MTPContractsV2.swift` (`CBv2MTPConfig.envOrdinaryDecodeHistory`) | While no Qwen inline-MTP row can speculate (more decode rows than its speculative batch of one), steps in which every MTP-eligible row is decoding run as ordinary chainable decode with no policy top-two; finalize feeds the assistant history and carry. Off restores hidden-returning seed steps. Not forwarded to LaunchAgents. |
| `DARKBLOOM_TTFT_QWEN_MTP_CARRY` | `0`, `false`, `no`, `off` disable | on | `libs/mlx-swift-lm/Libraries/MLXLMCommon/ContinuousBatchingV2/MTP/MTPContractsV2.swift` (`CBv2MTPConfig.envPrefillCarry`) | The final prompt row's hidden seeds the first Qwen MTP carry, so a round can follow the first token. Off restores the post-first-token seed step. Not forwarded to LaunchAgents. |
| `DARKBLOOM_NEMOTRON35_MTP_CAPTURE_VERIFY` | exact `0` disables | on | `libs/mlx-swift-lm/Libraries/MLXLLM/Models/NemotronH35MTP.swift` (`requiredVerificationMode`) | Captured rectangular verification with every-prefix recurrent state; `0` uses serial target verification. Not forwarded to LaunchAgents. |
| `DARKBLOOM_NEMOTRON35_MTP_BATCHED_M1` | exact `0` disables | on | `libs/mlx-swift-lm/Libraries/MLXLLM/Models/NemotronH35MTPExactRows.swift` (`NemotronMTPExecution`) | Batch-axis projection dispatch that retains matrix M=1. No change to target precision; not forwarded to LaunchAgents. |
| `DARKBLOOM_NEMOTRON35_MTP_KV_ONLY_HISTORY` | exact `0` disables | on | `libs/mlx-swift-lm/Libraries/MLXLLM/Models/NemotronH35MTP.swift` (`NemotronH35MTPAssistant`) | Trusted-history replay may compute only the embedded assistant's K/V. Prefix save/restore uses the separate typed history codec. Not forwarded to LaunchAgents. |
| `DARKBLOOM_NEMOTRON35_MTP_MAX_DRAFT_TOKENS` | integer `1`…`7` | `7` | `libs/mlx-swift-lm/Libraries/MLXLLM/Models/NemotronH35MTP.swift` (`NemotronH35MTPAssistant`) | Upper proposal limit for adaptive depth; invalid selected limits fall back to seven. This is not a fixed proposal count. Not forwarded to LaunchAgents. |
| `DARKBLOOM_NEMOTRON_SUPER_MTP` | exact `1` enables (surrounding spaces ignored) | off | `provider-swift/Sources/ProviderCore/Inference/Engine/Factory/NemotronSuperLocalMTP.swift` (`Setting.resolve`) | Greedy text speculation for the Super qualification hook with the checkpoint's embedded head. The managed `nvidia-nemotron-3.5-super` slot sets or clears it from `backend.mtp_mode` (below) and ignores this value. Adds the head's LOAD supplement; image requests on the speculating owner run target-only. `DARKBLOOM_CBV2_MTP` still disables it. Not forwarded to LaunchAgents. |
| `DARKBLOOM_NEMOTRON_SUPER_MTP_DEPTH` | integer `1`…`3`, `auto`, or a comma list of up to eight depths `1`…`3` | `1` | `provider-swift/Sources/ProviderCore/Inference/Engine/Factory/NemotronSuperLocalMTP.swift` (`Setting.resolve`) | Fixed Super draft depth; above one is the deep-draft opt-in. A list fixes the depth by the requests decoding in the step (entry N for N requests, the last for more; rectangular only). The managed slot defaults it to `3,2,2,2,1` and keeps an explicit value. Any other value fails the opt-in load. Ignored unless `DARKBLOOM_NEMOTRON_SUPER_MTP` is `1`. |
| `DARKBLOOM_NEMOTRON_SUPER_MTP_VERIFICATION` | `rectangular` or `serial` (surrounding spaces ignored) | `rectangular` | `provider-swift/Sources/ProviderCore/Inference/Engine/Factory/NemotronSuperLocalMTP.swift` (`Setting.resolve`) | Super target verification: `rectangular` runs one exact captured target window per round, `serial` one ordinary target step per draft. Any other value fails the opt-in load. Ignored unless `DARKBLOOM_NEMOTRON_SUPER_MTP` is `1`. |
| `DARKBLOOM_NEMOTRON_SUPER_KV_BACKEND` | `paged` (surrounding spaces ignored) | `paged` | `provider-swift/Sources/ProviderCore/Inference/Engine/Factory/NemotronSuperLocalKVBackend.swift` (`resolve`) | Super attention KV storage, paged only: the eight attention layers' BF16 KV in the segmented native paged backend, charged by the engine's process-memory owner, with every request's decode-row workspace reserved for the owner's lifetime. `contiguous` is no longer supported and fails the load, as does any other value, before its LOAD claim and installation; so does `DARKBLOOM_CBV2_PAGED_KV` disabling paged KV. A paged construction failure fails the load, never falls back. Not forwarded to LaunchAgents. |
| `DARKBLOOM_NEMOTRON_SUPER_MAX_CONCURRENT` | integer `1`…`64`; `1`…`8` with `DARKBLOOM_NEMOTRON_SUPER_MTP=1` (surrounding spaces ignored) | `1` | `provider-swift/Sources/ProviderCore/Inference/Engine/Factory/NemotronSuperLocalAdmission.swift` (`concurrentRequests`); `provider-swift/Sources/ProviderCore/Inference/Engine/Factory/NemotronSuperLocalMTP.swift` (`validate`) | Requests the Super qualification hook's owner serves at once (the managed slot sets it from its slot policy, below); above one, text decode runs as one row-exact batched step, and with speculation one rectangular verify window covers every decoding request. Any other value, or a value above one with `DARKBLOOM_NEMOTRON_SUPER_MTP_VERIFICATION=serial`, fails the load. The KV grant must hold every request's fixed bytes. Not forwarded to LaunchAgents. |
| `DARKBLOOM_NEMOTRON_SUPER_VIDEO_PRUNING` | number in [0, 1) (surrounding spaces ignored) | `0.5` (`NemotronSuperVideoPreprocessing.defaultPruningRate`) | `provider-swift/Sources/ProviderCore/Inference/Vision/NemotronSuperVideoFeatures.swift` (`validatedPruningRate`) | EVS pruning rate `q` of Super video requests, in the managed slot and the qualification hook: a video of `T` tubelets of `N` visual rows keeps `max(N, int(T * N * (1 - q)))` rows; `0` keeps every row. Any other value fails the load before its LOAD claim and installation. A value below `0.5` keeps more rows, so a video's prompt has more tokens than the coordinator estimates for it, since that estimate assumes `0.5`. Not forwarded to LaunchAgents. |
| `DARKBLOOM_MTP_VERIFICATION_MODE` | `rectangular`, `serial`, `serial_target`, `automatic` | `automatic` | `provider-swift/Sources/ProviderBenchmark/MTPProductionSession.swift` | MTP verification strategy (benchmark session). |
| `DARKBLOOM_MTP_ACCEPTANCE` | `exact`, `typical`, `typical:<delta>` (finite positive delta) | `exact` | `provider-swift/Sources/ProviderBenchmark/MTPProductionSession.swift`; `provider-swift/Sources/ProviderCore/Inference/MTP/MTPAcceptancePolicy.swift` (`benchmarkOverride`) | MTP draft acceptance rule (benchmark session only). An unrecognized value uses `exact`. Serving reads no environment variable for this rule; it reads `[backend] mtp_acceptance` and `mtp_acceptance_by_model` in [`provider.toml`](../provider/cli-reference.md#providertoml-keys-read-by-the-cli). |
| `DARKBLOOM_PREFILL_DEADLINE_MODE` | exactly `off` disables; any other value enforces | `enforce` | `provider-swift/Sources/ProviderCore/Inference/Engine/PrefillDeadlineMode.swift` (`PrefillDeadlineMode.resolve`) | Prefill-deadline admission on the provider. Read only when `[backend] prefill_deadline_mode` is absent from `provider.toml`; that key takes precedence. |
| `DARKBLOOM_TTFT_ADMISSION_FIXES` | `0`, `false`, `off`, `no` disable (trimmed, case-insensitive) | on | `provider-swift/Sources/ProviderCore/Inference/Performance/Deadline/AdmissionRateEstimators.swift` (`DeadlineAdmissionFixes`) | Deadline-admission estimator corrections: per-batch decode charging, anchored isolated-prefill rate, newest-observation freshness. Off restores the previous estimators. Forwarded to the launchd provider job. |
| `DARKBLOOM_TTFT_SHAPE_WARMUP` | trimmed, case-insensitive `0`, `false`, `no`, `off` disable; `always` skips the probe | unset: probe-gated warmup | `provider-swift/Sources/ProviderCore/Inference/Performance/ModelCalibrationPolicy.swift` (`shapeWarmupMode`) | Excluded load-time [shape warmup](../architecture/inference.md#model-startup-calibration) for ordinary `EngineV2` slots: a 128-token shader-cache probe runs twice and only a cold cache runs the shape cells, within 20 seconds per engine. Trains no rate or counter. Forwarded to the LaunchAgent. |
| `DARKBLOOM_GEMMA4_PREFILL_CHUNK_EVAL` | integer layers | projected from `provider.toml` (`18`) | `provider-swift/Sources/ProviderCore/Config/GemmaOptimizationEnvironment.swift` | Gemma-4 prefill chunk-eval layers; the provider sets it for the engine, `scripts/install.sh` sets `18` for the smoke test. |
| `DARKBLOOM_TTFT_GDN_BLOCKED` | `0`, `false`, `no`, `off` keep the stock kernel; `packed` or `rows` force that kernel; unset or any other value probes. Case-insensitive; surrounding whitespace is ignored | probe | `libs/mlx-swift-lm/Libraries/MLXLLM/Models/GatedDelta.swift` (`GatedDeltaPrefill.mode`, `GatedDeltaPrefill.kernel`) | Selects the Gated DeltaNet prompt-window kernel of `qwen3_5`, `qwen3_5_moe` and `prism_hadamard_qwen35` models ([mechanism](../architecture/inference.md#context)). The default probe keeps a four-row kernel only where it reproduces `gated_delta_step` bit for bit on the GPU; it does not compare speed, so `0` is the rollback where a kept kernel is slower. Forced kernels skip that check and are for A/B measurement only. Decode, MTP verification and masked updates always use the stock kernel. Read once per process. Forwarded to the LaunchAgent. |
| `DARKBLOOM_ENGINE_V2_VLM_PARITY_CHECK` | `0` skips | on | `provider-swift/Sources/ProviderCore/Inference/Vision/EngineV2VLMTextExtraction.swift` | VLM text-extraction parity check. |
| `DARKBLOOM_TTFT_STREAM_TOOL_CALLS` | exact `0` disables | on | `provider-swift/Sources/ProviderCore/Inference/ToolStreamPreparation.swift` (`streamsToolCallsByDefault`) | Chat streams send `tool_choice` `auto` calls in the Gemma, Qwen 3.5, Harmony and framed-JSON formats as OpenAI `tool_calls` fragments while they are generated; each call is still validated when its frame closes. Required/named calls and other formats are unchanged. `0` restores complete calls at the engine terminal. See [streamed auto tool calls](../architecture/inference.md#streamed-auto-tool-calls). Forwarded to the LaunchAgent. |
| `DARKBLOOM_TTFT_THINK_CONTENT_SEED` | exact `0` disables | on | `provider-swift/Sources/ProviderCore/Inference/Prompting/ReasoningPromptProbe.swift` (`seedsPlainTailContentByDefault`) | Qwen3-VL (`qwen3_vl_moe`, `plainTailContentModelTypes`) requests on the `qwen3` reasoning parser whose prompt tail has no think marker start in content state, so the answer streams instead of waiting for a tag or the end of generation. Other model types, including close-only Qwen reasoners, keep undecided parsing. `0` restores undecided parsing. Forwarded to the LaunchAgent. |

### Managed Nemotron Super slot

The managed `nvidia-nemotron-3.5-super` slot reads provider configuration, not
the qualification hook's keys, for speculation and width
(`NemotronSuperServingPolicy.loadPlan` in
`provider-swift/Sources/ProviderCore/Inference/Engine/Factory/NemotronSuperServingPolicy.swift`).

| Control | Default | Effect |
|---|---|---|
| `backend.mtp_mode` | `auto` | `auto` and `on` install exact rectangular speculation with the embedded head, depth 3 for one decoding request, 2 for two to four and 1 for more; `off`, or `DARKBLOOM_CBV2_MTP` negative, serves the plain owner |
| `backend.engine_v2_max_concurrent`, `engine_v2_max_concurrent_by_model` | absent: 8 requests | An explicit value bounds the owner's width (at most 8 with speculation, 64 plain) |
| `DARKBLOOM_NEMOTRON_SUPER_MTP_DEPTH`, `_MTP_VERIFICATION`, `_PREFILL_CHUNK`, `_DECODE_STEPS_BETWEEN_CHUNKS`, `_KV_BACKEND`, `_VIDEO_PRUNING` | depth `3,2,2,2,1`; the [builder defaults](../architecture/inference.md#context) otherwise | Kept when set in the provider process |
| `DARKBLOOM_PREFIX_CACHE_MEMORY` | on for either owner when the grant holds every request's fixed bytes and the bank | An explicit value, `DARKBLOOM_PREFIX_CACHE` negative or `DARKBLOOM_CBV2_HYBRID_PREFIX_CACHE=0` keeps the bank off |

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
| `DARKBLOOM_GLM_RECTANGULAR_VERIFY` | unset enables; rollback: trimmed, case-insensitive `0`, `false`, `no`, `off` | on (rectangular adaptive MTP verification, depth up to 3; greedy output is not token-identical to target-only decode); rollback selects the serial-target single-proposal profile | `provider-swift/Sources/ProviderCore/Inference/Models/GLM5Next/GLM5NextProtectedExecution.swift` (`GLM5NextProtectedModel.verification`); does not itself enable MTP. Forwarded to the launchd provider job |
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
| `DARKBLOOM_TTFT_IDLE_CACHE_SWEEP` | exact `0` disables | on | `provider-swift/Sources/ProviderCore/Inference/Memory/GlobalKVCacheBudget.swift` (`idleCacheSweepEnabled`); `provider-swift/Sources/ProviderCore/Inference/Memory/KVPoolReclaimer.swift` (`proactiveWindow`) | Gates the proactive buffer-cache sweep (cache ≥ 2 GiB) on 5 s of whole-Mac idleness, flushing without reporting device activity while request admission waits (`WholeMacServiceBudget.performIfIdle`); busy engines flush only when the pool crowds out admission headroom. `0` restores flushing between busy engines' steps. Refused engine-owned KV charges and native MiMo media reservations signal a shortfall-gated reclaim unless this and `DARKBLOOM_TTFT_SEGMENT_RETENTION` are both `0` (`busyEnginesKeepReclaimableMemory`). Forwarded to the launchd provider job. |
| `DARKBLOOM_TTFT_SEGMENT_RETENTION` | exact `0` disables | on | `provider-swift/Sources/ProviderCore/Inference/Engine/Factory/EngineV2Factory+SegmentedBackend.swift` (`segmentRetentionEnabled`) | Paged pools keep up to `min(2 GiB, slot grant / 8)` of free KV segments, uncommitted and uncharged, and reinstall them at admission instead of allocating, filling and fencing new ones; dropped on a refused admission, on process memory pressure (any refused charge, a pressure sweep or a macOS memory-pressure event), before a load gate (provider, standalone or managed Nemotron Super) evicts a resident model or refuses and before startup preload skips a model (load admission counts them as reclaimable only until that release; segments still parked afterwards never justify an eviction), and after 30 s of engine idleness. New segments whose size is a whole number of VM pages wrap zero-fill-on-demand host pages (no stream fence). `0` restores release-time trimming and device-filled segments. Forwarded to the launchd provider job. |
| `DARKBLOOM_TTFT_SEGMENT_HOST_ZEROS` | exact `0` disables | on (with retention) | `provider-swift/Sources/ProviderCore/Inference/Engine/Factory/EngineV2Factory+SegmentedBackend.swift` | `0` keeps segment retention but allocates new segments with the device zero fill plus stream fence. Forwarded to the launchd provider job. |
| `DARKBLOOM_MLX_MEMORY_RESERVE_GB` | GiB | `provider.toml` `memory_reserve_gb` | `provider-swift/Sources/ProviderCore/Inference/Memory/MLXMemoryGuard.swift` | Overrides the whole-machine memory reserve. |
| `DARKBLOOM_MEM_CAP_FRACTION` | fraction | `0.90` | `provider-swift/Sources/ProviderCore/Inference/Memory/UnifiedMemoryCap.swift` | Share of unified memory the engine may address. |
| `DARKBLOOM_MEMORY_AVAILABILITY` | `reclaimable` / `free-only` | `reclaimable` | `provider-swift/Sources/ProviderCore/Inference/Memory/SystemMemory.swift` | Process-start policy shared by admission, KV budgets and diagnostics; persisted into the provider launchd plist on background start. `reclaimable` counts Mach free pages plus the file-backed page cache (`external_page_count`, speculative read-ahead counted once) and volatile purgeable pages; anonymous pages, active or inactive, and compressed memory are never counted (`SystemMemory.availableBytes`). `free-only` counts only free pages and fails closed if sampling fails. Unknown/empty explicit values select `free-only`. See [shared-host admission](https://github.com/Layr-Labs/darkbloom-platform/blob/48a198c71a2d30feec5597bacf1101120f7f955d/docs/architecture/scheduling.md#shared-host-memory-admission). |
| `DARKBLOOM_ACTIVATION_RESERVE_GB` | GiB (raise-only) | [Resolved serving-set floor](../architecture/hardware-support.md#cap-and-reserves-unifiedmemorycap) | `provider-swift/Sources/ProviderCore/Inference/Memory/UnifiedMemoryCap.swift` (`resolvedActivationReserveBytes`) | Raises activation headroom above the effective floor; a lower value cannot reduce it. The [ordinary picker](../provider/cli-reference.md#darkbloom-start) resolves that floor from the complete selection; Autopilot enrollment retains the flat floor. |
| `DARKBLOOM_VISION_MAX_TOWER_PATCHES` | integer (lower-only) | model default | `provider-swift/Sources/ProviderCore/Inference/Vision/VisionTowerBudget.swift` | Caps vision-tower patches. |
| `DARKBLOOM_MAX_IMAGE_MEGAPIXELS`, `DARKBLOOM_MAX_REQUEST_IMAGE_MEGAPIXELS` | megapixels | `100`, `384` | `provider-swift/Sources/ProviderCore/Inference/Vision/MediaIngest.swift` | Per-image and per-request pixel caps. |
| `DARKBLOOM_MAX_MEDIA_MIB` | MiB | `25` | `provider-swift/Sources/ProviderCore/Inference/Vision/MediaIngest.swift` | Per-request media bytes. |
| `DARKBLOOM_MAX_VIDEO_SECONDS` | seconds | `600` | `provider-swift/Sources/ProviderCore/Inference/Vision/MediaIngest.swift` | Per-video duration cap. |
| `DARKBLOOM_MAX_IMAGES_PER_REQUEST`, `DARKBLOOM_MAX_VIDEOS_PER_REQUEST` | integers | `16`, `8` | `provider-swift/Sources/ProviderCore/Inference/Vision/MediaIngest.swift` | Attachment count caps. |
| `DARKBLOOM_MAX_REQUEST_VIDEO_FRAME_MEGAPIXELS` | megapixels | `384` | `provider-swift/Sources/ProviderCore/Inference/Vision/MediaIngest.swift` | Per-request decoded video-frame pixel cap. |

### Model verification I/O

The default reusable-buffer reader and bounded parallel hashing change full-file
reading and scheduling, not the verified
bytes or model arithmetic. Each file is first read through a page-aligned
`F_NOCACHE` descriptor (`WeightHasher.hashSingleFileUncached`), so verification
does not pull a second copy of loaded weights through the file cache; the
readers selected below remain its fallbacks. Discovery remains hash-free. Fresh pre/post-load
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

### Prompt preparation and admission

| Variable | Values / type | Default | Read in | Effect |
|---|---|---|---|---|
| `DARKBLOOM_TTFT_PROMPT_CACHE` | `0`, `false`, `off`, `no` disable | on | `provider-swift/Sources/ProviderCore/Inference/Prompting/PromptTokenCache.swift` (`PromptTokenCachePolicy.isEnabled`) | Reuses the token IDs of rendered chat-template pieces (text between added tokens) already seen in the request's prefix-cache scope; the IDs equal the uncached path. The global `DARKBLOOM_PREFIX_CACHE` disable also turns it off. Read at tokenizer load. Forwarded by LaunchAgent. |
| `DARKBLOOM_TTFT_PROMPT_CACHE_MB` | MiB, `0`…`4096` | `32` | same file (`capacityBytes`) | Least-recently-used piece storage per loaded tokenizer; `0` keeps only the multi-core encoding of new long prompts. Read at tokenizer load. Forwarded by LaunchAgent. |
| `DARKBLOOM_TTFT_PROMPT_CACHE_VERIFY` | integer, `0` off | `256` | same file (`verificationInterval`) | Re-tokenizes each tokenizer's first 4 prompts, then one in N, on the uncached path in the background; a mismatch, or an uncached path that throws, disables reuse for that tokenizer. `darkbloom benchmark --prompt-prep` sets `0`. Read at tokenizer load. Forwarded by LaunchAgent. |
| `DARKBLOOM_TTFT_TEMPLATE_LOOPS` | `0`, `false`, `off`, `no` disable | on | `provider-swift/Sources/ProviderCore/Inference/Prompting/ChatTemplateLoopRewrites.swift` (`ChatTemplateLoopRewrites.isEnabled`) | The prompt token cache renders Gemma 4 and GPT-OSS templates through linear-time forms of their per-message history scans, which render the same text; used only when the load-time comparison with the served template passes, and checked by the same background comparisons. Read at tokenizer load. Forwarded by LaunchAgent. |
| `DARKBLOOM_TTFT_COLD_LOAD_RELEASE` | `0`, `false`, `off`, `no` disable | on | `provider-swift/Sources/ProviderCore/ProviderLoop+WorkFIFO.swift` (`WorkFIFOPolicy`) | Lets later coordinator events overtake a request waiting for its model load (see [process boundaries](../architecture/components/provider.md#process-boundaries)). Read at loop start. Forwarded by LaunchAgent. |

### SSD prefix cache

The optional `[cache]` table in `provider.toml` is saved by
`darkbloom cache set` and read by `Start.run` before serving. It applies to both
attention blocks and complete checkpoints. It does not enable a model's cache
capability or alter the TTL, encryption or memory safeguards.

| Key | Type / default | Effect | Source |
|---|---|---|---|
| `cache.daily_write_gb` | Optional nonnegative finite decimal GB; absent uses environment/default below | `0` explicitly means unlimited. A positive value must represent at least one byte and fit in `Int`; saved values win over the environment after restart | `provider-swift/Sources/ProviderCore/Config/CacheSettings.swift` (`validate`), `provider-swift/Sources/ProviderCore/KVCacheSSD/CacheStorage.swift` (`dailyWriteBytes`) |
| `cache.directory` | Optional absolute existing directory | Payloads use its `darkbloom/kv3` child (a dev build: its own namespace); absent retains the built-in cache directory. No automatic migration or fallback when configured storage is unavailable | `CacheStorage.swift` (`root`), `provider-swift/Sources/ProviderCore/KVCacheSSD/CacheVolume.swift` (`inspect`) |
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
| `DARKBLOOM_DEBUG_CACHE_KEY_FILE` | absolute path; empty is unset | unset | `provider-swift/Sources/ProviderCore/KVCacheSSD/SSDDebugCacheKeyFile.swift` (`load`) | DEBUG builds only; release builds do not compile this path. Replaces the Secure Enclave/Keychain SSD cache KEK with one derived from an existing operator-created file (`(umask 077 && head -c 32 /dev/urandom > FILE)`), reported as persistent. The file must be exactly 32 bytes, a regular file owned by the current user with mode `0600` and one link; the final path component must not be a symlink. Any other file refuses with a typed `key_unavailable` cause (an affirmative `DARKBLOOM_PREFIX_CACHE_ALLOW_EPHEMERAL` still falls back to an ephemeral key). The file is never created or rewritten. An explicit persistent test namespace keeps its own enclave key. Not forwarded to LaunchAgents. |
| `DARKBLOOM_PREFIX_CACHE_SSD_TTL_SECONDS` | seconds ≤ 1800 | `1800` | `provider-swift/Sources/ProviderCore/KVCacheSSD/SSDPrefixCachePolicy.swift` | Entry time-to-live. |
| `DARKBLOOM_PREFIX_CACHE_SSD_MAX_WRITE_GB_PER_DAY` | GB/day (`0` unlimited) | `4000` | `provider-swift/Sources/ProviderCore/KVCacheSSD/SSDPrefixCachePolicy.swift` | Persistent rolling-day write budget; includes serialized cache-file framing. A saved `cache.daily_write_gb` takes precedence. Forwarded to newly installed launchd jobs. See [accounting and limits](ssd-kv-cache.md#size-and-eviction-rules). |
| `DARKBLOOM_PREFIX_CACHE_SSD_MIN_EFFECTIVE_TOKENS` | tokens | `1024` | `provider-swift/Sources/ProviderCore/KVCacheSSD/SSDPrefixCachePolicy.swift` | Smallest prefix worth persisting. |
| `DARKBLOOM_PREFIX_CACHE_SSD_WINDOW_SIDECAR` | affirmative | off | `provider-swift/Sources/ProviderCore/KVCacheSSD/SSDPrefixCachePolicy.swift` | Persists the sliding-window sidecar. |
| `DARKBLOOM_PREFIX_CACHE_SSD_MAX_STAGE_MB`, `DARKBLOOM_PREFIX_CACHE_SSD_MAX_STAGE_MS` | MiB, ms | `1024`, `1000`; complete checkpoints on Macs with ≥ 48 GiB: `7168`, `15000` | `provider-swift/Sources/ProviderCore/KVCacheSSD/SSDPrefixCachePolicy.swift` | Attention staging byte/time caps. Complete checkpoints apply the byte value as a payload cap and the time value as an estimated-read cap when capturing and reading (both defaults raised on large-memory Macs; an explicit value overrides both families); native destination plus bounded scratch is separately reserved before allocation, with no permanent RAM carve. Not forwarded to LaunchAgents, so installed daemons use the defaults. |
| `DARKBLOOM_PREFIX_CACHE_SSD_STRICT_FSYNC` | affirmative | off | `provider-swift/Sources/ProviderCore/KVCacheSSD/SSDPrefixCachePolicy.swift` | `fsync` after every write. |

### Resident recurrent prefix cache

These overrides are read at slot construction in foreground/local and test
processes; neither is on the LaunchAgent environment allow-list. Both require
`DARKBLOOM_PREFIX_CACHE_MEMORY=1` first; that opt-in and the global cache switch
are forwarded to the LaunchAgent. Backend/model/assistant
eligibility, measured publication limits, and the conservative reservation after
a slot shrink are described in
[`../architecture/prefix-cache.md#resident-tiers`](../architecture/prefix-cache.md#resident-tiers).
Provider cache enablement does not enable coordinator preference. The pinned
[coordinator/registry/config.go](https://github.com/Layr-Labs/darkbloom-platform/blob/48a198c71a2d30feec5597bacf1101120f7f955d/coordinator/registry/config.go)
snapshot (`ReadConfig`) records an independent `EIGENINFERENCE_CACHE_ROUTING_MODE`
default of `off`; consult the platform's latest default branch for current policy.

| Variable | Values / type | Default | Read in | Effect |
|---|---|---|---|---|
| `DARKBLOOM_CBV2_HYBRID_PREFIX_CACHE` | exact `0` disables | unset (eligible only after memory opt-in) | `provider-swift/Sources/ProviderCore/Inference/PrefixCache/PrefixCachePolicy+Hybrid.swift` (`hybridConfig`) | Disables recurrent checkpoint retention without changing paged/SSD policy or MTP mode. |
| `DARKBLOOM_CBV2_HYBRID_PREFIX_BYTES` | integer bytes | `min(1 << 30, max(0, kvBytesCapacity / 8))`; the pinned Nemotron Super checkpoint uses `NemotronSuperServingPolicy.defaultPrefixBankBytes` instead | `provider-swift/Sources/ProviderCore/Inference/PrefixCache/PrefixCachePolicy+Hybrid.swift` (`hybridConfig`), `provider-swift/Sources/ProviderCore/Inference/Engine/Factory/NemotronSuperServingPolicy.swift` | Reservation inside the existing slot KV grant; parsed values outside `0 < bytes < kvBytesCapacity` disable the bank, malformed values use the default. The Super default is `min(16 GiB, grant / 4, serving / 2, load / 2)` rounded down to 256 MiB, where `serving` is the grant minus every request's fixed bytes plus 2 GiB, the prefill lane bound and one image's media charge, and `load` is the memory cap minus the activation reserve, the LOAD claim's installation and head bytes (counted once), the same fixed bytes and the lane bound; below 1 GiB there is no default bank. |

`CBv2HybridPrefixCacheConfig` defaults to `maximumEntries = 32` and
`maximumCheckpointsPerRequest = 2`; the Super owner raises the entry limit to
one per 256 MiB of bank. These have no CLI environment overrides
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
| `MLX_QUANTIZED_CONSTANT_CACHE` | `0`, `false`, `no`, `off` disable | enabled | `libs/mlx-swift/Source/MLX/ConstantArrayCastCache.swift` (`ConstantArrayCastCache`): bounded reuse of unchanged BF16-to-FP32 constants; updates invalidate and transforms bypass reuse. A bf16 GPT-OSS checkpoint keeps bf16 activations, so its constants need no widening and this cache does not apply to it. |
| `MLX_GPTOSS_MXFP4_DECODE_FAST_TAIL` | `1` enables, other explicit values disable | enabled only on physical `applegpu_g16s` | `libs/mlx-swift/Source/Cmlx/mlx/mlx/backend/metal/quantized.cpp` (`gather_qmv`): width-2880 MXFP4 gathered matrix-vector path with a masked 320-element tail. Exact shape/dtype gates retain the general fallback. |
| `MLX_GPTOSS_MXFP4_PREFILL_TILE` | `m32n32k32`; other values use legacy | legacy | `libs/mlx-swift/Source/Cmlx/mlx/mlx/backend/metal/gptoss_mxfp4_policy.h` (`gptoss_mxfp4_prefill_tile`): optional 32-row tile for matching sorted expert prefill shapes. Small workstation gains do not establish a universal default. |
| `DARKBLOOM_GPTOSS_COMPILED_EXPERTS` | `1` enables | disabled | `libs/mlx-swift-lm/Libraries/MLXLLM/Models/GPTOSS+CompiledExperts.swift` (`GPTOSSCompiledExpertsPolicy`): compile single-token B=1/2/4 expert graphs for exact 20B shapes. The global `MLX_COMPILED_DECODE=0` rollback still disables this path. Batch-dependent timing is mixed; weights remain live through weak updatable state. |
