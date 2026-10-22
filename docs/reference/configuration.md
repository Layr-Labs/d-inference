# Configuration reference

> Last updated: 2026-10-21

Provider CLI, native-runtime and retained-console environment variables, compiled defaults and reading symbols. Secrets are named, never valued. Unless specified otherwise, values are read at process start.

Coordinator and admin settings belong to the [platform configuration reference](https://github.com/Layr-Labs/darkbloom-platform/blob/48a198c71a2d30feec5597bacf1101120f7f955d/docs/reference/configuration.md).
Pinned platform links on this page are immutable evidence snapshots, not claims
about current platform behavior. For current settings and behavior, consult the
latest default branch of [darkbloom-platform](https://github.com/Layr-Labs/darkbloom-platform).

## Local GLM qualification

Cluster image qualification is a separate local selection:
`darkbloom cluster local glm-5.3-flash --private-glm-image-qualification`.
`ClusterGLMImageCandidate.profileID` binds planning, request admission and worker
LOAD to the bounded image candidate. It requires the current paired leader and
the exact cached source; it does not enable images for the ordinary text profile
or admit coordinator or solo requests. The flag is defined in
`provider-swift/Sources/darkbloom/ClusterLocalCommand.swift`.

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
whitespace. An explicit `~user` requires an existing system account, including
when a process uses a fixed home directory (`ModelScanner.expandingTilde`). The selected candidate must be an existing readable, searchable,
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
| `DARKBLOOM_NEMOTRON_SUPER_MTP` | exact `1` enables (surrounding spaces ignored) | off | `provider-swift/Sources/ProviderCore/Inference/Engine/Factory/NemotronSuperLocalMTP.swift` (`Setting.resolve`) | Greedy text speculation for the Super qualification hook with the checkpoint's embedded head. The managed `nvidia-nemotron-3.5-super` slot sets or clears it from `backend.mtp_mode` (below) and ignores this value. Adds the head's LOAD supplement; image requests on the speculating owner run target-only. `DARKBLOOM_CBV2_MTP` still disables it. Not forwarded to LaunchAgents. |
| `DARKBLOOM_NEMOTRON_SUPER_MTP_DEPTH` | integer `1`…`3`, `auto`, or a comma list of up to eight depths `1`…`3` | `1` | `provider-swift/Sources/ProviderCore/Inference/Engine/Factory/NemotronSuperLocalMTP.swift` (`Setting.resolve`) | Fixed Super draft depth; above one is the deep-draft opt-in. A list fixes the depth by the requests decoding in the step (entry N for N requests, the last for more; rectangular only). The managed slot defaults it to `3,2,2,2,1` and keeps an explicit value. Any other value fails the opt-in load. Ignored unless `DARKBLOOM_NEMOTRON_SUPER_MTP` is `1`. |
| `DARKBLOOM_NEMOTRON_SUPER_MTP_VERIFICATION` | `rectangular` or `serial` (surrounding spaces ignored) | `rectangular` | `provider-swift/Sources/ProviderCore/Inference/Engine/Factory/NemotronSuperLocalMTP.swift` (`Setting.resolve`) | Super target verification: `rectangular` runs one exact captured target window per round, `serial` one ordinary target step per draft. Any other value fails the opt-in load. Ignored unless `DARKBLOOM_NEMOTRON_SUPER_MTP` is `1`. |
| `DARKBLOOM_NEMOTRON_SUPER_KV_BACKEND` | `paged` (surrounding spaces ignored) | `paged` | `provider-swift/Sources/ProviderCore/Inference/Engine/Factory/NemotronSuperLocalKVBackend.swift` (`resolve`) | Super attention KV storage, paged only: the eight attention layers' BF16 KV in the segmented native paged backend, charged by the engine's process-memory owner, with every request's decode-row workspace reserved for the owner's lifetime. `contiguous` is no longer supported and fails the load, as does any other value, before its LOAD claim and installation; so does `DARKBLOOM_CBV2_PAGED_KV` disabling paged KV. A paged construction failure fails the load, never falls back. Not forwarded to LaunchAgents. |
| `DARKBLOOM_NEMOTRON_SUPER_MAX_CONCURRENT` | integer `1`…`64`; `1`…`8` with `DARKBLOOM_NEMOTRON_SUPER_MTP=1` (surrounding spaces ignored) | `1` | `provider-swift/Sources/ProviderCore/Inference/Engine/Factory/NemotronSuperLocalAdmission.swift` (`concurrentRequests`); `provider-swift/Sources/ProviderCore/Inference/Engine/Factory/NemotronSuperLocalMTP.swift` (`validate`) | Requests the Super qualification hook's owner serves at once (the managed slot sets it from its slot policy, below); above one, text decode runs as one row-exact batched step, and with speculation one rectangular verify window covers every decoding request. Any other value, or a value above one with `DARKBLOOM_NEMOTRON_SUPER_MTP_VERIFICATION=serial`, fails the load. The KV grant must hold every request's fixed bytes. Not forwarded to LaunchAgents. |
| `DARKBLOOM_NEMOTRON_SUPER_VIDEO_PRUNING` | number in [0, 1) (surrounding spaces ignored) | `0.5` (`NemotronSuperVideoPreprocessing.defaultPruningRate`) | `provider-swift/Sources/ProviderCore/Inference/Vision/NemotronSuperVideoFeatures.swift` (`validatedPruningRate`) | EVS pruning rate `q` of Super video requests, in the managed slot and the qualification hook: a video of `T` tubelets of `N` visual rows keeps `max(N, int(T * N * (1 - q)))` rows; `0` keeps every row. Any other value fails the load before its LOAD claim and installation. A value below `0.5` keeps more rows, so a video's prompt has more tokens than the coordinator estimates for it, since that estimate assumes `0.5`. Not forwarded to LaunchAgents. |
| `DARKBLOOM_MTP_VERIFICATION_MODE` | `rectangular`, `serial`, `serial_target`, `automatic` | `automatic` | `provider-swift/Sources/ProviderBenchmark/MTPProductionSession.swift` | MTP verification strategy (benchmark session). |
| `DARKBLOOM_MTP_ACCEPTANCE` | `exact`, `typical`, `typical:<delta>` (finite positive delta) | `exact` | `provider-swift/Sources/ProviderBenchmark/MTPProductionSession.swift`; `provider-swift/Sources/ProviderCore/Inference/MTP/MTPAcceptancePolicy.swift` (`benchmarkOverride`) | MTP draft acceptance rule (benchmark session only). An unrecognized value uses `exact`. Serving reads no environment variable for this rule; it reads `[backend] mtp_acceptance` and `mtp_acceptance_by_model` in [`provider.toml`](../provider/cli-reference.md#providertoml-keys-read-by-the-cli). |
| `DARKBLOOM_PREFILL_DEADLINE_MODE` | `off`, `enforce` | `off` | `provider-swift/Sources/ProviderCore/Inference/Engine/PrefillDeadlineMode.swift` | Prefill-deadline admission on the provider. |
| `DARKBLOOM_GEMMA4_PREFILL_CHUNK_EVAL` | integer layers | projected from `provider.toml` (`18`) | `provider-swift/Sources/ProviderCore/Config/GemmaOptimizationEnvironment.swift` | Gemma-4 prefill chunk-eval layers; the provider sets it for the engine, `scripts/install.sh` sets `18` for the smoke test. |
| `DARKBLOOM_ENGINE_V2_VLM_PARITY_CHECK` | `0` skips | on | `provider-swift/Sources/ProviderCore/Inference/Vision/EngineV2VLMTextExtraction.swift` | VLM text-extraction parity check. |

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
| `DARKBLOOM_MLX_MEMORY_RESERVE_GB` | GiB | `provider.toml` `memory_reserve_gb` | `provider-swift/Sources/ProviderCore/Inference/Memory/MLXMemoryGuard.swift` | Overrides the whole-machine memory reserve. |
| `DARKBLOOM_MEM_CAP_FRACTION` | fraction | `0.90` | `provider-swift/Sources/ProviderCore/Inference/Memory/UnifiedMemoryCap.swift` | Share of unified memory the engine may address. |
| `DARKBLOOM_MEMORY_AVAILABILITY` | `reclaimable` / `free-only` | `reclaimable` | `provider-swift/Sources/ProviderCore/Inference/Memory/SystemMemory.swift` | Process-start policy shared by admission, KV budgets and diagnostics; persisted into the provider launchd plist on background start. `reclaimable` counts Mach free + inactive pages; `free-only` excludes inactive pages and fails closed if sampling fails. Unknown/empty explicit values select `free-only`. See [shared-host admission](https://github.com/Layr-Labs/darkbloom-platform/blob/48a198c71a2d30feec5597bacf1101120f7f955d/docs/architecture/scheduling.md#shared-host-memory-admission). |
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
| `MLX_QUANTIZED_CONSTANT_CACHE` | `0`, `false`, `no`, `off` disable | enabled | `libs/mlx-swift/Source/MLX/ConstantArrayCastCache.swift` (`ConstantArrayCastCache`): bounded reuse of unchanged BF16-to-FP32 constants; updates invalidate and transforms bypass reuse. |
| `MLX_GPTOSS_MXFP4_DECODE_FAST_TAIL` | `1` enables, other explicit values disable | enabled only on physical `applegpu_g16s` | `libs/mlx-swift/Source/Cmlx/mlx/mlx/backend/metal/quantized.cpp` (`gather_qmv`): width-2880 MXFP4 gathered matrix-vector path with a masked 320-element tail. Exact shape/dtype gates retain the general fallback. |
| `MLX_GPTOSS_MXFP4_PREFILL_TILE` | `m32n32k32`; other values use legacy | legacy | `libs/mlx-swift/Source/Cmlx/mlx/mlx/backend/metal/gptoss_mxfp4_policy.h` (`gptoss_mxfp4_prefill_tile`): optional 32-row tile for matching sorted expert prefill shapes. Small workstation gains do not establish a universal default. |
| `DARKBLOOM_GPTOSS_COMPILED_EXPERTS` | `1` enables | disabled | `libs/mlx-swift-lm/Libraries/MLXLLM/Models/GPTOSS+CompiledExperts.swift` (`GPTOSSCompiledExpertsPolicy`): compile single-token B=1/2/4 expert graphs for exact 20B shapes. The global `MLX_COMPILED_DECODE=0` rollback still disables this path. Batch-dependent timing is mixed; weights remain live through weak updatable state. |

## Experimental cluster configuration (staging)

`provider-swift/Sources/ProviderCore/Config/ClusterConfiguration{,Files,Paths}.swift`
holds the staged cluster configuration value types: one canonical device
namespace per user (`~/.config/darkbloom/clusters`,
`~/.darkbloom/cluster-device`), strict path/symlink rules, and closed
configuration validation. They carry saved expectations only — never a
grant, runtime approval or serving capacity. `darkbloom cluster configure`
(`provider-swift/Sources/darkbloom/ClusterCommand.swift`, `Cluster.Configure`)
validates and saves one without enabling or starting it. `darkbloom cluster`
saves this setup when you pick a model. The other Mac applies it, and the
service starts the processes. `cluster configure` and `start --cluster-member`
are developer tools. The processes that use the saved setup are
`darkbloom start --local --distributed` and `darkbloom start --cluster-member`
(`provider-swift/Sources/darkbloom/Start/StartCommand.swift`, `distributed`
and `clusterMember`); both are control-only and refuse solo serving options
when parsed. No environment variable selects one, so ordinary
solo serving is unchanged and the whole surface stays default-off.

### Experimental cluster pairs

The coordinator side of two-Mac cluster pairs, including the settings that
turn it on (`EIGENINFERENCE_CLUSTER_PAIR_CATALOG` and
`EIGENINFERENCE_CLUSTER_PAIR_TRUSTED_TLS_PROXIES`), is implemented and
documented in `Layr-Labs/darkbloom-platform`. With the catalog unset
there, no pair is ever formed and a member registration is only acknowledged.
What this repository shares with it is the approval entry below: a provider's
saved cluster setup carries the same entry, field for field (see
[coordinator-paired member](#coordinator-paired-member)).

The approval file has schema `darkbloom_cluster_pair_catalog_v1` and an
`approvals` list of at most 64 entries. Every field is required; unknown
fields, trailing data and out-of-bounds values are errors.

| Field | Type | Rule |
|---|---|---|
| `id` | string | 1–128 bytes, unique in the file |
| `model` | string | the exact catalog model ID the pair serves |
| `generation` | integer | positive policy generation |
| `plan_sha256`, `artifact_sha256`, `native_runtime_sha256`, `metallib_sha256`, `resource_library_sha256`, `capability_sha256`, `resource_policy_sha256`, `profile_sha256` | string | 64 lowercase hex, nonzero |
| `schedule` | integer | `1` or `2` |
| `maximum_plaintext`, `maximum_transport_frame` | integer | plaintext 1 to 16 MiB; frame at least plaintext + 40 |
| `maximum_records`, `maximum_cumulative_plaintext` | integer | 1 to 1,048,576 records; 1 byte to 4 GiB |
| `allowed_chips` | list of strings | 1–16 chip names, sorted by byte, unique. Each is compared byte for byte with a member's registered `hardware.chip_name` (for example `Apple M4 Max`), so it must be that exact string; only printable ASCII is accepted |
| `not_after` | RFC 3339 instant | approval expiry; a pair is formed only while a full session fits before it. The only accepted form is `YYYY-MM-DDTHH:MM:SS`, an optional fraction of one to nine digits, then `Z` or `±HH:MM`, naming an instant after 1970 that fits in 64-bit nanoseconds |

The file is read as strictly as the provider reads the same entry in its own
setup, so an entry one side accepts is never refused, or read differently, by
the other: field names must be spelled exactly and appear once (Go's usual
case-insensitive matching is not applied), and the `not_after` and
`allowed_chips` rules above are the provider's
(`ParseNativeRuntimeCatalog` in the coordinator;
`provider-swift/Sources/ProviderCore/Config/ClusterPairApproval.swift` here).
Three entries with fixed digests are pinned in both test suites
(the coordinator's catalog golden test and the provider's
`ClusterPairApprovalTests`), so neither encoder can change alone.

Each entry's canonical bytes are what a member compares with its installed
policy, and their SHA-256 is the `policy_sha256` it registers
(`NativeRuntimeCatalog.PolicySHA256`). Changing any field therefore produces a
different policy: members that installed the old one are no longer offered a
pair.

### Sharded placement and the hand-off opt-in

A cluster deployment shards the model across its members: tensor parallel
(every member holds a share of every layer) or pipeline (layers split at a
cut, with compact decode framing as a variant), chosen by the planner from
each Mac's detected profile, the measured link and the model's own
configuration (`ClusterPlacementPlanner`, `ClusterShardAssessment`). The guided
setup (`darkbloom cluster`) shows the chosen deployment in one line; the optional
diagnostic `darkbloom cluster plan` prints every sharded candidate with its
predicted speed and the reason it was or was not chosen. Tensor parallel is
chosen only where the runtime executes it for the model, a reduction over the
keyed data plane has been measured, no failed qualification covers the shape,
and it is predicted at least 5 % faster than every pipeline.

| Variable | Default | Effect |
|---|---|---|
| `DARKBLOOM_CLUSTER_HANDOFF_MODES` | unset (off) | `1` (or `on`) is the one explicit opt-in for the hand-off modes kept in the code: phase split, phase split + MTP, the pipeline-prefill/tensor-decode hybrid, and the per-request "alone" route. Read by the process that plans (`darkbloom cluster`, `darkbloom cluster plan`) and by each Mac's serving owner: a setup saved with a hand-off mode (for example by an earlier release, whose default was phase split + MTP) is refused at start without it, with the way back (`darkbloom cluster`, select the model again), and the alone route is taken only by a leader that has it. `0`, `off` or unset plan sharded deployments only; any other value is refused. Never offered in the onboarding. (`provider-swift/Sources/ProviderCore/Inference/Distributed/Placement/ClusterHandOffModes.swift`) |
| `DARKBLOOM_DEV_BENCH_PLANNER_CAP_GIB` | unset | Developer bench only, debug builds only (a release build refuses to plan while it is set): caps what the planner believes each Mac can give a model, in whole GiB, so a pair of large bench Macs is planned as smaller Macs would be. The load gates never see it. (`ClusterPlannerBenchCap.swift`) |

The developer plan tool takes `--hand-off-modes` for the same opt-in.

### Coordinator-paired member

To be offered a pair by the coordinator, each of the two Macs saves a setup
with an optional `nativeMember` object and runs `darkbloom start
--cluster-member`. Nothing else is needed on the provider side: the pair
selector matches the two registrations itself (see
[pair formation](cluster-control-protocol.md#pair-formation)).

1. The coordinator operator adds one entry to the approval file named by
   [`EIGENINFERENCE_CLUSTER_PAIR_CATALOG`](#experimental-cluster-pairs) and
   gives both Mac operators that same entry.
2. On each Mac, add `nativeMember` to the setup JSON and save it with
   `darkbloom cluster configure --input <setup.json> --capability <file>
   --capability-sha256 <hex>`. The two setups share `clusterID`; one has
   `role` `leader` (rank 0) and the other `follower` (rank 1).
3. On each Mac, run `darkbloom start --cluster-member` with a coordinator URL
   whose scheme is `wss`, signed in to the same account. Add `--always-on` to
   install it as the always-on service instead of running it in the
   foreground ([always-on members](../provider/cluster-always-on.md)).

| `nativeMember` field | Type | Rule |
|---|---|---|
| `schema` | string | exactly `darkbloom_cluster_native_member_v1` |
| `ownerSHA256` | string | 64 lowercase hex: SHA-256 of this Mac's `peers[local].ownerExecutable` |
| `metallibPath`, `resourceLibraryPath` | string | absolute shell-safe paths of the installed files whose digests the approval pins; distinct from each other and from the owner and worker executables |
| `approval` | object | the coordinator's approval entry, field for field ([fields](#experimental-cluster-pairs)); unknown or missing fields are refused |

The object is validated when the setup is saved and again whenever it is
loaded (`provider-swift/Sources/ProviderCore/Config/ClusterNativeMemberAttachment.swift`,
`validate`): the approval's `model`, `plan_sha256`, `artifact_sha256`,
`native_runtime_sha256`, `capability_sha256`, `profile_sha256` and `schedule`
must equal the saved setup's own model, selected Plan, capability pins and
prefill schedule (`1` serial, `2` one-chunk lookahead). The member derives the
canonical policy bytes from the entry exactly as the coordinator does
(`provider-swift/Sources/ProviderCore/Config/ClusterPairApproval.swift`,
`canonicalPolicy`, mirroring `darkbloom-platform:coordinator/registry/native_pair_approval.go`,
`canonicalNativeRuntimeApproval`) and registers their SHA-256 as
`cluster_membership.policy_sha256`. `not_after` must be a strict RFC 3339
instant (`YYYY-MM-DDTHH:MM:SS`, an optional fraction of one to nine digits,
then `Z` or `±HH:MM`); any other spelling is refused when the setup is saved.

At start (`provider-swift/Sources/ProviderCore/Inference/Distributed/Membership/ClusterMemberPreparation.swift`,
`nativeMemberInstallation`) the approval must be unexpired and list this Mac's
chip, and the owner, native executable, metallib and resource library must
hash to their pins; otherwise the command stops before registering. A member
whose setup has no `nativeMember` registers no membership and is never paired.

A setup with `nativeMember` cannot run `darkbloom start --local --distributed`
(`ClusterConfiguration.requireOrdinarySessionRoute`): that session launches
both owners itself over SSH and would contend with a coordinator-formed pair
for the same device. Save a setup without the object for a local session.

In this build a paired member declines the coordinator's preparation and no
pair serves a request; see [provider member
control](cluster-control-protocol.md#provider-member-control) for the reason
and for what the member answers.

### Guided link setup

`darkbloom cluster` (and `darkbloom cluster setup`) on a terminal runs the
onboarding: it pairs the Macs and offers a model. Run `darkbloom cluster` on
both Macs to pair them again. The line-by-line link setup described here runs
only with `--json`, `--yes`, `--temporary`, `--dry-run` or the hidden
`--link-only`
(`provider-swift/Sources/darkbloom/ClusterSetupCommand.swift`, `Cluster.Setup`);
with no terminal and none of those, `darkbloom cluster` prints one line: "Run
`darkbloom cluster` in a Terminal window on this Mac." The link setup
gets this Mac's link ready and keeps it ready. It prints one
line per step as each is observed, and the only thing it asks of the person is
approval in the macOS prompt. It runs the inspection, the change watch and the approval-gated fix
described in the next sections; its decisions and wording are one state machine
(`provider-swift/Sources/ProviderCore/Inference/Distributed/Diagnostics/Link/ClusterLinkSetupFlow.swift`,
`ClusterLinkSetupFlow`).

| Step | What must hold | When it does not |
|---|---|---|
| RDMA | RDMA is enabled and lists its devices | Prints the guidance for `rdmaDisabled`, `rdmaUnavailable` or `probeFailed` and stops |
| Connection | An RDMA port is active | Waits for a Thunderbolt 5 connection, polling as `cluster link --watch` does, until a port comes up or the wait is interrupted |
| Address | The active port publishes the IPv4-mapped GID, and an address Darkbloom assigned to it has its keeper | If the port only lacks an address: says what it is about to do, opens the macOS prompt, then installs and verifies exactly as `cluster link --fix` does, so the address is also put back whenever macOS removes it. A port that does not have the address Darkbloom has on record for it is named as such and repaired by the same one approval; when its keeper is installed and running the flow first waits `keeperWaitSeconds` (one keeper interval and 4 seconds) for the keeper to put the address back, without a prompt, and installs the keeper afresh only if it has not. A port that is ready on an address Darkbloom added but nothing keeps is reported as ready, and the same prompt installs only the keeper; a cancelled or unavailable prompt leaves the link ready. A cancelled prompt is reported with how to run the command again. More than one such port, or any other state, prints what to do and stops |
| Done | — | Prints that this Mac's link is ready and that the other Mac needs the same command. Pairing and model steps are not part of this flow |

The wait and the prompt happen on their own only when standard output is a
terminal and `--json` is not given (`ClusterLinkSetupFlow.mayPrompt`). Otherwise
the command prints what it found and the next step, and exits non-zero unless
the link is ready; `--yes` allows the wait and the prompt there too.
`--temporary` adds the address alone, as `cluster link --fix --temporary` does.
`--dry-run` waits for nothing and opens no prompt: where the flow would ask, it
prints the exact commands an approval would run, and exits 0. `--json`
prints one object at the end: `schema` is `darkbloom_cluster_setup_v1`, with
`ready`, `state` (the link state the flow last observed; `ready` after a
verified fix) and `narration`, the lines in order. The exit status is 0 when
the link is ready or a dry run printed its plan, the fix's own status (see [Link fix and
removal](#link-fix-and-removal)) when the fix ended any other way, and 1 for
every other stop, including an interrupted wait. A link that is ready on an
address nothing keeps still exits 0 when the keeper was not installed because
no prompt was allowed, the prompt was cancelled or it could not be shown; the
lines say what to run. If the keeper's installation was approved and then
failed, the exit status is the fix's own even though the link is still ready.

### Local link readiness

`darkbloom cluster link [--json]`
(`provider-swift/Sources/darkbloom/ClusterLinkCommand.swift`, `Cluster.Link`)
reads this Mac's own RDMA and network-interface state and reports whether
JACCL could initialise on it. Without `--fix` or `--remove` it reads no
provider configuration, changes no setting, contacts no peer and runs no
collective, and it exits non-zero unless the state is `ready`.
`darkbloom cluster doctor` runs the same inspection and appends its findings as
checks; `darkbloom cluster status` does not run it.

| Item | Value | Source |
|---|---|---|
| Tools run | `/usr/bin/rdma_ctl status`, `/usr/bin/ibv_devinfo`, `/sbin/ifconfig -a`, then `/usr/bin/ibv_devinfo -v -d <device>` for each device whose port is active; `--fix` also reads `/sbin/route -n get default`. Absolute paths, no shell, null standard input, environment limited to `PATH`, `LANG` and `LC_ALL` | `provider-swift/Sources/ProviderCore/Inference/Distributed/Diagnostics/Link/ClusterLinkToolCommand.swift` (`ClusterLinkToolCommand`); `provider-swift/Sources/ProviderCore/Inference/Distributed/Diagnostics/Link/ClusterLinkToolProcess.swift` (`ClusterLinkToolProcess.run`) |
| Time bounds | `childTimeoutNanoseconds = 3_000_000_000` per tool, `inspectionTimeoutNanoseconds = 10_000_000_000` for all of them, `reapTimeoutNanoseconds = 1_000_000_000` to await a killed tool | `provider-swift/Sources/ProviderCore/Inference/Distributed/Diagnostics/Link/ClusterLinkReadinessProbe.swift` (`ClusterLinkReadinessProbe`); `ClusterLinkToolProcess` |
| Size bounds | `maximumOutputBytes = 256 * 1024` per tool, `maximumDevices = 32` | `ClusterLinkReadinessProbe` |
| Report | `schema` is `darkbloom_cluster_link_readiness_v1`; `state`, `guidance`, one `devices` entry per RDMA device, and the constant `physicalProbePerformed: false`. Device and interface names only: no IP address, MAC address, GID, host name or serial number. An unknown fact is omitted rather than written as `null`. A device carries `assignedAddress` (`present` or `missing`) and `addressKept` (whether the address keeper is loaded with the job definition Darkbloom writes; omitted when that could not be read) only when the record of [link fixes](#link-fix-and-removal) names its interface; those two readings are `/bin/launchctl print system/<label>` and `/usr/bin/plutil -convert json -o - <file>` | `provider-swift/Sources/ProviderCore/Inference/Distributed/Diagnostics/Link/ClusterLinkReadinessReport.swift` (`ClusterLinkReadinessReport`); `provider-swift/Sources/ProviderCore/Inference/Distributed/Diagnostics/Link/ClusterLinkName.swift` (`ClusterLinkName`) |
| Doctor checks | `localLink` for the Mac; `localLinkDevice.<device>` for each active port and for the saved setup's port; `configuredLinkDevice` when the saved setup names a device this Mac does not list. A port that is not ready fails only where serving would use it. A ready port whose address nothing keeps passes, and its detail carries the guidance below. The doctor report sets `localLinkInspectionPerformed` and keeps `physicalProbePerformed` `false` | `provider-swift/Sources/ProviderCore/Inference/Distributed/Diagnostics/Link/ClusterLinkDiagnosticChecks.swift` (`diagnosticChecks`); `provider-swift/Sources/ProviderCore/Inference/Distributed/Diagnostics/ClusterDiagnosticsReport.swift` (`ClusterDiagnosticsReport`) |

`state`, and each device's `verdict`, is one value of
`ClusterLinkReadinessState`
(`provider-swift/Sources/ProviderCore/Inference/Distributed/Diagnostics/Link/ClusterLinkReadinessState.swift`).
Every state except `ready` carries one `guidance` sentence. For the two states
that only lack an address (`fixableByAddingAddress`) it offers
`darkbloom cluster link --fix`; for the others it names the change the operator
must make and says that Darkbloom will not make it. When the port that decides
the state has `assignedAddress: missing`, meaning the record holds an address
for it that the port does not carry now, the guidance says exactly that and
names the one command, `darkbloom cluster`
(`ClusterLinkReadinessReport.addressLostGuidance`). It does not say how the
address went missing: macOS removes one when it reconfigures the port, and an
earlier attempt that was approved elsewhere or failed part-way leaves the same
record. A `ready` state carries guidance in one case: the deciding port has
`assignedAddress: present` and `addressKept: false`, an address nothing would
put back, and the sentence names the same command
(`ClusterLinkReadinessReport.addressTemporaryGuidance`). The text summary then
prints that sentence before the scope line. The doctor's `localLink` and
`localLinkDevice.<device>` checks carry the same sentences.

| State | Meaning |
|---|---|
| `ready` | An active port publishes an IPv4-mapped GID, the condition JACCL checks before it uses a device. Local state only: it does not show that the peer is reachable |
| `rdmaDisabled` | `rdma_ctl status` printed `disabled`. RDMA is enabled from macOS Recovery with `rdma_ctl enable` |
| `rdmaUnavailable` | `rdma_ctl` or `ibv_devinfo` is missing or exited non-zero, as `ibv_devinfo` does when there is no RDMA device |
| `noActivePort` | No RDMA device has an active port |
| `portWithoutIPv4Address` | The active port's interface has no IPv4 address and is not a bridge member. `--fix` applies |
| `portBridgedWithoutAddress` | The active port's interface is a bridge member, such as the Thunderbolt Bridge, and has no IPv4 address of its own. `--fix` applies |
| `gidNotPublished` | No IPv4-mapped GID is listed although the interface has an IPv4 address, or the interface could not be identified |
| `probeFailed` | A tool timed out, exceeded its output bound or printed unrecognized text |

### Link fix and removal

`darkbloom cluster link --fix [--device <rdma device>] [--temporary] [--dry-run] [--json]`
gives the one active port that lacks an IPv4 address a link-local one, so that
it publishes the IPv4-mapped GID, and keeps it there.
`darkbloom cluster link --remove [--device <rdma device>] [--dry-run] [--json]`
undoes everything a fix installed and nothing else, including a keeper whose
record is gone. Nothing is changed without
a person approving the macOS authorization prompt: Darkbloom passes one fixed
command line to `/usr/bin/osascript` (`do shell script … with administrator
privileges`) and never uses `sudo` or sees a password.

An address added with `ifconfig` alone does not last. macOS removes it at a
restart, and on a Mac that shares its internet over the Thunderbolt Bridge it
was also seen removed, without sleep, restart or replug, at the moment another
network device was disconnected. A fix therefore installs an address keeper: a
root launchd job that runs every `intervalSeconds = 10` seconds and at start-up,
and adds the address back only when the port has no IPv4 address at all, so a
port that has any other address keeps just that one. It is
one file under `/Library/LaunchDaemons`; it runs `/sbin/ifconfig` and
`/usr/bin/grep` and installs no program. It leaves the bridge, its members,
Internet Sharing and every network service as they are. macOS lists it under
System Settings → General → Login Items & Extensions, where it can be switched
off; `--remove` deletes it. `--temporary` adds the address without the keeper.

The install writes nothing to launchd's own database of enabled and disabled
jobs, because a removal could not take such an entry out again. If the job was
switched off under Login Items & Extensions, macOS may refuse to start it and
the fix then ends as `commandFailed` or `appliedButNotReady`; switch it on
there and run `darkbloom cluster` again; the address itself is added before
the job is started, so the link is usable meanwhile. `--remove` works from the
record below and, for ports the record does not name, from the keepers it
finds installed: a file named as above whose content is exactly a job
definition Darkbloom writes names its port and address, so a keeper left
behind by a deleted `~/.darkbloom`, or installed from another account, is
still removed. Run `darkbloom cluster link --remove` before deleting
`~/.darkbloom`.

| Item | Value | Source |
|---|---|---|
| When `--fix` acts | Exactly one active port has verdict `portWithoutIPv4Address` or `portBridgedWithoutAddress`, or `--device` names such a port. A Mac that is already `ready` is left alone, with one exception unless `--temporary`: a ready port whose address is the recorded one and has no running keeper (`assignedAddress: present`, `addressKept: false`) gets the keeper, by the same commands. A ready port on any other address is never touched, and any other state stops before the prompt | `provider-swift/Sources/ProviderCore/Inference/Distributed/Diagnostics/Link/ClusterLinkRepair.swift` (`ClusterLinkFixPlan.make`) |
| Address keeper | Label `io.darkbloom.cluster-link.<interface>`, file `/Library/LaunchDaemons/io.darkbloom.cluster-link.<interface>.plist` (owner `root:wheel`, mode `644`), keys `Label`, `ProgramArguments`, `RunAtLoad` and `StartInterval`. Its program is `/bin/sh -c` with `/sbin/ifconfig <interface> \| /usr/bin/grep -qw inet \|\| /sbin/ifconfig <interface> inet <address> netmask 255.255.0.0 alias` | `provider-swift/Sources/ProviderCore/Inference/Distributed/Diagnostics/Link/ClusterLinkAddressKeeper.swift` (`ClusterLinkAddressKeeper`) |
| Commands approved for a fix | In order, joined with `&&`: `/bin/launchctl bootout system/<label>` (errors ignored), `/bin/rm -f <file>`, `/usr/bin/plutil -create xml1 <file>`, seven `/usr/bin/plutil -insert … <file>` commands that write the four keys, `/usr/sbin/chown root:wheel <file>`, `/bin/chmod 644 <file>`, `/bin/sh -c '<the keeper's script>'`, `/bin/launchctl bootstrap system <file>`. The script is run once before the job is started, so the address is there even where launchd refuses the job. The file is built key by key from fixed values; nothing a user could have prepared is copied into place. With `--temporary` the only command is `/sbin/ifconfig <interface> inet <address> netmask 255.255.0.0 alias` | `ClusterLinkAddressKeeper` (`installCommands`); `provider-swift/Sources/ProviderCore/Inference/Distributed/Diagnostics/Link/ClusterLinkPrivilegedRequest.swift` (`ClusterLinkPrivilegedRequest`) |
| Commands approved for a removal | For one port, only those whose target is found, in this order and joined with `;` so that each runs whatever an earlier one reported: `/bin/launchctl bootout system/<label>`, `/bin/rm -f <file>`, `/sbin/ifconfig <interface> inet <address> -alias`. The last is also included whenever the keeper is loaded, because the keeper may put the address back while the prompt is open. What is found afterwards decides the outcome, not the exit status | `ClusterLinkPrivilegedRequest` (`commands`); `provider-swift/Sources/ProviderCore/Inference/Distributed/Diagnostics/Link/ClusterLinkFixRemnants.swift` (`ClusterLinkFixRemnants.observed`) |
| What may enter a command | A validated interface name and a generated or recorded link-local address. `--device` is matched against the listed devices and never placed in a command | `provider-swift/Sources/ProviderCore/Inference/Distributed/Diagnostics/Link/ClusterLinkName.swift` (`ClusterLinkName`) |
| Address | `169.254.x.y` with both octets in 1–254, derived from a SHA-256 of this Mac's hardware UUID and the interface name, so the same port gets the same address each time and two Macs almost never choose the same one. A recorded address that differs from the derived one, as after a home directory copied from another Mac, is used only while something of it is still on this Mac. Apart from a dry run it appears only in the commands handed to macOS, in the keeper's file and in the record below; never in output, JSON or logs | `provider-swift/Sources/ProviderCore/Inference/Distributed/Diagnostics/Link/ClusterLinkLocalAddress.swift` (`derived`); `provider-swift/Sources/ProviderCore/Inference/Distributed/Diagnostics/Link/ClusterLinkMachineIdentity.swift` (`hardwareUUID`) |
| Verification | After the commands run, the port's device must be `ready` (up to `verificationAttempts = 10` probes one second apart), no bridge may have gained or lost a member, the default route must leave through the same interface as before, and, unless `--temporary`, the keeper must be loaded with exactly the job definition above | `ClusterLinkRepair` (`fix`, `unmetConditions`); `ClusterLinkAddressKeeper` (`isRunning`, `isDescribed`); `provider-swift/Sources/ProviderCore/Inference/Distributed/Diagnostics/Link/ClusterLinkTopology.swift` (`ClusterLinkTopology`) |
| Read-only tools | `/sbin/route -n get default`, `/bin/launchctl print system/<label>`, `/usr/bin/plutil -convert json -o - <file>` and `/bin/ls /Library/LaunchDaemons` (a keeper's file counts as present by its name, whatever it holds), beside those of the readiness inspection | `provider-swift/Sources/ProviderCore/Inference/Distributed/Diagnostics/Link/ClusterLinkToolCommand.swift` (`ClusterLinkToolCommand`) |
| Record | `~/.darkbloom/cluster-device/link-alias.json`, mode `0600`, schema `darkbloom_cluster_link_alias_v1`: the interface and address of each fix not yet removed. Written before the prompt, and again after an approved one, under the file lock and with the strict cluster file policy. After a cancelled prompt or a failed command an entry this fix created is dropped once the port is seen with nothing of the fix on it, and an entry from an earlier fix stays as it was; the entry is kept when no prompt could be shown, so that what is added with the printed commands can still be removed. `--remove` acts only on what the record names, or what an installed keeper's own job definition names, and only on what it finds: the port's address, the loaded keeper and the keeper's file. An entry with none of the three left is cleared without a prompt | `provider-swift/Sources/ProviderCore/Inference/Distributed/Diagnostics/Link/ClusterLinkAliasRecord.swift` (`ClusterLinkAliasStore`) |
| Dry run | `--dry-run` performs every read, decides exactly as a real run would, and stops where the prompt would open: no prompt, no record change, nothing run. It prints the commands, one per line, and they are the one place besides the manual commands below where the address is shown; with `--json` they are `plannedCommands` | `ClusterLinkRepair` (`fix`, `remove`) |
| Prompt wait | `promptTimeoutNanoseconds = 300_000_000_000` | `provider-swift/Sources/ProviderCore/Inference/Distributed/Diagnostics/Link/ClusterLinkApproval.swift` (`ClusterLinkApproval`) |
| Result | `schema` is `darkbloom_cluster_link_repair_v1`; `operation`, `outcome`, `message`, and where they apply `device`, `interface`, `state`, `unmet`, `candidates`, `durable` (whether the fix includes the keeper, or found it running) and `plannedCommands` (dry run only; `/` may appear escaped as `\/`, which is the same JSON string) | `provider-swift/Sources/ProviderCore/Inference/Distributed/Diagnostics/Link/ClusterLinkRepairOutcome.swift` (`ClusterLinkRepairResult`) |

`outcome` is one value of `ClusterLinkRepairOutcome`; the exit status is its
`exitCode`.

| Outcome | Exit status | Meaning |
|---|---|---|
| `dryRun` | 0 | `--dry-run`: the commands in `plannedCommands` would run after approval. Nothing was asked or changed |
| `alreadyReady` | 0 | `--fix`: the link, or the named device, is already ready and, unless `--temporary`, has no temporary address of Darkbloom's to keep. No prompt |
| `fixed` | 0 | `--fix`: approved, applied, and every verification condition holds |
| `removed` | 0 | `--remove`: nothing of the fix is left on the port |
| `alreadyAbsent` | 0 | `--remove`: nothing of the recorded fix was found. The spent record entry is cleared, except on a dry run. No prompt |
| `nothingRecorded` | 0 | `--remove`: no recorded fix and no installed keeper of Darkbloom's, or none for the named device. No prompt |
| `nothingFixable` | 1 | The state, given as `state`, is not one that adding an address cures; `probeFailed` here also covers a bridge, route, interface or keeper reading that could not be made before acting. No prompt |
| `ambiguousPorts` | 1 | More than one port qualifies; `candidates` lists them for `--device`. No prompt |
| `deviceNotListed` | 1 | `--device` names no RDMA device on this Mac. No prompt |
| `machineIdentityUnavailable` | 1 | The hardware UUID could not be read. No prompt |
| `recordUnavailable` | 1 | The record could not be read or written. No prompt |
| `approvalDeclined` | 2 | The prompt was cancelled: `osascript` reported error `-128` or `-60006` |
| `approvalUnavailable` | 3 | No prompt could be shown or answered, for example in an SSH session without a desktop: `osascript` failed in any other way or did not finish in time. The same commands, each under `sudo`, are printed on standard error |
| `commandFailed` | 4 | Approved, but one of the commands exited non-zero. After a failed keeper installation the message also names Login Items & Extensions. For a removal this is reported only when something of the fix is still found afterwards |
| `appliedButNotReady` | 4 | `--fix`: applied, but the conditions in `unmet` do not hold: `deviceNotReady`, `bridgeMembersChanged`, `defaultRouteChanged`, `stateUnreadable` or `addressKeeperNotRunning`. What was done stays until `--remove` |
| `removalNotVerified` | 4 | `--remove`: approved, but something of the fix is still found, or the port could not be read afterwards |
| `isolationRefused` | 1 | `--fix` (link setup v2): a finding in `findings` that the approval cannot cure is in the way, such as `internetSharingToPort`; the message says what the owner can do. No prompt |
| `appliedButNotIsolated` | 4 | `--fix` (link setup v2): approved, but the findings in `findings` still hold afterwards. What was done stays until `--remove` |

### Link setup v2: isolating the cluster port

Where the network around an active port can be read (always, on the command
line and in the console), `--fix` without `--temporary`, `darkbloom cluster`
and `--remove` use link setup v2 instead of the address keeper above. Design
and reasons: `handoff/DESIGN-link-setup-v2.md`. The end state for the active
port `P` on hardware port `H`: `P` is in no bridge, it has one network service
`Darkbloom Cluster Link (P)` with manual IPv4 `10.219.x.y/16` (the two octets
the link-local address above would use), no router, no DNS and link-local IPv6
only, other enabled services on `P` are switched off with their settings kept,
and the first version's keeper and alias are gone. macOS keeps that address
itself, also after a restart; no Darkbloom job runs. Internet Sharing is never
changed.

Each active port in `darkbloom cluster link --json` gains `isolation`:
`{"isolated": <bool>, "findings": [...]}`, names only. `darkbloom cluster
doctor` adds `localLinkIsolation.<device>`: `passed` when isolated, `failed` for
the port serving would use when not, `notObserved` for another active port.

| Finding | Read from | What the approval does |
|---|---|---|
| `portInBridge` | `/usr/bin/plutil -extract VirtualNetworkInterfaces.Bridge json -o - /Library/Preferences/SystemConfiguration/preferences.plist` | takes `P` out of that bridge |
| `internetSharingOverPortBridge` | `plutil -extract NAT.Enabled raw` and `NAT.SharingDevices json` of `/Library/Preferences/SystemConfiguration/com.apple.nat.plist` name `P`'s bridge | the same; sharing over the other members is left alone |
| `internetSharingToPort` | `NAT.SharingDevices` names `P` itself | blocks: turn `P` off under Internet Sharing in System Settings, or turn sharing off |
| `portInUnmanagedBridge` | `ifconfig -a` shows `P` in a bridge the preferences do not list | blocks: the same owner step |
| `defaultRouteViaPort` | `/usr/sbin/netstat -rn -f inet`: a `default` row through `P` | own service without a router |
| `dnsViaPort` | `/usr/sbin/scutil --dns`: a resolver with name servers through `P` | own service without DNS, IPv6 link-local only |
| `dhcpLeaseOnPort` | `/usr/sbin/ipconfig getpacket P` succeeds with a DHCP reply | own service with a fixed address |
| `portAddressMissing` | no `inet` on `P` | own service with a fixed address |
| `clusterServiceMissing`, `clusterServiceMisconfigured` | `/usr/sbin/networksetup -listnetworkserviceorder` and `-getinfo` (manual, recorded address, `255.255.0.0`, no router, IPv6 not `Automatic`) | the service is made, or made afresh |
| `otherServiceOnPort` | another enabled service on `P` | switched off |
| `clusterSubnetInUse` | another interface's address or route in `10.219/16` | blocks |
| `serviceNameUnsafe` | a service or hardware port name outside letters, digits, spaces and `( ) - . _` | blocks |
| `hardwarePortUnknown` | `networksetup -listallhardwareports` lists no port for `P` | blocks |
| `stateUnreadable` | a reading failed | blocks |

| Item | Value | Source |
|---|---|---|
| Commands approved for an isolation | Under `set -e`, in order, each only when needed: `/bin/launchctl bootout system/io.darkbloom.cluster-link.P` (errors ignored), `/bin/rm -f` its plist, `/sbin/ifconfig P inet <link-local address> -alias` (errors ignored); `/usr/libexec/PlistBuddy -c 'Print :VirtualNetworkInterfaces:Bridge:B:Interfaces:i' <preferences> \| /usr/bin/grep -qx P`, `PlistBuddy -c 'Delete …:i' <preferences>`, `/sbin/ifconfig B deletem P` (errors ignored); `networksetup -removenetworkservice` of an existing service of Darkbloom's; `networksetup -createnetworkservice 'Darkbloom Cluster Link (P)' 'H'`, `-setmanual … 10.219.x.y 255.255.0.0`, `-setdnsservers … Empty`, `-setv6LinkLocal …`; `-setnetworkserviceenabled '<service>' off` for each other enabled service on `P` | `provider-swift/Sources/ProviderCore/Inference/Distributed/Diagnostics/Link/ClusterLinkIsolationPlan.swift` (`ClusterLinkIsolationPlan`) |
| Commands approved for a restore | Joined with `;`, each only when needed: the first version's keeper as above, `PlistBuddy -c 'Add …:i string P' <preferences>` (position clamped to the bridge's length), `networksetup -removenetworkservice 'Darkbloom Cluster Link (P)'`, `-setnetworkserviceenabled '<service>' on` for each service the isolation switched off that is still off, `/sbin/ifconfig P inet 10.219.x.y -alias` for an address left without its service, `/sbin/ifconfig B addm P`. What is found afterwards decides `removed` | `ClusterLinkIsolationPlan.swift` (`ClusterLinkIsolationRestore`); `provider-swift/Sources/ProviderCore/Inference/Distributed/Diagnostics/Link/ClusterLinkIsolationRepair.swift` (`restoreNeeded`) |
| Verification | Up to `isolationVerificationAttempts = 15` readings one second apart: the device `ready` and no finding left | `ClusterLinkIsolationRepair.swift` (`isolate`) |
| Record | `~/.darkbloom/cluster-device/link-isolation.json`, mode `0600`, schema `darkbloom_cluster_link_isolation_v1`: per port the address, hardware port, bridge and position, and the services switched off. Written before the prompt; an entry a declined or failed first attempt created is dropped once nothing of it is found. A service named `Darkbloom Cluster Link (P)` without an entry is still removed, and nothing else is guessed | `provider-swift/Sources/ProviderCore/Inference/Distributed/Diagnostics/Link/ClusterLinkIsolationRecord.swift` (`ClusterLinkIsolationStore`) |
| Result | As above, plus `isolated: true` and, for the two outcomes of v2, `findings` | `ClusterLinkRepairOutcome.swift` (`ClusterLinkRepairResult`) |

Before a rank starts, `cluster worker-owner --stdio` waits up to
`waitSeconds = 20` for the saved setup's RDMA device to be `ready`, reading the
link once a second: RDMA off or missing refuses at once, a port without its
address or GID refuses after the wait with that state, and an unreadable link
or an unlisted device lets the launch go ahead after the wait
(`provider-swift/Sources/ProviderCore/Inference/Distributed/Diagnostics/Link/ClusterLinkLaunchReadiness.swift`,
`ClusterLinkLaunchReadiness`).

### Link watch

`darkbloom cluster link --watch [--json]` repeats the read-only inspection
every `pollIntervalSeconds = 2` seconds and prints one line per change until it
receives SIGINT or SIGTERM, then exits 0
(`provider-swift/Sources/darkbloom/ClusterLinkWatchLoop.swift`,
`ClusterLinkWatchLoop.printChanges`). With `--json` each change is one object on one
line, schema `darkbloom_cluster_link_watch_v1`
(`provider-swift/Sources/ProviderCore/Inference/Distributed/Diagnostics/Link/ClusterLinkWatch.swift`,
`ClusterLinkWatch.events`). It never prompts and never changes anything.

| Event | When | Fields besides `event`, `state` and `fixable` |
|---|---|---|
| `started` | The first poll | `guidance` when `--fix` applies to the state |
| `portUp` | A device's port became active, or an active device appeared | `device`, `interface`, `verdict` |
| `portDown` | A device's port stopped being active, or an active device left the listing | `device`, `interface`, and `verdict` while the device is still listed |
| `stateChanged` | The link state differs from the previous poll; emitted after that poll's port events | `previousState`, and `guidance` when `--fix` applies to the new state |

### Cluster console

The setup response check uses the model's default reasoning controls. It does not send a binary thinking override; if its token budget ends during reasoning, it reports that the model is still thinking. This is a liveness check, not an answer-quality benchmark. Source: `provider-swift/Sources/ProviderCore/Inference/Distributed/Console/ClusterSetupProbeRequest.swift` and `ClusterSetupWizardLiveOperations.prompt`.

`darkbloom cluster console [--json | --plain] [--dry-run] [--temporary] [--config <path>]`
(`provider-swift/Sources/darkbloom/ClusterConsoleCommand.swift`, `Cluster.Console`)
shows this Mac's link, saved setup, model and session on one screen and runs
the cluster commands from it (a hidden developer screen). Bare
`darkbloom cluster` and `darkbloom cluster setup` run the onboarding on any
terminal (it prints plain lines and reads keys through termios, so `TERM` does
not matter); `--wizard` opens the earlier six-step wizard on a terminal that
can draw it; `--json`, `--yes`, `--temporary`, `--dry-run` and `--link-only`
run the line-by-line [guided link setup](#guided-link-setup)
(`Cluster.Setup.entry`).

Everything shown is read when the screen opens, when `r` is pressed and after
each action. Between those, a probe is run again only where something is
being waited for (`provider-swift/Sources/ProviderCore/Inference/Distributed/Console/ClusterConsoleReducer.swift`,
`poll`): the link inspection every `pollIntervalSeconds = 2` seconds while the
link is not `ready`, and `cluster status` at the same interval while this Mac
leads a saved cluster or the screen started a session.

| Section | Read from | Source |
|---|---|---|
| Readiness | The link inspection, the guided setup's sentences for it, for a port Darkbloom has on record whether it carries its assigned address and whether the system job that keeps it is loaded, the worker binary's pin and whether it carries the progress guard, the device journal's state, and the checks of `cluster doctor`. One link inspection serves the link lines and the doctor | `provider-swift/Sources/ProviderCore/Inference/Distributed/Console/ClusterConsoleLiveOperations.swift` (`ClusterConsoleOperations.live`); `provider-swift/Sources/ProviderCore/Inference/Distributed/Console/ClusterConsoleLinkObservations.swift` (`ClusterConsoleLinkSetup`) |
| Pairing and trust | The saved setup's cluster, member and peer labels; the fingerprint of each key in its pinned known-hosts file, as a host key, a certificate authority or a revoked key, and how many further keys are not listed; whether that file still matches its pin; whether the identity file is owner-only. No host name, user name, address or path | `provider-swift/Sources/ProviderCore/Inference/Distributed/Console/ClusterConsoleSavedSetup.swift` (`ClusterConsolePairing`); `provider-swift/Sources/ProviderCore/Inference/Distributed/Console/ClusterConsoleHostKeys.swift` (`ClusterConsoleTrust.observe`) |
| Model | The models the cluster runtime in this build accepts a setup for, the saved model and Plan, the layers each rank owns, and the manifest's files by presence and size. Weight contents are not hashed here, and the chip and runtime requirements a start applies to the model are not evaluated here. Each rank's admission is shown from the leader's status once a session reports it, and as not observed until then | `libs/darkbloom-cluster/Sources/DarkbloomClusterProtocol/ClusterRuntimeAdmittedModels.swift` (`ClusterRuntimeAdapter.admittedModels`); `provider-swift/Sources/ProviderCore/Inference/Distributed/Console/ClusterConsoleInstalled.swift` (`ClusterConsoleInstalled.inspect`) |
| Session | The process the screen started, its output, and the leader's `GET /v1/cluster/status` report | `provider-swift/Sources/ProviderCore/Inference/Distributed/Console/ClusterConsoleSessionProcess.swift` (`ClusterConsoleSessionProcess`); `provider-swift/Sources/ProviderCore/Inference/Distributed/Console/ClusterConsoleContent.swift` (`liveSession`) |
| Not available in this build | What the screen cannot do, each with its reason | `provider-swift/Sources/ProviderCore/Inference/Distributed/Console/ClusterConsoleWiring.swift` (`ClusterConsoleWiring.unavailable`) |

Error text an operation worded is shown as worded, less anything in it that
names this Mac, its user or a peer
(`provider-swift/Sources/ProviderCore/Inference/Distributed/Console/ClusterConsoleSnapshotRedaction.swift`).

| Key | Action | Runs |
|---|---|---|
| `r` | Read everything again | The probes above |
| `f` | Fix link | `ClusterLinkRepair.fix`, as `cluster link --fix`: the address and the system job that keeps it, behind one macOS prompt. With `--temporary` the address alone; with `--dry-run` the same call's dry run, which lists the commands an approval would run and asks, records and changes nothing |
| `a`, then `y` | Approve the setup passed with `--input`, `--capability` and `--capability-sha256` | `ClusterConfigurationStore.configure`, as `cluster configure`, on a private copy of the two files, refused unless they are still the setup whose digest was on the screen (`provider-swift/Sources/ProviderCore/Inference/Distributed/Console/ClusterConsoleCandidateSetup.swift`, `ClusterConsoleReviewedSetup.hold`) |
| `s`, then `y` | Start the session; refused on a follower, without a saved setup, and beside a session that is already serving | `darkbloom start --local --distributed` as a child process in a session of its own, with default signal handling and none of the screen's descriptors, so closing the terminal window does not reach it (`provider-swift/Sources/ProviderCore/Inference/Distributed/Console/ClusterConsoleSessionProcess.swift`) |
| `x` | Stop the session this screen started | SIGINT to that child, once; nothing stronger is ever sent |
| `c`, then `y` | Recover | `ClusterDeviceRecovery.recover`, as `cluster recover` |
| `e` | Export diagnostics | `ClusterDiagnosticExport.write` into the current directory |
| `?` | Keys and the unavailable list with reasons | — |
| `q`, Ctrl-C | Close. With a session this screen started still running: asks, stops it and closes when it has ended. Then waits for an action in flight. A second `q` skips either wait and says on the restored terminal what is still finishing | — |

One action runs at a time; a result under Activity is the operation's own
summary or error text. While a session is serving, whether this screen started
it or another process did, `f`, `a` and `c` are refused with the reason: the
link, the saved setup and the journal are that session's. `f` and `a` are
refused as well while the device journal is not empty, which is what shows a
session on a follower. What stood in an action's way is checked again when its
question is answered. A session this screen started is asked to stop, with one
interrupt, on every way the screen ends, a signal, a closed terminal and an
error included; a second signal while the screen is still closing ends the
process after `forcedExitGraceMilliseconds = 2000`.

A question (`a`, `s`, `c`) is asked on one row, which fits an 80-column
window, and only in a window that shows every word of it; a narrower window
says how wide it must be. `y` answers a question only while the frame last
drawn shows it and has shown it for `questionDwellMilliseconds = 500`
(`ClusterConsoleState.drew`, `questionShownAt`), so a `y` typed or pasted
ahead of the question, or before it could be read, does nothing. Any other
key cancels. A
question about a setup is withdrawn when a later reading finds a different
setup, and any question is withdrawn when the window stops showing all of it.
Pasted text is read as one key that does nothing, and a paste whose end does
not arrive within `pasteMilliseconds = 1000` is given up on
(`provider-swift/Sources/ProviderCore/Inference/Distributed/Console/ClusterConsoleKey.swift`, `ClusterConsoleKeyDecoder`).

The one thing the screen starts by itself is the guided setup's address step,
as the link setup takes it in a terminal: when a reading finds a
port that only lacks an address, or whose address nothing keeps, the fix is
started once and macOS shows its approval prompt. Where the system job is
loaded and about to put a lost address back, the link is first read
`keeperReadings` more times (the setup's `keeperWaitSeconds` at the poll
interval). The step is the screen's only while it waits for a cable or for
that job: it is taken at most once, and is spent by any other reading, by a
fix asked for with `f`, and when a session or anything else stands in its way
(`provider-swift/Sources/ProviderCore/Inference/Distributed/Console/ClusterConsoleReducer.swift`,
`onboardingFix`).

With `--json` or `--plain`, or when standard input or output is not a
terminal, the command prints the same state and exits 0 without opening a
screen, waiting or asking. `--json` prints one object, schema
`darkbloom_cluster_console_v1`
(`ClusterConsoleSnapshot`): `observedAt`, `link` (the
[link report](#local-link-readiness)), `setup` (`lines`, `next`, `fixDevice`),
`diagnostics` (the doctor's report), `saved`, `candidate` and
`admittedModels`. A second screen for the same user is refused with status 1
while one is open (`provider-swift/Sources/ProviderCore/Inference/Distributed/Console/ClusterConsoleInstanceLock.swift`,
`ClusterConsoleInstanceLock`); the lock is an empty file in the user's
temporary directory, and opening a screen writes nothing under the home
directory.

The export is one owner-only file,
`darkbloom-cluster-diagnostics-<UTC time>.json`, schema
`darkbloom_cluster_diagnostic_export_v1`, holding the snapshot, the activity
list and the last `sessionOutputLines = 200` lines of session output. Each
text value is redacted before the document is written: network and hardware
addresses, host names, user names, serial numbers, keys, fingerprints,
credentials, long encoded values and whole paths under any home directory,
`~` or a volume are replaced by a placeholder in angle brackets such as
`<ipv4>`, `<host>` or `<home-path>`; digests of public files and schema names
are kept. Addresses are replaced before names, so a name cannot split one. A second, separately written
look then searches every value for what the first should have removed, and
the file is not written when it finds any. An existing file is never replaced
(`provider-swift/Sources/ProviderCore/Inference/Distributed/Console/ClusterDiagnosticExport.swift`,
`ClusterDiagnosticExport.render`; `provider-swift/Sources/ProviderCore/Inference/Distributed/Console/ClusterDiagnosticRedaction.swift`,
`ClusterDiagnosticRedaction`; `provider-swift/Sources/ProviderCore/Inference/Distributed/Console/ClusterDiagnosticResidue.swift`).

### Provider configuration file mode

Every provider save replaces `provider.toml` atomically and owner-only (mode
`0600`); a file an earlier release left group- or world-readable is tightened
by the next save, and a stricter existing mode is kept
(`provider-swift/Sources/ProviderCore/Config/ProviderConfigFile.swift`,
`ProviderConfigFile.replace`). The cluster readers refuse a `provider.toml`
that group or others can access
(`provider-swift/Sources/ProviderCore/Config/ClusterConfigurationInstalledReference.swift`,
`installedReference` and `optionalInstalledReference`), so until such a file is
saved again or its mode is corrected by hand, `darkbloom cluster status` and
`darkbloom cluster doctor` report the saved setup as `invalid`.

## Automatic cluster chunk policy

| Input / field | Meaning | Reader |
|---|---|---|
| Passing chunk preference | Uses matching-model/artifact passing records only when their prompt is at least their configured chunk; a preference is not proof of actual executed frame geometry or current-build speed | `ClusterPlacementRequestLimits.chunkTokens`, `provider-swift/Sources/ProviderCore/Inference/Distributed/Placement/ClusterPlacementRequestLimits.swift`; `ClusterPlacementFlow`, `provider-swift/Sources/ProviderCore/Inference/Distributed/Placement/ClusterPlacementFlow.swift` |
| No matching long-prompt measurement | Uses the smaller of the layout and worker capability chunk caps; the plan identifies the missing measurement. This fallback adds no serving grant | Same readers |
| Derived versus explicit request limits | Automatic descriptions derive limits; explicit diagnostic limits remain explicit. A changed worker identity triggers the existing replan/adoption path, retaining capability/build validation | `ClusterPairDescription.derivesRequestLimits`, `provider-swift/Sources/ProviderCore/Inference/Distributed/Placement/ClusterPlacementSetup.swift`; `ClusterService.checkForUpdate`, `provider-swift/Sources/ProviderCore/Inference/Distributed/Onboarding/ClusterService.swift` |

The registered GLM candidate's cap and resource qualification boundary live in
[inference](../architecture/inference.md#glm-cluster-prefill-bounds). Finite
calibration scope is listed with the
[CLI command](../provider/cli-reference.md#glm-automatic-finite-calibration-placement).
This policy adds no environment variable and does not rewrite qualification
records or enable private image/MTP profiles for public traffic.

## Automatic finite-placement inputs

| Input | Meaning | Reader |
|---|---|---|
| `glm-calibration-candidates --input` | Owner-only installed quotation template; `request.selection.cut` may be absent | `GLM5NextCalibrationPlacement.candidates` |
| `--planner-sha256` | Immutable identity of the installed plan helper | `GLM5NextCalibrationPlacement.candidates` |
| `--speed` (repeatable) | Existing keyed speed measurement; no missing rate is treated as a measurement | `ClusterSpeedEstimator.estimate` |
| `glm-calibration-run --placement` (exactly twice) | Same two rank snapshots on both Macs; 120-second maximum age | `ClusterGLMCalibrationPlacement.select` |

All other template fields, including artifact pins, environment, finite request, native/host allowances and expiry, remain unchanged and are validated by the existing quotation owner. No new environment variable, serving capability or public admitted cut is added. See [CLI usage](../provider/cli-reference.md#glm-automatic-finite-calibration-placement).

The cluster login agent derives `AssociatedBundleIdentifiers` from its actual
enclosing app's `CFBundleIdentifier` and matching `CFBundleExecutable` in
`Contents/Info.plist`; it is not a user setting. Unbundled executables do not
borrow an app identity. See
`provider-swift/Sources/ProviderCore/Service/ClusterServiceAgent.swift`
(`ClusterServiceAgent.job`) and [background cluster setup](../provider/cluster-always-on.md).
