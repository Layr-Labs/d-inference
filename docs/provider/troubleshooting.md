# Provider troubleshooting

> Last updated: 2026-09-03 · commit `5d400cf75`

Symptom → check → fix for the `darkbloom` provider: installer exits, `doctor`
check names, service lifecycle, coordinator connection, updates, models and the
KV-backend guard. For operators; every fix is a command you run on the Mac.

## Prerequisites

Start every session with the three read-only commands:

```bash
darkbloom doctor --strict      # ✓ / ⚠ / ✗ per check; exit 1 on any ⚠ or ✗
darkbloom status               # config, hardware, live daemon snapshot
darkbloom logs --last 1h       # unified logs, subsystem dev.darkbloom.provider
```

`doctor` (`provider-swift/Sources/darkbloom/DoctorCommand.swift`, `Doctor`) and
`status` read `~/.darkbloom/daemon-state.json`, which the daemon rewrites every
`max(1, heartbeat_interval_secs / 2)` s (2 s by default). A snapshot older than
90 s is `STALE`; older than `max(8 × refresh period, 90)` s and `doctor` reports
the daemon as wedged (`provider-swift/Sources/darkbloom/Diagnostics/KVBackendPosture.swift`,
`wedgedAfterSeconds`).

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
| `Staged Darkbloom.app does not satisfy the pinned signature requirement.` / `Legacy flat artifact does not satisfy …` | `codesign --verify --deep --strict -R=…` failed against `identifier "io.darkbloom.provider"`, Team `SLDQ2GJ6TL` | Do not install; the artifact is not the signed release |
| `Fan-helper CLI capability, marker, and nested helper must be present together.` / `… marker is invalid.` / `Bundled fan helper must be a regular executable …` / `… must have mode 0755.` / `… does not satisfy the pinned helper signature requirement.` | Fan-helper capability triple inconsistent in the staged app | Bad artifact; report it |
| `Paged-capable staged app is missing its signed capability marker.` / `Staged app advertises paged capability without paged runtime code.` / `Paged runtime capability marker is invalid.` / `… requires exactly one sealed MLXLMCommon pagedattention.metal.` | Paged-kernel marker ⇔ binary ⇔ resource mismatch | Bad artifact; report it |
| `Packaged paged-kernel runtime smoke failed.` | `darkbloom runtime-smoke` could not load the packaged Metal runtime | Confirm a Metal GPU (`system_profiler SPDisplaysDataType`); retry; report with the macOS version |
| `Atomic app swap failed; previous install was restored.` | `mv` into `~/.darkbloom` failed | Check free space and permissions on `~/.darkbloom` |
| `Secure Enclave ⚠ (not available on this hardware …)` (warning, install continues) | `darkbloom-enclave info` failed | Trust stays below `hardware`; see [attestation](./attestation.md) |
| `Enrollment ⚠ …` (warning) | Profile not installed, or `POST /v1/enroll` unreachable | `darkbloom enroll`, then install the profile in System Settings |
| `darkbloom: command not found` after install | Shell not reloaded; rc file is `~/.zshrc`, or `~/.bashrc` only if `~/.zshrc` is absent | `source ~/.zshrc`, or `export PATH="$HOME/.darkbloom/bin:$PATH"` |

## Doctor checks

`darkbloom doctor` prints an operator diagnosis (sections attestation key,
attestation readiness, trust, model fit, runtime, billing, version;
`provider-swift/Sources/darkbloom/Diagnostics/DoctorRunner.swift`,
`buildOperatorDiagnosis`) followed by `DETAILED CHECKS`
(`provider-swift/Sources/darkbloom/DoctorCommand.swift`, `buildDoctorChecks`,
`buildCoordinatorDoctorChecks`). Check names are stable identifiers:

| Check | What it tests | When it is not ✓ |
|---|---|---|
| `hardware`, `metal gpu`, `macos` | Chip/RAM detection, Metal device, OS version | Apple Silicon with a working GPU is required; nothing to configure |
| `config` | `provider.toml` parses | Fix the TOML at `~/.config/darkbloom/provider.toml`; retired keys only warn |
| `huggingface cache`, `local mlx models` | `~/.cache/huggingface/hub` exists and holds serveable models | `darkbloom models download <id>` |
| `sip`, `authenticated root`, `hardened runtime`, `debugger`, `binary hash`, `rdma` | Boot security and process integrity the coordinator scores | `csrutil enable` from Recovery; detach debuggers; reinstall if the binary hash is unknown. Effects on trust: [attestation](./attestation.md) |
| `account link` | `~/.darkbloom/auth_token` present and accepted | `darkbloom login` |
| `mdm enrollment`, `mdm verification` | Profile installed; coordinator has cross-checked `SecurityInfo` | `darkbloom enroll`; how and when the grant happens: [Reaching `hardware`](./attestation.md#reaching-hardware) |
| `console session`, `automatic login`, `auto-logout on idle`, `sleep prevention` | Attestation readiness (`provider-swift/Sources/ProviderCore/Diagnostics/AttestationReadiness.swift`) | A real console user must be logged in; enable automatic login; disable auto-logout; the daemon self-caffeinates while serving |
| `active se key` | Secure Enclave signing key self-test | `darkbloom-enclave info`; hardware without SE runs at reduced trust |
| `coordinator health`, `minimum version`, `coordinator trust` | Coordinator reachable, this version is accepted, trust verdict with reasons | `darkbloom update`; reasons are explained in [attestation](./attestation.md) |
| `trust level` stuck at `self_signed` | The MDM `SecurityInfo` cross-check has not passed for this connection | `darkbloom enroll` if not enrolled; otherwise wait — see [Reaching `hardware`](./attestation.md#reaching-hardware) |
| `daemon`, `daemon connected`, `daemon state freshness` | Daemon process alive, WebSocket connected, snapshot refreshed | See [service lifecycle](#the-service-does-not-stay-running); a stale snapshot ⇒ `darkbloom restart` |
| `recent model load` | Last model-load error recorded by the daemon | See [models and memory](#models-and-memory) |
| `kv backend posture`, `kv backend crash-loop guard` | Explicit `engine_v2_kv_backend` request honoured; guard record present | See [KV-backend guard](#kv-backend-crash-loop-guard) |
| `competing inference` | Another inference server holds the GPU (`provider-swift/Sources/darkbloom/Diagnostics/CompetingInferenceDiagnostics.swift`) | Quit it; it competes for the same unified memory and GPU time |
| `usage reporting` | Usage rows the coordinator has not acknowledged (`usageGaps > 0`) | Transient after reconnects; persistent gaps ⇒ `darkbloom report` |
| `up to date` | `SelfUpdater.checkForUpdate`; also reports a quarantined release | See [updates](#updates) |

`darkbloom verify` runs the same set and exits 1 on any ⚠.

## `darkbloom start` fails

| Message | Cause | Fix |
|---|---|---|
| `--local and --local-endpoint are mutually exclusive …` | Both flags given | Pick one ([direct mode](./direct-mode.md)) |
| `A debugger is attached. The coordinator will reject this provider.` | `checkDebuggerAttached()` | Detach the debugger |
| `This Mac has N GB RAM. At least 8 GB is needed to serve any model.` | `Start.runPreflightChecks` (`provider-swift/Sources/darkbloom/StartCommand+Preflight.swift`) | Use a larger machine ([hardware requirements](./hardware-requirements.md)) |
| `Cannot start: …` | `Start.prepareServeRuntime` — `GPUEnforcement.requireMetal` failed, or the Gemma runtime environment could not be applied (`GemmaOptimizationEnvironment.apply`) | Confirm a Metal GPU (`system_profiler SPDisplaysDataType`); retry |
| `Cannot start: hardware detection failed …` | `sysctl`/`system_profiler` failed | Retry; report the output of `sysctl machdep.cpu.brand_string hw.memsize` |
| `No models selected.` | Picker cancelled or `--model` ids not local | `darkbloom models list`; `darkbloom models download <id>` |
| `No engine-v2-capable models available to serve.` (`--local`) | Every local model's family lacks a CBv2 adapter | Download a supported family (gpt-oss, gemma-4) |
| `Local server failed to bind <addr>:<port> within 5s` | Port in use | `--port <other>`, or stop the other process |
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
| Models unload after an hour, daemon stays up | `backend.idle_timeout_mins = 60`; polled every 60 s; reload is lazy on the next request (`provider-swift/Sources/ProviderCore/ProviderLoop+IdleTimeout.swift`) | Expected. `idle_timeout_mins = 0` disables unloading |
| Provider offline after logout / at the login window | GUI LaunchAgents run only inside a logged-in session | Enable automatic login; see `console session` above |
| Daemon restarts every few minutes, then `kv backend crash-loop guard` appears | `crashLoopTripThreshold = 3` restarts inside the watchdog window (`provider-swift/Sources/ProviderCore/Service/WatchdogDecision.swift`) | See [KV-backend guard](#kv-backend-crash-loop-guard) |
| `darkbloom restart` prints `Provider is not running. Start it with darkbloom start.` | Plist not installed | `darkbloom start` |

## Coordinator connection

| Symptom | Mechanism | Fix |
|---|---|---|
| `daemon connected` ⚠, console shows offline | The client reconnects with `ExponentialBackoff(base: 1.0, max: 30.0)` s (`provider-swift/Sources/ProviderCore/Coordinator/CoordinatorClient+Connection.swift`) | `curl -v https://api.darkbloom.dev/health`; check DNS, clock, TLS interception, firewall on 443 |
| Log: `WebSocket pong timeout (no response in 30s)` | Ping every `pingInterval = 10.0` s; no pong for `pongTimeout = 30.0` s closes the socket and the backoff restarts it | Network path stalls; nothing to configure on the provider |
| Heartbeats arrive but requests do not | Heartbeat is `heartbeat_interval_secs = 5`; being connected is not being routable | `darkbloom doctor` → `trust level`, `coordinator trust`; the routing gates are listed in [attestation](./attestation.md#what-the-coordinator-checks-before-routing-to-you) |
| `minimum version` ✗ | Coordinator rejects this `ProviderCore.version` | `darkbloom update` |

## Updates

| Symptom | Cause | Fix |
|---|---|---|
| `Latest release vX is quarantined on this machine.` | vX crashed `rollbackThreshold = 3` times before surviving `defaultStabilizationSeconds = 600` (`provider-swift/Sources/ProviderCore/Update/UpdateRecoveryState.swift`) | Wait for the next release (it installs normally), or `darkbloom update --override-quarantine` |
| `vX is already installed on disk but this process is vY.` | Update landed, daemon not restarted | `darkbloom restart` |
| `SHA-256 hash mismatch!` | Download ≠ `bundle_hash`/`binary_hash`/`metallib_hash` | Retry; persistent mismatch means the release record and artifact disagree |
| `another update/recovery operation is active` | Watchdog recovery or a previous update holds the lock | Wait a minute; retry |
| No automatic updates | `provider.auto_update = false`, or `DARKBLOOM_NO_UPDATE_CHECK` set in a `--foreground` shell | `darkbloom autoupdate status`, `darkbloom autoupdate enable` |
| Fan control stops after an update | The unprivileged updater does not replace the root helper | `sudo darkbloom fan enable` ([fan control](./fan-control.md)) |

Constants: first in-daemon check 300 s after start, then every 1800 s, install
delayed up to `update_jitter_seconds = 300`, 120 s drain before restart
(`provider-swift/Sources/ProviderCore/ProviderLoop+AutoUpdate.swift`).

## Models and memory

| Symptom | Cause | Fix |
|---|---|---|
| `model fit` ✗ / `recent model load` shows admission refused | `ModelLoadAdmission` (`provider-swift/Sources/ProviderCore/Inference/ModelLoadAdmission.swift`): loadable = min(total − `memory_reserve_gb`, OS-available) − resident MLX − live GPU-active | Close other apps; lower `max_model_slots`; pick a smaller quantisation ([hardware requirements](./hardware-requirements.md)) |
| Model missing from `darkbloom models list` | Not in `~/.cache/huggingface/hub`, or filtered by `enabled_models` | `darkbloom models download <id>`; `darkbloom models list --all` |
| Load fails after a catalog update | New build published for the alias | `darkbloom models remove <id>` then `darkbloom models download <id>` |
| `Skipping <id>: model_type … has no engine-v2 adapter` | Family not served by CBv2 | Use a supported family; the model is never advertised |
| Slow decode, GPU busy | `competing inference` ⚠ | Quit the other server |

## KV-backend crash-loop guard

The watchdog writes `~/.darkbloom/kv-backend-guard.json` after
`crashLoopTripThreshold = 3` restarts; while it matches the running version the
engine forces contiguous KV and `doctor` shows `kv backend crash-loop guard`
(`provider-swift/Sources/ProviderCore/Service/KVBackendGuard.swift`;
`provider-swift/Sources/darkbloom/Diagnostics/KVBackendGuardDiagnostics.swift`).

```bash
darkbloom doctor                        # read the guard record and the posture per slot
darkbloom doctor --clear-backend-guard  # delete the record, reset the crash-loop counter
darkbloom restart
```

A new binary version clears a stale record on start. `kv backend posture` ✗
means an explicit `engine_v2_kv_backend = "paged"` (or per-model entry) could
not be built and the model refused to load rather than degrade; set `"auto"` or
`"contiguous"` for that model, or keep paged and accept the refusal.

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
support.

## Related

- [CLI reference](./cli-reference.md) — flags, paths, runtime constants.
- [Installation](./installation.md) · [Quickstart](./quickstart.md).
- [Attestation](./attestation.md) — trust levels, enrollment, challenge cadence.
- [Direct mode](./direct-mode.md) · [Fan control](./fan-control.md) · [Beta features](./beta-features.md).
