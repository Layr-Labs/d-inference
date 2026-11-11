# Provider troubleshooting

> Last updated: 2026-11-11

Symptom → check → fix for the `darkbloom` provider: installer exits, `doctor`
check names, service lifecycle, coordinator connection, updates, models, the
KV-backend guard and uninstalling. For operators; every fix is a command you run on the Mac.

## Prerequisites

Start every session with the three read-only commands:

```bash
darkbloom doctor --strict      # ✓ / ⚠ / ✗ per check; exit 1 on any ⚠ or ✗
darkbloom status               # config, hardware, live daemon snapshot
darkbloom logs --last 1h       # unified logs, subsystem dev.darkbloom.provider
```

`doctor` (`provider-swift/Sources/darkbloom/DoctorCommand.swift`, `Doctor`) and
`status` read `~/.darkbloom/daemon-state.json`, which the daemon rewrites every
`max(1, heartbeat_interval_secs / 2)` s. A snapshot older than the stale
threshold is `STALE`; older than `max(8 × refresh period, stale threshold)` s
and `doctor` reports the daemon as wedged
(`provider-swift/Sources/darkbloom/Diagnostics/KVBackendPosture.swift`,
`wedgedAfterSeconds`). The heartbeat default and the stale threshold are in
[`cli-reference.md`](./cli-reference.md#runtime-constants).

## Installer exits

All messages come from `scripts/install.sh`; each exits 1 and, once the download
has started, leaves the previous install untouched.

| Message | Cause | Fix |
|---|---|---|
| `Error: Darkbloom requires macOS with Apple Silicon.` / `… requires Apple Silicon (arm64).` | `uname` ≠ `Darwin` or `uname -m` ≠ `arm64` (Rosetta shell included) | Run in a native `arm64` shell on an Apple Silicon Mac |
| `Could not reach coordinator at …` | `GET $COORD_URL/v1/releases/latest` failed | Check network/DNS; `curl -fsSL https://api.darkbloom.dev/v1/releases/latest`. From a checkout, set `COORD_URL` (the source keeps the `__DARKBLOOM_COORD_URL__` placeholder) |
| `Coordinator response missing required fields (url / bundle_hash / version).` | Release record incomplete | Coordinator-side release publishing problem; retry later |
| `Bundle hash mismatch — refusing to install possibly-tampered binary.` | Tarball SHA-256 ≠ `bundle_hash` | Re-run; a proxy or partial download is the usual cause |
| `Release bundle is missing required flat verifier files.` | No `bin/darkbloom`, `bin/darkbloom-enclave` or `bin/mlx.metallib` in the tarball | Bad release artifact; report it |
| `Binary hash mismatch …` / `Metallib hash mismatch …` / `App binary hash mismatch …` / `App releases require binary_hash and metallib_hash.` | Staged file ≠ published hash, or an app release without both hashes | Re-run; if it persists the release record and artifact disagree |
| `Release bundle has no Darkbloom.app; flat-only bundles are no longer installable.` | The tarball carries only the flat `bin/` files, as releases before the app bundle did | Install a current release; if `/v1/releases/latest` serves this artifact, report it |
| `Staged app predates the paged runtime; pre-paged releases are no longer installable.` | The staged `Darkbloom.app` has neither paged runtime code nor its capability marker: a pre-0.8 release artifact | Install the current release; if `/v1/releases/latest` serves this artifact, report it |
| `Staged Darkbloom.app does not satisfy the pinned signature requirement.` | `codesign --verify --deep --strict -R=…` failed against `identifier "io.darkbloom.provider"`, Team `SLDQ2GJ6TL` | Do not install; the artifact is not the signed release |
| `Fan-helper CLI capability, marker, and nested helper must be present together.` / `… marker is invalid.` / `Bundled fan helper must be a regular executable …` / `… must have mode 0755.` / `… does not satisfy the pinned helper signature requirement.` | Fan-helper capability triple inconsistent in the staged app | Bad artifact; report it |
| `Paged-capable staged app is missing its signed capability marker.` / `Staged app advertises paged capability without paged runtime code.` / `Paged runtime capability marker is invalid.` / `… requires exactly one sealed MLXLMCommon pagedattention.metal.` | Paged-kernel marker ⇔ binary ⇔ resource mismatch | Bad artifact; report it |
| `Packaged App Attest callback runtime smoke failed.` or missing callback marker | The staged callback runtime failed before Metal validation | Keep the existing installed app; retry with a fixed release and report the provider/macOS versions |
| `Packaged runtime smoke failed (App Attest, configuration, or Metal).` | One of the staged runtime checks failed | Run the staged app’s `runtime-smoke` to identify the last success marker; report its output and macOS version |
| `Atomic app swap failed; previous install was restored.` | `mv` into `~/.darkbloom` failed | Check free space and permissions on `~/.darkbloom` |
| `Secure Enclave ⚠ (not available on this hardware …)` (warning, install continues) | `darkbloom-enclave info` failed | Trust stays below `hardware`; see [attestation](./attestation.md) |
| `Enrollment ⚠ …` (warning) | Profile not installed, or `POST /v1/enroll` unreachable | `darkbloom enroll`, then install the profile in System Settings |
| `darkbloom: command not found` after install | Shell not reloaded; rc file is `~/.zshrc`, or `~/.bashrc` only if `~/.zshrc` is absent | `source ~/.zshrc`, or `export PATH="$HOME/.darkbloom/bin:$PATH"` |

## Doctor checks

`darkbloom doctor` prints an operator diagnosis (sections local API,
attestation key, App Attest, attestation readiness, trust, model fit, runtime,
billing, version; `provider-swift/Sources/darkbloom/Diagnostics/DoctorRunner.swift`,
`buildOperatorDiagnosis`, and `DoctorLocalAPI`) followed by `DETAILED CHECKS`
(`provider-swift/Sources/darkbloom/DoctorCommand.swift`, `buildDoctorChecks`,
`buildCoordinatorDoctorChecks`). Check names are stable identifiers:

| Check | What it tests | When it is not ✓ |
|---|---|---|
| `mode`, `darkbloom network` | How this Mac serves (Only me, Darkbloom network or Both, me first), first in the report; with Only me (also while it loads its models), the account, trust, App Attest and coordinator checks are skipped as not needed (`provider-swift/Sources/darkbloom/Diagnostics/DoctorLocalAPI.swift`) | Informational. Not chosen yet: `darkbloom start` asks; `darkbloom start --choose` changes it (`darkbloom cluster` on a pair; `darkbloom start --solo --choose` on a paired Mac serving alone) |
| `address`, `key file` | The local API answers `GET /health` on its port, and a key file holds its key; the key is never printed | Follow the printed fix: `darkbloom restart` (a stopped background service, which starts as saved) or `darkbloom start` (none installed), the free port it names (port in use). For a port that doesn't answer, or no file holding the key, the command that starts the API again as it serves now: Ctrl-C, then `darkbloom start --local --here` for Only me in a terminal; `darkbloom restart` for the background service serving your saved choice; `darkbloom start` with the flag of the way it serves otherwise ([every case](./cli-reference.md#the-local-api-section)). On a pair's Mac whose own port can't pass the pair's API on now, `status`'s words: with the other Mac away, wait, or `darkbloom stop`, then `darkbloom start --solo` |
| `OpenCode`, `Hermes` | Darkbloom's provider in the tool's config points at this Mac's local API and its key file | `darkbloom --opencode` or `--hermes` points it here again; a config Darkbloom can't read says why |
| `hardware`, `metal gpu`, `macos` | Chip/RAM detection, Metal device, OS version | Apple Silicon with a working GPU is required; nothing to configure |
| `config` | `provider.toml` parses | Fix the TOML at `~/.config/darkbloom/provider.toml`; retired keys only warn |
| `huggingface cache`, `local mlx models` | `~/.cache/huggingface/hub` exists and holds serveable models | `darkbloom models download <id>` |
| `sip`, `authenticated root`, `hardened runtime`, `debugger`, `binary hash`, `rdma` | Boot security and process integrity the coordinator scores | `csrutil enable` from Recovery; detach debuggers; reinstall if the binary hash is unknown. Effects on trust: [attestation](./attestation.md) |
| `account link` | `~/.darkbloom/auth_token` present and accepted | `darkbloom login` |
| `mdm enrollment`, `mdm verification` | Profile installed; coordinator has cross-checked `SecurityInfo` | `darkbloom enroll`; the steps and what to expect: [Reaching and keeping `hardware` trust](./attestation.md#steps) |
| `console session`, `automatic login`, `auto-logout on idle`, `sleep prevention` | Attestation readiness (`provider-swift/Sources/ProviderCore/Diagnostics/AttestationReadiness.swift`) | A real console user must be logged in; enable automatic login; disable auto-logout; the daemon self-caffeinates while serving |
| `active se key` | Secure Enclave signing key self-test | `darkbloom-enclave info`; hardware without SE runs at reduced trust |
| `launch session`, `app attest support`, `apple operation`, `app attest key` | macOS 27+ only: the daemon's last local App Attest observation (`provider-swift/Sources/ProviderCore/Diagnostics/AppAttestLocalDiagnosis.swift`) — GUI session, `is_supported_false`, a stalled DeviceCheck call, stored/enrolled key and local generation safeguard | The coordinator may retry after the displayed local countdown expires. Run the provider inside the logged-in GUI session (`darkbloom restart` after logging in) and keep SIP and Full Security. For `is_supported_false` in the GUI session, typically after a self-update, re-register the app with the `lsregister -f` command that `doctor` prints instead of restarting; a stall clears when the provider restarts ([attestation](./attestation.md#app-attest-without-darkbloom-mdm)); never delete the Keychain item |
| `gui session` | macOS 27+: the provider runs outside the GUI session. Either a user is logged in at the console but the provider was launched elsewhere (SSH, system daemon), or nobody is logged in (`AppAttestDeepDiagnosis.swift`) | Run `darkbloom restart` from the logged-in desktop (Terminal or Screen Sharing). If nobody is logged in, log in and enable automatic login |
| `boot security` | SIP or authenticated root is not confirmed enabled. Apple requires Full Security for App Attest | In Recovery: `csrutil enable`, `csrutil authenticated-root enable`, Startup Security Utility → Full Security, restart |
| `app signing` | A known missing opt-in, invalid environment entitlement, or missing/expired profile fails. Unavailable signing data or unknown expiry warns instead of passing; an explicitly absent environment entitlement can be legitimate | Reinstall a known-bad release (`curl -fsSL https://api.darkbloom.dev/install.sh \| bash`), then restart; for indeterminate evidence, collect a report |
| `process start` | Why this provider process started (launchd, watchdog, update, stall restart, manual) and whether the previous one shut down cleanly (`provider-run.json`) | Unclean exits come from a crash, force-kill, power loss or a reboot without a drain. If App Attest broke right after one, run `darkbloom report` |
| `key history`, `last apple failure` | Key generation attempts in 24 h, key age and boot, last Apple success, consecutive assertion failures, and the last native error chain. CryptoTokenKit `-3` with an `aks` code means the Secure Enclave refused to sign. Doctor distinguishes a latest error eligible for coordinator dead-key checks from timeouts or `serverUnavailable`; the aggregate failure count alone cannot establish a dead key or promise rotation | The coordinator decides whether replacement is due. For repeated generation attempts with a recorded `invalidKey` attestation failure, run `darkbloom report` from an administrator account (or `sudo darkbloom report` if this account can use sudo); see the [limits of local key-history evidence](./attestation.md#app-attest-without-darkbloom-mdm) |
| `apns pushes` | APNs code-identity pushes received and answered in 24 h, and whether APNs registration produced a device token (`apns-push-history.json`) | No token: APNs registration failed, so stay in the GUI session and restart. None received while the coordinator says it pushed: an APNs delivery problem, so keep the Mac awake and online. Received but unanswered: `darkbloom restart` |
| `devicecheckd log` | Device-wide system App Attest patterns, potentially from other apps; they cannot be attributed to Darkbloom or establish this provider's key failure. Administrator log access is required | Use an explicit administrator-run report for supporting context; do not infer provider key loss or rotate a key from these observations alone |
| `coordinator health`, `minimum version`, `coordinator trust` | Coordinator reachable, this version is accepted, trust verdict with reasons | `darkbloom update`; reasons are explained in [attestation](./attestation.md) |
| `trust level` stuck at `self_signed` | The MDM `SecurityInfo` cross-check has not passed for this connection | `darkbloom enroll` if not enrolled; otherwise wait — see [Reaching and keeping `hardware` trust](./attestation.md#troubleshooting) |
| `daemon`, `daemon connected`, `daemon state freshness` | Daemon process alive, WebSocket connected, snapshot refreshed | See [service lifecycle](#the-service-does-not-stay-running); a stale snapshot ⇒ `darkbloom restart` |
| `coordinator traffic` | Whether the coordinator can route work to this connection: connected, a coordinator verdict received, and an App Attest lease, legacy authorization or a request routed since the latest status. ✗ names the cause from current evidence only: disconnected, no verdict minutes after connecting, an `untrusted` or `offline` status, an expired lease, or a refusal received in the last minute with the coordinator's reason. ℹ `unconfirmed`: the last refusal is older than that, so it does not show an exclusion; the current coordinator sends no status when legacy verification authorizes a connection after its registration refusal. Skipped while an add-on holds the connected Mac on purpose: `darkbloom status` prints `Not serving: held by add-on …` and `darkbloom addon` shows the hold (`provider-swift/Sources/ProviderCore/Diagnostics/ServingReadiness.swift`) | Follow the printed fix. A locked login keychain, a stalled Apple call or a provider started outside the logged-in GUI session clears after logging in at the console or `darkbloom restart`; `app_attest_identity_required` needs `darkbloom login`; macOS 26 needs macOS 27 unless the Mac is in the legacy MDM cohort. `unconfirmed` prints no fix: its reason is the coordinator's last, which may no longer apply. See [connected but no traffic](#coordinator-connection) |
| `recent model load` | Last model-load error recorded by the daemon | See [models and memory](#models-and-memory) |
| `kv backend posture`, `kv backend crash-loop guard` | Explicit `engine_v2_kv_backend` request honoured; guard record present | See [KV-backend guard](#kv-backend-crash-loop-guard) |
| `competing inference` | Another inference server holds the GPU (`provider-swift/Sources/darkbloom/Diagnostics/CompetingInferenceDiagnostics.swift`) | Quit it; it competes for the same unified memory and GPU time |
| `glm wired limit` | Shown only when GLM-5.3-Flash is downloaded, selected or served on a 256 GB M5 Mac: the GPU wired-memory limit (`iogpu.wired_limit_mb`, or Metal's working set while it is `0`) and both user wire limits against the production values (`provider-swift/Sources/darkbloom/Diagnostics/GLMWiredLimitAdvice.swift`) | ⚠ only; follow [GLM-5.3-Flash GPU wired-memory limit](#glm-53-flash-gpu-wired-memory-limit) |
| `usage reporting` | Requests completed since the daemon started whose usage chunk was missing (`usageGaps > 0`); the pass line counts this daemon's completions, not paid jobs | Transient after reconnects; persistent gaps ⇒ `darkbloom report` |
| `up to date` | `SelfUpdater.checkForUpdate`; also reports a quarantined release | See [updates](#updates) |

`darkbloom verify` runs the same set, except the doctor-only `glm wired limit`,
and exits 1 on any ⚠.

The process-table, local-port and sleep probes have a five-second execution
deadline, followed by bounded child termination. Large output is captured in
a temporary file, which is removed after the probe. A failed contention probe
adds no hints; a failed sleep probe reports unavailable. These bounds apply
to `LocalContentionSnapshot.runCapture` and `DoctorRunner.systemSleepPrevented`
in `provider-swift/Sources/darkbloom/Diagnostics/CompetingInferenceDiagnostics.swift`
and `provider-swift/Sources/darkbloom/Diagnostics/DoctorRunner.swift`, using
`provider-swift/Sources/ProviderCore/Process/BoundedProcess.swift`
(`runCapturingStandardOutput`).

## `darkbloom start` fails

| Message | Cause | Fix |
|---|---|---|
| `--local and --local-endpoint are mutually exclusive …` | Both flags given | Pick one: `--local` for Only me, `--me-first` for Both, me first ([the local API](./direct-mode.md)) |
| `A debugger is attached. The coordinator will reject this provider.` | `checkDebuggerAttached()` | Detach the debugger |
| `This Mac has N GB RAM. At least 8 GB is needed to serve any model.` | `Start.runPreflightChecks` (`provider-swift/Sources/darkbloom/Start/StartCommand+Preflight.swift`) | Use a larger machine ([hardware requirements](./hardware-requirements.md)) |
| `Cannot start: …` | `Start.prepareServeRuntime` — `GPUEnforcement.requireMetal` failed, or the Gemma runtime environment could not be applied (`GemmaOptimizationEnvironment.apply`) | Confirm a Metal GPU (`system_profiler SPDisplaysDataType`); retry |
| `Cannot start: hardware detection failed …` | `sysctl`/`system_profiler` failed | Retry; report the output of `sysctl machdep.cpu.brand_string hw.memsize` |
| `No models selected.` | Picker cancelled or `--model` ids not local | `darkbloom models list`; `darkbloom models download <id>` |
| ``Without a terminal, `darkbloom start` can't ask which models to serve: …`` (exit 64) | A script, an agent or a start with its input redirected named no models for Darkbloom network or Both, me first; no start asks a question without a terminal | Add `--model <id>` (`darkbloom models list`) or `--all`, or run `darkbloom start` in a terminal to pick |
| ``No model to serve yet. See them: `darkbloom models catalog`. …`` (Only me) | No model on this Mac that Only me can serve (every local model's family lacks a CBv2 adapter, or none is downloaded) | Pick one in `darkbloom start`'s list, which downloads it, or `darkbloom models download <id>` (gpt-oss, gemma-4 families) |
| ``This Mac's local API couldn't listen on <addr>:<port>: another program may use port <port>. …`` (Only me) | Another program holds this Mac's local API port | Stop the other program, or run the `darkbloom start --port <n>` it names: the new port is saved, and tools set up for the old one need `darkbloom --opencode` or `--hermes` again |
| ``Serving: Darkbloom and you, me first — the local API isn't up: port <port> is in use (…)`` (`status`; `local` says `The local API isn't up: …`) | Both, me first serves Darkbloom, but another program holds the local API's port (`DaemonState.localAPIFailure`) | As above; after freeing the port, `darkbloom restart` |
| `Cannot start --local-endpoint: failed to create the local API token …` | `~/.darkbloom` not writable | Fix permissions, or `--no-auth` on a trusted network |
| `warning: … RETIRED knob and is IGNORED` | A retired `[backend]` key or env var is set | Remove it; see [beta features](./beta-features.md#retired) |

## The service does not stay running

```bash
launchctl print gui/$(id -u)/io.darkbloom.provider | head   # loaded? last exit status?
launchctl print gui/$(id -u)/io.darkbloom.watchdog | head
tail -50 ~/.darkbloom/provider.log ~/.darkbloom/watchdog.log
```

| Symptom | Cause | Fix |
|---|---|---|
| Service gone after `darkbloom stop` and a reboot | `stop` disables the label; auto-start returns only with `darkbloom start` (`provider-swift/Sources/darkbloom/StopCommand.swift`) | `darkbloom start` |
| Daemon exits and nobody restarts it | The provider plist has `KeepAlive = false`; restarts are the watchdog's job, armed only when `provider.auto_restart = true` | Set `auto_restart = true`; `darkbloom restart` re-arms it (`provider-swift/Sources/darkbloom/RestartCommand.swift`) |
| Models unload after a while, daemon stays up | `backend.idle_timeout_mins` elapsed (default in the [`provider.toml` table](./cli-reference.md#providertoml-keys-read-by-the-cli)); reload is lazy on the next request (`provider-swift/Sources/ProviderCore/ProviderLoop+IdleTimeout.swift`) | Expected. `idle_timeout_mins = 0` disables unloading |
| Provider offline after logout / at the login window | GUI LaunchAgents run only inside a logged-in session | Enable automatic login; see `console session` above |
| Daemon restarts every few minutes, then `kv backend crash-loop guard` appears | `crashLoopTripThreshold` restarts inside the watchdog window (`provider-swift/Sources/ProviderCore/Service/WatchdogDecision.swift`; value in [runtime constants](./cli-reference.md#runtime-constants)) | See [KV-backend guard](#kv-backend-crash-loop-guard) |
| `watchdog.log` says `warning: v<version> restarted <n> times before its promotion` | Something restarts the provider more often than every 10 minutes, so the new release is never promoted (`WatchdogRecoveryService.observeHealthyProvider`) | Find what restarts it (a script, a cron job or a login item: `crontab -l`, `launchctl list`, the login items in System Settings) and stop it, or make it restart less often ([`darkbloom update`](./cli-reference.md#darkbloom-update)) |
| `darkbloom restart` prints `Provider is not running. Start it with darkbloom start.` | Plist not installed | `darkbloom start` |
| `stop`, `restart` or `start` says `Drain did not complete: 0 unfinished request(s), coordinator acknowledgement false`, or `The drained provider is still shutting down` | On a provider without the bounded drain: the coordinator connection was down (nothing could acknowledge the drain), or a model's native retirement never finished at shutdown. Current providers finish both: a drain without a session needs no acknowledgement, and shutdown waits 15 seconds per unload (`ProviderLoop.performLifecycleDrain`, `ProviderLoop.unloadAllModelsForShutdown`) | On such a provider, `--force`; it interrupts only unfinished work, of which there is none in the first case |
| Console shows the provider offline while `darkbloom status` prints `Daemon: running` and a `Not serving:` line | A `stop`, `restart`, `start` or `update` drain timed out, was interrupted (Ctrl+C), or drained without a relaunch. The old process stays alive and refuses new work (`provider-swift/Sources/darkbloom/StatusCommand+LifecycleDrain.swift`, `Status.lifecycleDrainLine`); the command also turned automatic restart off (`provider-swift/Sources/darkbloom/ServiceDrain.swift`, `ServiceDrain.prepare`) | `darkbloom restart` to serve again or `darkbloom stop` to stay stopped, each with a new drain deadline; add `--force` to interrupt unfinished work |

## Coordinator connection

| Symptom | Mechanism | Fix |
|---|---|---|
| `daemon connected` ⚠, console shows offline | The client reconnects with an exponential backoff (`CoordinatorReconnectPolicy`, `provider-swift/Sources/ProviderCore/Coordinator/CoordinatorReconnectPolicy.swift`; bounds in [runtime constants](./cli-reference.md#runtime-constants)) | `curl -v https://api.darkbloom.dev/health`; check DNS, clock, TLS interception, firewall on 443 |
| Log: `WebSocket pong timeout (no response in 30s)` | No pong within `pongTimeout` of a `pingInterval` ping closes the socket and the backoff restarts it ([runtime constants](./cli-reference.md#runtime-constants)) | Network path stalls; nothing to configure on the provider |
| An error-level `coordinator` log line every 30.0 s that `log show` prints as `<private>` (providers before 0.10.10) | The coordinator measures each connection's round trip with a WebSocket ping every 30 s that carries a counter (`"1"`, `"2"`, …). Network.framework answers it, then hands the ping up with its payload; the receive loop skipped only empty control frames, so the codec logged `Failed to parse coordinator message`. Serving is unaffected. 0.10.10 skips every ping and pong (`CoordinatorClient.inboundFrame`, `provider-swift/Sources/ProviderCore/Coordinator/CoordinatorClient+Connection.swift`) | Update; nothing else to do |
| Heartbeats arrive but requests do not ("no traffic until restart") | A heartbeat every `heartbeat_interval_secs` proves the connection, not routability. The coordinator routes only a connection it authorizes (an App Attest lease or legacy verification) | `darkbloom status` → `Traffic:` and `darkbloom doctor` → `coordinator traffic` name the cause and fix. The provider re-registers a connection while that verdict stays `NOT receiving` for 15–30 minutes, then after 30 minutes, 1 hour, 2 hours and every 4 hours, only while it is idle: no accepted or local requests, model loads, Autopilot operation, drain or update (`provider-swift/Sources/ProviderCore/Coordinator/UnauthorizedConnectionRecovery.swift`, `provider-swift/Sources/ProviderCore/ProviderLoop+ServingAuthorizationRecovery.swift`). A refusal counts only while the coordinator keeps repeating it, so a refusal sent once at registration never triggers a re-registration. `darkbloom logs` records when the coordinator starts refusing the connection, when it authorizes it, and when its refusal is no longer current. The routing gates are listed in [`../architecture/security/attestation.md#routing-gate`](../architecture/security/attestation.md#routing-gate) |
| `minimum version` ✗ | Coordinator rejects this `ProviderCore.version` | `darkbloom update` |
| `Requests served` in `status` is higher than the jobs in the console's Earnings | The status count covers only the time since the daemon started (the `… ago` on the line) and includes free [self-route](./self-route.md) requests to your own machine and requests that ended early after this Mac had sent output. `status` lists those by what stopped them and whether the coordinator pays: the work done is paid when the requester left mid-answer or this Mac stopped the request itself, and nothing is paid when another Mac answered first, this Mac started too late or the connection to the network dropped (`Requests served` under `darkbloom status` in the [CLI reference](./cli-reference.md)). Earnings lists only paid jobs (`provider-swift/Sources/darkbloom/StatusCommand+ServedRequests.swift`) | Compare Earnings over the same period; the machine card's Tokens/reqs add the status counters up across restarts |

## Updates

| Symptom | Cause | Fix |
|---|---|---|
| `Latest release vX is quarantined on this machine.` | vX crashed `rollbackThreshold` times before surviving `defaultStabilizationSeconds`, or was rolled back with `darkbloom update --rollback` (`provider-swift/Sources/ProviderCore/Update/UpdateRecoveryState.swift`; values in [runtime constants](./cli-reference.md#runtime-constants)) | Wait for the next release (it installs normally), or `darkbloom update --override-quarantine` |
| A new release runs but regresses | Automatic updates install every newer release | `darkbloom update --rollback` restores the previous release and quarantines this one; leave automatic updates on ([roll back](./installation.md#roll-back-to-the-previous-release)) |
| `vX is already installed on disk but this process is vY.` | Update landed, daemon not restarted | `darkbloom restart` |
| `Couldn't check for updates: <host> didn't answer within 15 s (3 tries).` | The release check (`GET /v1/releases/latest`) got no answer three times, or `couldn't reach <host>`: its connection was lost or refused, or the name didn't resolve (`ReleaseCheck`, `provider-swift/Sources/ProviderCore/Update/SelfUpdater.swift`; the bound per try, tries and pauses in [runtime constants](./cli-reference.md#runtime-constants)). Nothing was downloaded or changed | Run the command again in a minute. If it keeps failing, check this Mac's network: `curl -sS -o /dev/null -w '%{http_code} %{time_total}\n' "https://api.darkbloom.dev/v1/releases/latest?platform=macos-arm64"` should print `200` within a second. If `curl` answers while `darkbloom` doesn't, the two took different paths: read the `release check: try …` lines above the message (or in `~/.darkbloom/provider.log`, `cluster-setup/service.log`, `watchdog.log`), which give each try's HTTP version, whether it went through a proxy and the address it reached; run `scutil --proxy`; and read `log show --last 30m --info --predicate 'process == "darkbloom" AND subsystem == "com.apple.network"'` |
| `Couldn't check for updates: <host> answered HTTP 500 instead of the latest release.`, `… isn't a release …`, `… is for another platform …` | The coordinator answered, but not with a release this Mac can use. The second line says the network works | Run the command again later. Nothing on this Mac needs to change; if it keeps failing, the release service has a problem |
| `Couldn't check for updates: this Mac's update record can't be read (<path>): …` or `… the coordinator URL isn't a valid URL` | This Mac didn't get as far as asking: the record the updater keeps in `recovery/state.json`, or the coordinator URL in `provider.toml` or `--coordinator` | Fix what the line names, then run the command again |
| `SHA-256 hash mismatch!` | Download ≠ `bundle_hash`/`binary_hash`/`metallib_hash` | Retry; persistent mismatch means the release record and artifact disagree |
| `another update/recovery operation is active` | Watchdog recovery or a previous update holds the lock | Wait a minute; retry |
| No automatic updates | `provider.auto_update = false`, or `DARKBLOOM_NO_UPDATE_CHECK` set in a `--foreground` shell | `darkbloom autoupdate status`, `darkbloom autoupdate enable` |
| Fan control stops after an update | The unprivileged updater does not replace the root helper | `sudo darkbloom fan enable` ([fan control](./fan-control.md)) |

The check cadence (`autoUpdateInitialDelay`, `autoUpdateInterval`), the
`update_jitter_seconds` install delay and the `updateDrainTimeout` before the
restart (`provider-swift/Sources/ProviderCore/ProviderLoop+AutoUpdate.swift`)
are tabulated in [`cli-reference.md`](./cli-reference.md#runtime-constants).

## Two-Mac pairs

| Symptom | Cause | Fix |
|---|---|---|
| The part log (`~/.darkbloom/cluster-setup/rank.log`) repeats `This Mac cannot register the saved roster: This Mac's Secure Enclave key is not the one it paired with; pair again.` | The pairing was made with another Secure Enclave key: the Mac moved between a local build and the signed release, or the official installer made a new key. The DevNet app keeps its own pairing, so pairing it never causes this in the production app | Run `darkbloom cluster` on each Mac and choose **Pair again** ([pairing again](./two-mac-cluster.md#pairing-again)) |
| `darkbloom cluster` says "The other Mac (…) isn't answering over the cable" | Its cluster service is off (`darkbloom cluster stop --service` turns it off; plain `darkbloom stop` leaves it running), or that Mac is asleep, off, or waiting for someone to log in (with FileVault on, after a restart its cluster service starts only once someone logs in) | On that Mac, log in if it asks and run `darkbloom start` or `darkbloom cluster`, then choose **Try again** here. Silence is not a broken pairing: use **Start over** only if that Mac was reinstalled, unpaired or replaced. If it left the pair (`darkbloom cluster leave`), choose **Start over** to pair again, or **Quit** and run `darkbloom cluster leave` here too |
| Both Macs wait at "2/4 Pair" and neither finds the other; after about 25 s the screen says "The other Mac isn't found yet" | macOS's firewall on one Mac drops the discovery probe (stealth mode, or Darkbloom not allowed yet), or the other Mac isn't on this screen | Allow Darkbloom in System Settings → Network → Firewall on both Macs and run `darkbloom cluster` on both. Or pair directly: press q, run `darkbloom cluster pair --listen` on one Mac (it prints its cable address), then `darkbloom cluster pair --connect <that address>` on the other, and `darkbloom cluster` on both again |
| One Mac waits at "2/4 Pair"; the other shows its status and ends, or says "The other Mac (…) isn't answering over the cable" | The second Mac still holds an earlier pairing, so it never joins the waiting Mac | On the second Mac run `darkbloom cluster`, choose **Start over** and answer **Yes, start over** |
| "3/4 Model" (or "Model", "Change model", "Start") stays on "Reading both Macs over the cable" | The other Mac stopped answering; the screen says why each time the reason changes, and after 2 minutes offers **Try again**, **Start over** and **Quit** | Run `darkbloom cluster` on the other Mac first, then **Try again**; **Start over** only if it was reinstalled, unpaired or replaced |
| You want to set the pair up from scratch (after `darkbloom cluster link --remove`, an uninstall or a move to other Macs) | The pairing and the cluster setup stay on each Mac until removed | Run `darkbloom cluster` and choose **Start over**, then answer **Yes, start over**; on the other Mac choose **Start over** (or **Pair again**) if it offers it |

## Models and memory

| Symptom | Cause | Fix |
|---|---|---|
| `model fits in RAM` FAIL / `Cold load blocked (memory)` in status | The live no-eviction load budget is below the scanner's complete model estimate plus activation and minimum-KV serving reserve, and request-time idle eviction cannot close the gap. The nominal `Inference memory` hardware figure is not live free RAM. Status and doctor show both the preload gap and the smaller eviction-aware cold-load gap ([load gate](../architecture/hardware-support.md#load-gate-modelloadadmission)). A busy machine with an active request gets a temporary verdict instead | Free at least the **cold-load** shortfall with margin, rerun `darkbloom doctor`, then `darkbloom restart` to retry preload when enabled; or select a smaller model ([hardware requirements](./hardware-requirements.md)). A request cannot cold-load at the same memory level. |
| `Preload skipped (no eviction)` in status | The model does not fit alongside the current resident slots. The request-time allowance can fit it by evicting idle models; startup preload deliberately avoids that churn | Keep the current serving set, or free memory if both models should stay resident. A selected model the startup preload skipped is retried automatically (next row). |
| `Retrying <model> when memory frees; next check in …` in status | This explicitly selected model (`enabled_models`, `preload_models`, the pinned `model` or Autopilot's selection) is cold because of memory, not your choice: the startup preload left it out for memory or a slot, or an Autopilot operation unloaded it to load another model. The daemon rechecks it (30 s backing off to 10 minutes, at once after an unload) and loads it when it fits, unloading first only idle models outside your selection that no request could load back, with no Autopilot hold, pin or lease, and that meet Autopilot's own minimum dwell and idle time ([selected-model recovery](../architecture/hardware-support.md#load-gate-modelloadadmission)). `Last check:` names what kept it out | Nothing, if `Last check` names a request in flight, a hold, a lease, a minimum dwell or an idle wait: it loads after them. If it says no model outside the selection can be evicted, your selected models or another process hold the memory; it loads when that frees or on request. If it says a model stays in the running daemon's selection, `darkbloom restart` applies your saved `enabled_models`. If it says `next check after an unload or a configuration change`, the model loaded three times and each time left too little memory to serve (`Last check` names the refusal). Unload a model, select fewer or smaller models (a saved `enabled_models` or Autopilot change makes it due again) or run `darkbloom restart`; memory freed outside the daemon, such as by quitting an app, does not make it due by itself. |
| `Configuration change needs a restart to apply: enabled_models …` in status | The saved `enabled_models` differs from the filter the running selection applies (the one the daemon started with, or the one the last `darkbloom switch` saved); a running daemon applies an edited filter only at a start | `darkbloom restart`. |
| A load refusal says `Not evictable: <model> (… GB: …)`, or status says `Not evictable for a load now: …` | That resident model cannot be evicted for the load: an Autopilot placement hold (until the UTC time shown), requests in flight, a local request, an Autopilot pin, an unload or an MTP upgrade in progress. `adopted by Autopilot outside the selected models` means an Autopilot operation placed it there, not your selection ([placements](../architecture/model-autopilot.md#placements-after-an-operation)) | Wait for the hold to expire or the requests to finish, then retry the load; a hold also ends when an operation unloads the model or Autopilot is disabled. |
| `Serving outside the enabled model filter: <model>` in status | The running daemon serves a model your saved `enabled_models` omits: an Autopilot operation adopted it, it is in the running daemon's selection (a hand-edited filter applies only at the next start), or a live Autopilot lease published it. A coordinator command or model rollout never adds one ([operator filter](../reference/configuration.md#provider-model-selection)); on provider 0.10.6 or earlier, see the next row | For an adoption see `darkbloom autopilot status`; otherwise `darkbloom restart` applies the saved filter. |
| Provider 0.10.6 or earlier: a build you deselected with `darkbloom switch` or deleted with `darkbloom models remove` comes back within minutes, downloads again and replaces the build you selected (for example `gemma-4-26b-qat-4bit` replacing `gemma-4-26b`); status shows `Serving outside the enabled model filter: <build>` | The coordinator moved a public model you serve to `<build>`, and these providers follow that rollout even when `enabled_models` omits it. It reaches every Mac that serves any build of that public model, including its rollback build (`gemma-4-26b-8bit`) | Update the provider. Until then, serve the newest build (pick the public model's name in `darkbloom switch`) or select no build of that public model; a restart, a new login or selecting the rollback build does not stop it. |
| The log says `desired_models: <model> → <build> is outside the enabled model filter; not converging` | A public model you serve moved to a newer build that your `enabled_models` does not list. The provider keeps serving your build. The coordinator now sends the public model's requests to the newer build first, so your build gets them only when no Mac with the newer build has room | To keep your build, nothing. To take the new build, run `darkbloom switch` and pick the public model's name (the picker shows its newest build under that name and downloads it), with your other models. |
| Model missing from `darkbloom models list` | Not in `~/.cache/huggingface/hub`, or filtered by `enabled_models` | `darkbloom models download <id>`; `darkbloom models list --all` |
| Load fails after a catalog update | New build published for the alias | `darkbloom models remove <id>` then `darkbloom models download <id>` |
| `Skipping <id>: model_type … has no engine-v2 adapter` | Family not served by CBv2 | Use a supported family; the model is never advertised |
| Slow decode, GPU busy | `competing inference` ⚠ | Quit the other server |
| GLM-5.3-Flash requests or loads fail and the log mentions Metal `Insufficient Memory` | The macOS GPU wired-memory limit is below what GLM plans at full KV | [GLM-5.3-Flash GPU wired-memory limit](#glm-53-flash-gpu-wired-memory-limit) |
| Failed jobs on the console's Jobs card; `darkbloom logs` shows `Inference failure: invalid request (…)` lines | Each line is one request the provider refused before running it; the reason names the request shape ([refusal lines](./cli-reference.md#refusal-lines)). Request text is never logged | Nothing to change on the Mac. The client must change the request; a model that refuses the shape refuses it on every provider |

## GLM-5.3-Flash GPU wired-memory limit

The [requirement and values](./hardware-requirements.md) apply to a 256 GB M5
Mac serving GLM-5.3-Flash. The commands need an administrator; the provider
never runs `sudo` itself.

1. Run `darkbloom doctor`. A `glm wired limit` ⚠ prints the current limits and
   these commands.
2. Apply the limits until the next reboot:

   ```bash
   sudo sysctl -w iogpu.wired_limit_mb=245760 vm.global_user_wire_limit=261134011596 vm.user_wire_limit=261134011596
   ```

3. Restart the provider so MLX reads the new limit: `darkbloom restart`.
4. To reapply them at every boot, paste the LaunchDaemon block that `doctor`
   prints after its detailed checks. It writes
   `/Library/LaunchDaemons/com.layrlabs.glm53-wired-limits.plist`, which runs
   `/usr/sbin/sysctl -w` with the three values at load, and bootstraps it with
   `sudo launchctl bootstrap system /Library/LaunchDaemons/com.layrlabs.glm53-wired-limits.plist`.

Verify: `sysctl iogpu.wired_limit_mb vm.global_user_wire_limit vm.user_wire_limit`
prints the three values, and `darkbloom doctor` shows `glm wired limit` ✓ with
them. To roll back, run
`sudo launchctl bootout system/com.layrlabs.glm53-wired-limits`, delete the
plist and reboot.

## KV-backend crash-loop guard

The watchdog writes `~/.darkbloom/kv-backend-guard.json` after
`crashLoopTripThreshold` restarts ([runtime constants](./cli-reference.md#runtime-constants));
while it matches the running version it changes automatic backend selection,
and `doctor` shows `kv backend crash-loop guard`
(`provider-swift/Sources/ProviderCore/Service/KVBackendGuard.swift`;
`provider-swift/Sources/darkbloom/Diagnostics/KVBackendGuardDiagnostics.swift`).
The resulting fallback or refusal depends on live precision; see the
[backend posture and recovery reference](./cli-reference.md#darkbloom-doctor-1).

```bash
darkbloom doctor                        # read the guard record and the posture per slot
darkbloom doctor --clear-backend-guard  # delete the record, reset the crash-loop counter
darkbloom restart
```

A new binary version clears a stale record on start. Clearing the guard restores
normal selection on the next model load. It does not bypass live precision,
operator settings or loaded-model capability checks, and does not guarantee
paged service or qualify a runtime.
The [Qwen-first rollout](https://github.com/Layr-Labs/d-inference/blob/4230fa03ddbc84e34e2de150c89431744d6f1c55/docs/design/qwen-first-paged-ssd-rollout.md)
is historical qualification evidence, not the current selection policy.

`kv backend posture` ✗ means an explicit backend request was refused or the
served backend differs from the request. Read the reported reason. For explicit
contiguous recovery, first resolve live precision to `native`, then select
`contiguous`; account for per-model and environment overrides using the
[precision settings](./cli-reference.md#providertoml-keys-read-by-the-cli).
The [backend posture reference](./cli-reference.md#darkbloom-doctor-1) defines
the effects of explicit selection, capability vetoes and the paged kill switch.

Paging rollback alone does not disable eligible Qwen SSD reuse on contiguous.
SSD caching remains enabled by default with no resident retention; use
`DARKBLOOM_PREFIX_CACHE=0` to disable local reuse independently
([prefix-cache defaults](../architecture/prefix-cache.md#invariants)).

## A two-Mac cluster says "Not serving yet"

`darkbloom cluster` says Serving only once both Macs loaded the model and a
request answered. Otherwise its line names why
([two-Mac cluster](two-mac-cluster.md#the-steps-once)):

| Line | What to do |
|---|---|
| `… isn't logged in to Darkbloom, so the coordinator won't pair it` | `darkbloom login` on the Mac named, then **Retry**; or `darkbloom cluster local` (Only me). |
| `<Mac> isn't verified by Apple yet; Darkbloom retries by itself at about <time>` | The coordinator pairs only members with a current App Attest authorization. It is said once a Mac's part has run 2 minutes without one, or its key-generation safeguard holds it back; before that, `checking both Macs with Apple` is a new part's usual first minute. Leave both Macs running and don't restart either until that time (that Mac's local key-generation safeguard; `darkbloom doctor` shows it on the "app attest key" line), then **Retry**; or **Serve locally only** (Only me). |
| `<Mac> lacks free memory for its share` | Quit apps on that Mac, then **Retry**; or **Change model**. |
| `A part keeps ending the same way: …` | **Diagnostics** saves a redacted file in the home folder to send with a report. |

## Everyday commands on a Mac in a two-Mac cluster

On a paired Mac `darkbloom stop`, `start`, `restart` and `status` control the pair;
`--solo` manages single-Mac serving on this Mac
([CLI reference](cli-reference.md#darkbloom-cluster-status)).

| Symptom | Cause | Fix |
|---|---|---|
| `darkbloom stop` says `stopping both Macs` on a Mac in a cluster | On a paired Mac `stop` controls the pair, as on one Mac it controls single-Mac serving (`Stop.pairedStop`) | Expected: both Macs stop and stay stopped; `darkbloom start` on either Mac starts the pair again. `darkbloom stop --solo` stops single-Mac serving only |
| `darkbloom start` opens the cluster's screen, or in a script ends with `✗ Not serving: …` | On a paired Mac `start` starts the pair whatever its state, also after `darkbloom stop` (`Start.pairStart`); a script gets `darkbloom cluster status`'s exit status. Its first line says what it does: in a terminal, how the screen starts a stopped pair (``Press Enter to start it with <model> (last used), or choose another model.``) or `opening the pair's screen`; in a script, `starting the pair`, or `the pair already serves`, which keeps it as it is | Follow the result block's `Next:` line. `darkbloom start --solo` serves this Mac alone |
| `darkbloom start --model <id>` in a terminal, or `darkbloom autopilot enable`, says ``This Mac is in a two-Mac cluster with the other Mac (…): `--model` is for single-Mac serving, so nothing was started.`` (exit 64) | On a paired Mac single-Mac options need `--solo`, in every state of the pair; nothing was started or stopped | To start the pair: `darkbloom start`. To serve this Mac alone: `darkbloom start --solo --model <id>` (stop the pair first while it runs) |
| The app's **Start serving** on a paired Mac started the pair, and says ``This Mac serves in a pair: the pair serves <model>; `darkbloom cluster` changes its model.`` (or, not serving yet, ``This Mac is in a pair: the pair was asked to start with <model>, and isn't serving (above); …``), maybe with ``No local API was added on this Mac: …`` (only where the pair gives this Mac no local API: Darkbloom only, or its API kept on the leading Mac), or, on the other Mac while its relay can't answer, `status`'s `Local API:` line | The app has no `--solo`, so on a paired Mac its Start starts the pair, with the pair's own model and its own local API, never this Mac alone | Expected. To change the pair's model: `darkbloom cluster` on the leading Mac. To serve this Mac alone: `darkbloom stop`, then `darkbloom start --solo --model <id>` in a terminal |
| The app's Autopilot (onboarding's **Start serving with Autopilot**, or a model refresh) says ``This Mac is in a pair …; Autopilot isn't available for pairs yet. Use Start serving.`` (or ``This Mac serves in a pair; …`` while it serves) | Autopilot chooses the models of one Mac; on a paired Mac it is refused before anything downloads, and the app offers **Start serving** instead | Use **Start serving**: it starts the pair with its model. To change the pair's model: `darkbloom cluster` on the leading Mac |
| Is the pair serving? Why not? | `darkbloom cluster` needs a terminal | `darkbloom cluster status` (or `--json`; exit 0 only while it serves) |
| `This Mac's pairing record couldn't be read (…), so it may be in a two-Mac cluster.` (`cluster status` exit 7) | The pairing store can't be read (a damaged or unsafe file); the commands treat the Mac as maybe in a cluster, so `start`, `stop` and `restart` need `--solo` (`ClusterPairSummary.membership`) | `darkbloom cluster` on this Mac checks the pairing |
| `darkbloom cluster link --remove` asks `Remove it? [y/N]` | The Mac is paired; removing the port setup stops the cluster on both Macs until it is set up again | Answer `n` unless the cable port must go; never remove it because of a doctor line alone. `--yes` for scripts |
| `darkbloom stop` on the Mac that follows says the other Mac didn't answer, and `Nothing was stopped on this Mac.` | The leading Mac stops both Macs, and it isn't answering (`ClusterPairCommands.stop`) | Wake or log in to the leading Mac and run it again, or `darkbloom cluster stop --local-only` to stop this Mac alone |

## Missing base reward

`doctor` billing is local usage reporting, not a coordinator
`model=base_reward` grant. If last-1000 earnings show no `base_reward` rows
(or amounts that match a smaller RAM class) while `doctor` is green, follow
[Check a missing base reward](base-rewards.md).

## Uninstall and start over

| Symptom | Cause | Fix |
|---|---|---|
| After `darkbloom stop --uninstall`, the cluster setup, pairing and settings are still there | `stop --uninstall` removes only the provider, watchdog and desktop API agents and keeps every file | `darkbloom uninstall`: choose **Remove everything**, or **Keep models** to reuse the models after a reinstall ([installation](./installation.md#uninstall)) |
| You want to start from scratch | Saved settings, the pairing and the cluster setup bring the old setup back | `darkbloom uninstall --keep-models` (or `--everything`), then install again: settings, pairing and cable setup start fresh and the kept models are found. Deleting `~/.darkbloom` by hand leaves the cluster service, the pairing on the other Mac and the cable port setup behind |
| `Usage: darkbloom uninstall --everything\|--keep-models [--yes] [--dry-run [--json]] (no terminal to ask which)` | No terminal to ask in (an agent or a script), and no mode with `--yes` | Pass `--everything` or `--keep-models` with `--yes`; check first with `--dry-run` |
| `failed   Stop serving on this Mac: …` | The provider did not finish its accepted requests in time, or cannot drain | Run it again with a longer `--timeout`, or `--force` to interrupt them. Its services are kept until it stops |
| `skipped  Delete …: a Darkbloom service may still be running` | A step that stops a service failed (it is listed above) | Fix that step, then run `darkbloom uninstall` again with the same choice; every step is idempotent |
| `skipped  Revoke this Mac's account token: …` | No saved token, the coordinator was not reached, or it could not confirm the token | Nothing to do: the token file is deleted with `~/.darkbloom` |
| After **Keep models** and a reinstall, models in a folder you chose are not listed | That location was saved in the deleted `provider.toml` | `darkbloom models location <folder>` |
| `failed   Undo the cable port setup: …` | The macOS prompt was declined, or could not show (no screen, over SSH) | `~/.darkbloom` and the `darkbloom` command stay for this. Run `darkbloom uninstall` again at the Mac's screen with the same choice; without a screen, run the printed `sudo sh …` line as an administrator, then run it again |
| `Run \`darkbloom uninstall\` as yourself, not with sudo: …` (exit 64) | It was run with `sudo`. As root it would read root's home folder, not yours | Run `darkbloom uninstall` without `sudo`; macOS asks for the password when the cable port step needs it |
| `skipped  Delete …: not removed: …`, and the first line says Darkbloom is not fully removed (exit 1) | The path is a link, resolves outside Darkbloom's folders, or another disk is mounted at it or inside it | Nothing outside Darkbloom's folders is deleted. Remove it yourself if you don't need it, or eject the disk and run `darkbloom uninstall` again |
| `Darkbloom is not fully removed from this Mac: its app folder is your models folder, so it was kept (see below).` (exit 1) | `darkbloom models location ~/.darkbloom` made the app folder your models folder, and a folder you chose is never deleted | Move the models you want to keep out of `~/.darkbloom`, then run `~/.darkbloom/bin/darkbloom uninstall` again: the settings naming that folder are gone, so it deletes the rest |
| `~/.darkbloom` is still there after the uninstall, holding your models | You chose a models folder inside it (`darkbloom models location ~/.darkbloom/models`); a folder you chose is never deleted, and the summary lists it as `Kept:` | Move the folder, or delete it yourself if you don't need the models |
| ``The production Darkbloom on this Mac holds this Mac's GPU for its pair (or a model check) …``, ``The production Darkbloom on this Mac holds this Mac's GPU: it is serving (process <N>) …`` (or ``… its pair is set to serve here …``, or ``… its cluster service's status can't be read (…) …``) or ``Darkbloom Dev on this Mac holds this Mac's GPU …``, in the status or the cluster service log, while this pair waits (in DevNet's log also ``… This Mac's part stops and waits for it.``) | Both apps take one device lock (`~/Library/Application Support/io.darkbloom.cluster/native-device.lock`), and the other app's pair or its GLM model check holds it now. A DevNet build also waits while the production app serves on this Mac (even a version from before the lock) or its pair is set to serve here, or while production's status (`~/.darkbloom/cluster-setup/service-status.json`) was written in the last two minutes but can't be read. Its running pair stops at once when production starts serving: production wins | Nothing to repair: the pair starts by itself as soon as the other app's pair stops, and the wait never counts as a failing pair. Production serves on this Mac: don't stop it from DevNet; its owner decides. To start production's pair now, stop the DevNet pair with `darkbloom-dev cluster stop` |
| A DevNet provider serving on one Mac logs ``The production Darkbloom on this Mac holds this Mac's GPU: … no model of this build loads here until production stops serving`` and its requests go to other providers | The production app serves on this Mac (its own process, or its pair), and two models don't fit one Mac's memory: production wins | Nothing to repair: the DevNet provider loads its model again once production stops serving here. A model it loaded before production started stays loaded |
| After uninstalling Darkbloom Dev (or the production Darkbloom), the cable port setup is still there | The other install on this Mac may use the same cable, so the summary lists it as `Kept: this Mac's cable port setup` | Run the other install's uninstall too (`darkbloom uninstall` or `darkbloom-dev uninstall`) to undo it |
| `failed   Stop this Mac's cluster part and remove its service: another program holds this Mac's cluster service lock (pid …)` (exit 1, nothing deleted; one install only) | The program holding the lock is not a `darkbloom cluster service`, so `cluster stop --service` does not stop it | Stop that program (`ps -p <pid>` shows it), then run `darkbloom uninstall` again |
| `failed   Check that no cluster service of this install still runs: …` (exit 1, nothing deleted) | A cluster service started from a session (a development build, or a Mac where launchd did not take its agent) still holds this Mac's cluster lock, or one the uninstall can't tell apart does | `darkbloom cluster stop --service`, then run `darkbloom uninstall` again |
| The other Mac still shows the pair | Each Mac keeps its own pairing | Run `darkbloom uninstall` on it too, or `darkbloom cluster` on it to pair it with another Mac |

Steps, paths and safety rules: [`darkbloom uninstall`](./cli-reference.md#darkbloom-uninstall).

## Collect a report

```bash
darkbloom doctor --support > doctor.txt
darkbloom status > status.txt
darkbloom report --last 24h --dry-run   # review exactly what would be sent
darkbloom report --last 24h             # upload; prints report_id
```

`Report` (`provider-swift/Sources/darkbloom/ReportCommand.swift`) collects
subsystem `dev.darkbloom.provider` at info level with macOS privacy redaction
intact, uploads only when you run it, and prints the `report_id` to quote to
support. It appends the provider's closed App Attest snapshot, APNs push history
and device-wide `devicecheckd` pattern matches; see
[`cli-reference.md`](./cli-reference.md#darkbloom-report) for scope and fields.
macOS lets only administrator accounts read the system log. Run the report from
an administrator account, or run `sudo darkbloom report` if this account is
allowed to use sudo. Otherwise only the App Attest snapshot is sent, without
provider logs or `devicecheckd` evidence.

## Related

- [CLI reference](./cli-reference.md) — flags, paths, runtime constants.
- [Installation](./installation.md) · [Quickstart](./quickstart.md).
- [Attestation](./attestation.md) — trust levels, enrollment, challenge cadence.
- [Check a missing base reward](./base-rewards.md) — green `doctor` vs missing `model=base_reward`.
- [Use your Mac yourself, first](./local-first.md) · [The local API](./direct-mode.md) · [Fan control](./fan-control.md) · [Beta features](./beta-features.md).
