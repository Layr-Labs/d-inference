# Provider CLI reference

> Last updated: 2026-09-06 · commit `14f809d65`

Reference for the `darkbloom` command-line tool: every subcommand and flag, the
files and identifiers it creates, the `provider.toml` keys it reads with their
defaults, the environment variables it forwards to the daemon, and its runtime
constants, as declared in `provider-swift/Sources/darkbloom/` (`Darkbloom`,
version `ProviderCore.version` = `0.8.16` in
`provider-swift/Sources/ProviderCore/ProviderCore.swift`). For operators; types
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
| `--no-replace` | flag | `false` | Requires `--local`; refuse an occupied kernel lock or a still-live legacy owner without terminating it (`provider-swift/Sources/darkbloom/StartCommand.swift`, `Start.validate`; `provider-swift/Sources/ProviderCore/Service/ProcessLifecycle.swift`, `acquireSingleInstanceLock`) |
| `--local-endpoint` | flag | `false` | Local endpoint alongside the coordinator; mutually exclusive with `--local` |
| `--port <n>` | `UInt16` | `8000` | Local server port |
| `--bind <addr>` | `String` | `127.0.0.1` | Local server bind address |
| `--no-auth` | flag | `false` | Disable the local bearer-token check |

Exit 1 (`ExitCode.failure`) when `--local` and `--local-endpoint` are combined,
a debugger is attached, RAM is below 8 GB, Metal is unavailable, hardware
detection fails, no model is selected, or the local server does not bind within
5 s (`StartCommand+Preflight.swift`, `StartCommand+Modes.swift`).

The native app invokes `darkbloom start --local --model <id> --no-replace`
(`provider-swift/Sources/DarkbloomApp/Services/LocalAPIStartContract.swift`,
`LocalAPIStartCommand.arguments`). `Start.validate` rejects `--no-replace`
without `--local`. In `Start.runLocalStandalone`
(`provider-swift/Sources/darkbloom/StartCommand+Modes.swift`),
`acquireMediaServingLock(replaceExisting: !noReplace)` runs before token
creation or endpoint publication. `ProcessLifecycle.acquireSingleInstanceLock`
checks `replaceExisting` before either takeover path can signal another
provider; refusal throws `singleInstanceLockBusy` and preserves its owner
record. The default remains `false` for `noReplace`, so starts without the
flag retain their existing replacement policy. An older CLI rejects the unknown
flag; the app does not retry without it.

`start --local` loads its runtime snapshot with `migrateOnDisk: false`,
skipping automatic provider configuration migration. The app's command passes
no configuration-writing options. An explicit `--idle-timeout` without
`--foreground` still writes the policy to configuration; local serving still
creates/reuses credentials and publishes discovery after acquiring the lock. See
[configuration sources](../reference/configuration.md#where-values-are-set).

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
[`architecture/security/attestation.md#trust-levels`](../architecture/security/attestation.md#trust-levels),
and how to read the line in [attestation → Verify](./attestation.md#verify).

### `darkbloom doctor`

| Flag | Type | Default | Effect |
|---|---|---|---|
| `--strict` | flag | `false` | Exit 1 on any WARN as well as FAIL |
| `--coordinator <url>` | `String?` | config URL | Coordinator for the network checks |
| `--support` | flag | `false` | Append coordinator URL, token presence, MDM state, PID-file path |
| `--json` | flag | `false` | One schema-1 JSON report on stdout; no update banner, unchanged failure exit status (`provider-swift/Sources/darkbloom/DoctorCommand.swift`, `Doctor.run`) |
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
| `list` | `--all` | flag | `false` | Scan all disk inventory, ignoring enabled-model and available-memory filters (`provider-swift/Sources/darkbloom/ModelsCommand.swift`, `Models.List.listedModels`) |
| `list` | `--hash <model-id>` | `String?` | `nil` | Compute the aggregate SHA-256 of one model |
| `catalog` | `--coordinator <url>` | `String?` | config URL | Catalog source |
| `catalog` | `--json` | flag | `false` | Raw output |
| `catalog` | `--include-runtime-eligibility` | flag | `false` | With `--json`, emit `models`, per-model `runtime_eligibility`, and empty `download_plans` without planning downloads or hashing model weights. If both inclusion flags are set, download plans are included (`provider-swift/Sources/darkbloom/ModelsCatalogOutput.swift`, `Models.Catalog.makePlanOutput`) |
| `catalog` | `--include-download-plans` | flag | `false` | With `--json`, emit `models`, resume-aware `download_plans`, and per-model `runtime_eligibility` instead of the plain catalog array (`provider-swift/Sources/darkbloom/ModelsCommand.swift`, `Models.Catalog.run`) |
| `catalog` | `--type <t>` | `String?` | `nil` | Filter by `model_type` (e.g. `text`) |
| `download` | `<modelID>` | `String` | — | Catalog id (or S3 name) |
| `download` | `--coordinator <url>` | `String?` | config URL | Resolve the catalog entry |
| `download` | `--r2-cdn <url>` | `String?` | `DARKBLOOM_R2_CDN_URL`, else `https://models.darkbloom.ai` (`provider-swift/Sources/ProviderCore/Models/ModelDownloader.swift`, `defaultR2CDNURL`) | Mirror base URL |
| `remove` | `<modelID>` | `String` | — | Model to delete from `~/.cache/huggingface/hub` |
| `remove` | `--force` | flag | `false` | Skip confirmation |

`runtime_eligibility` is keyed by catalog model ID. Each value has `status`
(`eligible`, `ineligible`, or `unknown`) and `reason`, computed in the CLI by
`ModelRuntimeRequirements.evaluate`
(`provider-swift/Sources/darkbloom/ModelsCatalogOutput.swift`,
`ModelsCatalogRuntimeEligibility`). The app presents this verdict before RAM
fit; it does not infer runtime support or duplicate the CLI's capability table.
An older CLI's missing verdict remains unknown in the app.

`doctor` and model `list` / `catalog` load runtime snapshots with
`migrateOnDisk: false`: inspection does not create or migrate provider
configuration. These reads can still inspect hardware, contact the coordinator,
or hash staged files for download plans. Starting serving, downloading/removing
models, and `doctor --clear-backend-guard` are separate mutating actions.

### `darkbloom local`

| Flag | Type | Default | Effect |
|---|---|---|---|
| `--json` | flag | `false` | Print the raw `~/.darkbloom/local.json` record |

Exit 1 (and `{}` in JSON mode) when no live local server is recorded
(`LocalEndpoint.readLiveInfo`, `provider-swift/Sources/ProviderCore/Server/LocalEndpoint.swift`).

### `darkbloom login` / `darkbloom logout`

| Command / option | Behavior | Code |
|---|---|---|
| `login [--config <path>]` | Request a device code, open the approval URL, and poll for fresh authorization. Save the token with its account and issuing coordinator. | `provider-swift/Sources/darkbloom/LoginCommand.swift` (`Login`); `provider-swift/Sources/ProviderCore/Auth/DeviceAuth.swift` (`performDeviceCodeLogin`) |
| `login --json` | Emit `code`, `linked`, or `error` NDJSON events; the calling app opens the approval URL. A complete saved credential for the configured issuer emits `linked` immediately without a new browser flow. Error text never confirms a link. | `provider-swift/Sources/darkbloom/LoginCommand.swift` (`LoginEventNDJSON`) |
| `login` with incomplete legacy metadata | Run fresh browser authorization without first deleting the old credential. Replace only the unchanged original files after authorization succeeds; a recorded issuer must still match. Normal credential reads continue to reject incomplete metadata. | `provider-swift/Sources/ProviderCore/Auth/ProviderCredentialRecovery.swift` (`ProviderCredentialRecovery`); `provider-swift/Sources/ProviderCore/Auth/ProviderCredentialStore.swift` (`load`) |
| `login` after interrupted replacement | Require fresh authorization before replacing the interrupted state. Recovery backups block legacy-token import and are never restored as credentials. | `provider-swift/Sources/ProviderCore/Auth/ProviderCredentialRecoveryArtifacts.swift` (`ProviderCredentialRecoveryArtifacts`); `provider-swift/Sources/ProviderCore/Auth/ProviderCredentialRecovery.swift` (`ProviderCredentialRecovery`) |
| `logout` | Stop provider services, revoke the token at its recorded issuer, then clear local credentials. Revocation failure preserves credentials. | `provider-swift/Sources/darkbloom/LogoutCommand.swift` (`Logout`); `provider-swift/Sources/darkbloom/AccountUnlink.swift` (`unlinkProviderAccount`) |
| `logout --local-only` | Stop provider services and remove local credentials without sending an unverifiable token to a coordinator. Remote revocation is not established. | `provider-swift/Sources/darkbloom/LogoutCommand.swift` (`Logout`) |

### `darkbloom benchmark`

| Group | Flags (type = default) |
|---|---|
| Throughput | `--model <id>` (`String?`), `--prompt <text>` (`ModelBenchmark.defaultPrompt`), `--iterations <n>` (`ModelBenchmark.defaultIterations`), `--max-tokens <n>` (`ModelBenchmark.defaultMaxTokens`) |
| Scheduler prefill decision | `--scheduler-prefill-decision`, `--expected-model-aggregate-sha256`, `--expected-registered-binary-sha256`, `--expected-version`, `--source-sha`, `--decision-iterations` (`SchedulerPrefillDecisionReport.minimumLiveIterations`), `--output <path>` (`BenchmarkCommand+SchedulerPrefillDecision.swift`) |
| Sweep | `--sweep`, `--prefill-lengths` (`"128,512,2048"`), `--max-batch` (`6`), `--batch-sizes` (`String?`), `--decode-tokens`, `--decode-prompt-tokens`, `--decode-iterations` (`ThroughputSweep` defaults), `--kv-backend` (`"auto"`) (`BenchmarkCommand+Sweep.swift`) |
| Scheduler prefill | `--scheduler-prefill`, `--prefill-iterations` (`2`) |
| Arrival invariance | `--arrival-invariance`, `--arrival-prompt-tokens` (`512`), `--arrival-prompt-lengths` (`String?`; exactly four comma-separated positive lengths, overrides the uniform prompt length), `--arrival-decode-tokens` (`64`), `--arrival-iterations` (`3`) (`BenchmarkCommand.swift`, `Benchmark.arrivalPromptLengths`) |
| Backend parity | `--parity`, `--assistant-model <id>` (`String?`), `--parity-max-tokens` (`48`), `--parity-prefix-tokens` (`28672`) (`BenchmarkCommand+Parity.swift`) |

Environment inputs for the harnesses are in
[`reference/configuration.md`](../reference/configuration.md).
For a pinned GPT-OSS matrix with aggregate B=2/B=4 decode, raw token timing,
and mixed prompt arrivals, see [the profiling workflow](../developer/test.md#6-scripts-and-release-integrity).

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

| Flag | Description |
|------|-------------|
| `--coordinator-url <url>` | Override the coordinator WebSocket URL |
| `--model <id>` | Model to serve; repeatable (skips the interactive picker) |
| `--all` | Serve all downloaded models |
| `--idle-timeout <mins>` | Idle-memory policy, saved to `[backend] idle_timeout_mins` (0 = always ready); skips the memory prompt |
| `--foreground` | Run in the foreground (used by launchd; normally implicit) |
| `--local` | Run a local OpenAI server only; do not connect to the coordinator |
| `--no-replace` | With `--local`, refuse to replace an existing provider; see [the start contract](#darkbloom-start) |
| `--local-endpoint` | Serve a local OpenAI endpoint alongside the coordinator |
| `--port <port>` | Port for `--local` / `--local-endpoint` (default 8000) |
| `--bind <addr>` | Bind address for local modes (default 127.0.0.1) |
| `--no-auth` | Disable local API-key auth (trusted/airgapped only) |

| Flag | Type | Default | Effect |
|---|---|---|---|
| `--last <duration>` | `String` | `24h` | Window of unified logs to collect |
| `--dry-run` | flag | `false` | Print the report; do not upload |

After the model picker, an interactive `darkbloom start` asks how the machine
should treat its memory when nobody is sending requests:

```
Memory when idle
  1) Always ready    Keep models loaded (~18 GB while idle). Instant responses,
                     full base rewards.
  2) Free when idle  Unload after 60 min without requests; reload on demand
                     (~10-30 s cold start). Your Mac gets its memory back.
  3) Custom          Choose the number of idle minutes.
  Choice [2]:
```

Enter keeps the policy already in force (`Free when idle` on a fresh install).
The answer is written to `[backend] idle_timeout_mins` and applies to every
serve mode; `--model`/`--all`, `--idle-timeout`, non-interactive runs and the
launchd relaunch never prompt. See [`darkbloom idle`](#darkbloom-idle).

Examples:

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

## `darkbloom idle`

Manage the idle-memory policy: whether a model stays loaded while the machine
receives no requests, or is unloaded to give the memory back and reloaded on
demand. The single source of truth is `[backend] idle_timeout_mins` in
`provider.toml` (0 = always ready); `darkbloom start`'s memory prompt and
`--idle-timeout` write the same key, and the launchd plist never carries it.

```bash
darkbloom idle status                 # current policy and where it is set (default)
darkbloom idle keep-loaded            # always ready: models stay loaded
darkbloom idle unload-after <minutes> # free when idle: unload after N idle minutes (1..10080)
```

| Policy | `idle_timeout_mins` | Effect |
|--------|---------------------|--------|
| Always ready | `0` | Models stay resident; instant responses; the machine stays eligible for base rewards the whole time |
| Free when idle (default) | `60` | A model with no requests for 60 min is unloaded; the next request reloads it (~10-30 s cold start) |
| Custom | `N` | Same as above with an `N`-minute window |

Changes are saved with the same locked read-modify-write as `darkbloom beta`
and take effect after `darkbloom restart`. The provider reports the policy in
its heartbeat (`idle_unload_mins`) so the dashboard shows an empty slot as
"sleeping, wakes on demand" rather than as a fault. `--json` prints the policy
machine-readably.

## `darkbloom stop`

```bash
darkbloom stop [--uninstall]
```

| Flag | Description |
|------|-------------|
| `--uninstall` | Also remove the launchd plist |

`--uninstall` disarms the crash-recovery watchdog before removing the agent
(`provider-swift/Sources/darkbloom/StopCommand.swift`).

## `darkbloom restart`

Restart the running launchd service in place, reusing the current coordinator URL
and model selection.

```bash
darkbloom restart
```

## `darkbloom status`

Show local configuration, hardware, schedule, and live daemon state.

```bash
darkbloom status
```

Output includes:

- Provider version and config path.
- Coordinator URL and backend settings.
- Detected hardware (chip, RAM, GPU cores).
- Schedule state (active/inactive).
- Live daemon PID, uptime, trust verdict, and last model-load error.
- `Memory when idle`: the idle-memory policy in force (`always ready` or
  `free after N idle`), and any advertised models that are currently not
  loaded, with the reason (unloaded when idle vs. loads on first request).
- Per-slot posture: the KV backend each loaded model actually resolved to
  (`paged` / `contiguous`), the selection the config asked for, and whether
  MTP is enabled, active, or enabled-but-inert.

### Slot posture

```
Slot posture: state written 2s ago
  google/gemma-4-26b: kv=paged (requested paged) | mtp=enabled, active
  openai/gpt-oss-20b: kv=contiguous (requested auto) | mtp=enabled but INERT (inert_kv_unsupported)
  big/model-70b: kv=NOT SERVING (requested paged) — load failed: …
```

`requested` is what `engine_v2_kv_backend` (or a per-model override in
`engine_v2_kv_backend_by_model`) asked for; the `kv=` value is what the
engine was actually built with. They differ when a request was vetoed,
degraded, or refused — an explicitly requested `paged` backend that cannot
be built REFUSES the load rather than serving contiguous, so that model
shows `kv=NOT SERVING`.

`mtp=enabled but INERT` means a drafter is resident and charging memory
while producing no drafts. It is not the same state as `mtp=enabled,
active`, and the reason is always named.

These values come from the daemon's state file
(`~/.darkbloom/daemon-state.json`, override with `DARKBLOOM_STATE_FILE`),
which the running daemon rewrites every `heartbeat_interval_secs / 2`
seconds — about every 2 s at the default. The header carries the snapshot's
age, and the block is prefixed `STALE` once it has gone unrefreshed for
four write cycles: a value from before a reload is worse than no value.

## `darkbloom doctor`

Run local diagnostics and fetch the coordinator's trust view.

```bash
darkbloom doctor [--strict] [--coordinator <url>] [--support]
```

| Flag | Description |
|------|-------------|
| `--strict` | Treat warnings as failures |
| `--coordinator <url>` | Override coordinator URL for remote checks |
| `--support` | Print local identifiers useful for support |

`darkbloom doctor` is read-only except for the subprocess calls used by public
ProviderCore checks.

Two of the detailed checks cover the KV-backend rollout:

| Check | Fails when |
|-------|-----------|
| `daemon state freshness` | The daemon is running but has not rewritten its state file for eight write periods — it is wedged, and every live value below it is a guess. The bar is derived from `heartbeat_interval_secs` (the daemon writes every half-heartbeat) with a 90 s floor, so raising the heartbeat does not make a healthy daemon look wedged. |
| `kv backend posture` | An EXPLICIT `paged` or `contiguous` request was not honoured: refused (no engine built, the box serves nothing for that model) or silently degraded to another backend. |

`auto` never fails this check — it promises nothing, so whichever backend it
lands on is honoured by definition. It resolves contiguous as of v0.8.1, so an
`auto` slot reporting contiguous is expected output, not a finding. Explicit
`paged` remains available and refuses a load it cannot serve instead of
silently changing backends. When
the state file is past the wedge bar the backend verdict is WITHHELD rather
than asserted from a snapshot that may predate a reload.

An explicit `engine_v2_kv_backend` with no slot behind it — startup preload
off, or every slot idle-unloaded — WARNs rather than passes: nothing on the
box has loaded, let alone proved, the backend it was configured for. Under
`--strict` (and therefore `darkbloom verify`) that warning exits non-zero,
which is the point: an unproven paged rollout must not certify.

## `darkbloom verify`

Equivalent to a strict `doctor` run. Any warning or failure exits non-zero.

```bash
darkbloom verify [--coordinator <url>]
```

## `darkbloom models`

Manage locally cached MLX models.

### `darkbloom models catalog`

Show the coordinator's supported-model catalog.

```bash
darkbloom models catalog [--coordinator <url>] [--json] [--type <type>]
```

### `darkbloom models list`

List local models.

```bash
darkbloom models list [--json] [--all] [--hash <model-id>]
```

| Flag | Description |
|------|-------------|
| `--all` | Show every discovered model, ignoring `enabled_models` |
| `--hash <model-id>` | Compute an on-demand integrity hash for one model |

### `darkbloom models download <id>`

Download a model from the coordinator catalog.

```bash
darkbloom models download <id> [--coordinator <url>] [--r2-cdn <url>]
```

### `darkbloom models remove <id>`

Delete a downloaded model.

```bash
darkbloom models remove <id> [--force]
```

## `darkbloom benchmark`

Run a standardized local inference benchmark.

```bash
darkbloom benchmark [--model <id>] [--prompt <text>] [--iterations <n>] [--max-tokens <n>]
```

| Flag | Description |
|------|-------------|
| `--model <id>` | Model to benchmark (defaults to the largest model that fits) |
| `--prompt <text>` | Prompt text |
| `--iterations <n>` | Number of iterations (default from `ModelBenchmark`) |
| `--max-tokens <n>` | Maximum tokens to generate per iteration |

## `darkbloom update`

Check for and apply provider updates.

```bash
darkbloom update [--check-only] [--coordinator <url>]
```

| Flag | Description |
|------|-------------|
| `--check-only` | Report whether an update is available without installing |
| `--coordinator <url>` | Override coordinator URL |

The update path verifies the archive, app identity, and signed payload hashes
before replacing the managed app as one unit
(`provider-swift/Sources/ProviderCore/Update/SelfUpdater.swift`).
`ProviderAppLayout` selects real nested payloads, checks inner/outer copy parity,
and retains support for legacy regular layouts. The outer CLI compatibility
alias must have the exact published target. See the
[archive contract and upgrade-reader checks](../operations/app-release.md#tar-expansion-safety-contract)
for accepted layouts and qualification of older installed readers.

## `darkbloom autoupdate`

Enable or disable automatic update checks at startup.

```bash
darkbloom autoupdate <enable|disable|status>
```

This toggles `provider.auto_update` in `provider.toml`.

## `darkbloom beta`

Manage configurable beta features. Defaults are feature-specific: the selected
Gemma optimizations default on, while reserved/opt-in features default off.
Provider TOML is authoritative for every serve mode. The Gemma defaults and
missing-key decode are defined in
`provider-swift/Sources/ProviderCore/Config/GemmaOptimizationSettings.swift:16-34`,
with the missing-section fallback in
`provider-swift/Sources/ProviderCore/Config/ProviderConfig.swift:397-400`.
The shared pre-Metal projection is
`provider-swift/Sources/darkbloom/ServeRuntimePreparer.swift:24-35`.

```bash
darkbloom beta list                 # all features + on/off (default subcommand)
darkbloom beta status [feature]     # details for all features, or one
darkbloom beta enable <feature>     # turn on (then: darkbloom restart)
darkbloom beta disable <feature>    # turn off
```

| Feature | Effect |
|---------|--------|
| `gemma-prefill-layer18` | Default-on layer-18 prefill submission; disable and restart for legacy submission behavior |
| `gemma-weighted-r1` | Default-on atomic weighted-unsort + safe-R1 pair; disable and restart to roll back both |
| `mtp` | MTP policy. Default `auto` drafts automatically for Qwen 3.5-family checkpoints that embed their head (`mtplx_mtp` in `config.json`); explicit on additionally enables catalog `spec_dec` assistants and local `mtp_drafter_path` overrides; explicit off is the rollback |

`enable`/`disable` read-modify-write the TOML config and report whether a restart
is required. Restart is the activation boundary for process-wide optimization
state. The durable locked write and restart instruction are implemented in
`provider-swift/Sources/darkbloom/BetaCommand.swift:201-235`. See
[Beta Features](beta-features.md) for the full guide. `darkbloom beta list` also
accepts `--json`. Under the default `auto` mode a served checkpoint that embeds its MTP head
drafts without any beta toggle; checkpoints without an embedded declaration
stay target-only. Local parity results are not a blanket M1-M3/unknown-chip
certification.
The published assistant metadata is visible in the
[public production catalog](https://api.darkbloom.dev/v1/models/catalog?type=text)
under `gemma-4-26b-qat-4bit.metadata.spec_dec`.
`kv-quant` was removed in v0.8.0 and is no longer a valid feature id.

## `darkbloom fan` (experimental)

Inspect or opt into provider-only temperature-based fan control.

```bash
darkbloom fan status [--json]
darkbloom fan diagnose [--json]
sudo darkbloom fan enable [--speed 80] [--temperature 45]
sudo darkbloom fan configure [--speed 60...90] [--temperature C]
sudo darkbloom fan disable
sudo darkbloom fan uninstall
```

Ordinary Darkbloom installation leaves the bundled helper dormant. State changes
require explicit `sudo`; read-only status and diagnostics do not. The helper
applies a target only while a signed provider holds an activity lease and a
validated GPU sensor exceeds the threshold. Defaults are 80% of each fan's
reported maximum, engage at 45 C, and release below 40 C. See
[Experimental Fan Control](fan-control.md) for hardware gates and recovery
behavior.

## `darkbloom login`

Link this machine to a Darkbloom account via RFC 8628 device-code flow.
For credentials saved by older versions, the same command requests fresh
authorization while preserving the previous login until replacement succeeds.
The app exposes this through **Contributions → Reconnect account**.

```bash
darkbloom login
```

## `darkbloom logout`

Unlink this machine from its Darkbloom account.

```bash
darkbloom logout
```

## `darkbloom enroll`

Request and install the Darkbloom MDM / device-attestation profile.

```bash
darkbloom enroll [--coordinator <url>] [--no-open]
```

| Flag | Description |
|------|-------------|
| `--coordinator <url>` | Override coordinator URL |
| `--no-open` | Download the profile but do not open System Settings |

## `darkbloom unenroll`

Open System Settings to remove the Darkbloom MDM profile and optionally clean up
local data.

```bash
darkbloom unenroll [--force] [--no-open]
```

| Flag | Description |
|------|-------------|
| `--force` | Skip the local-data cleanup confirmation |
| `--no-open` | Do not open System Settings |

## `darkbloom local`

Print the local (direct-mode) OpenAI endpoint URL and API key.

```bash
darkbloom local [--json]
```

`darkbloom local` reads `~/.darkbloom/local.json`, but only advertises it if the
recorded server process is still alive.

## `darkbloom logs`

Show provider logs from macOS unified logging or the legacy log file.

```bash
darkbloom logs [--file] [--follow] [--last <duration>] [--debug] [--lines <n>]
```

| Flag | Description |
|------|-------------|
| `--file` | Read from the legacy log file instead of unified logging |
| `--follow`, `-f` | Stream new lines |
| `--last <duration>` | Historical window, e.g. `1h`, `30m`, `24h` |
| `--debug` | Include debug-level messages |
| `--lines <n>` | Number of lines (only with `--file`) |

## `darkbloom report`

Collect recent Darkbloom provider unified logs and explicitly upload them to the
coordinator for troubleshooting.

```bash
darkbloom report [--last <duration>] [--dry-run]
```

| Flag | Description |
|------|-------------|
| `--last <duration>` | Time window, e.g. `1h`, `6h`, `24h` |
| `--dry-run` | Print the exact report locally without uploading |

The command runs only when invoked by the provider operator. It collects the
`dev.darkbloom.provider` subsystem, preserves macOS unified-log privacy
redaction, and does not include debug-level messages. Automatic report upload is
disabled.

## `darkbloom runtime-smoke`

Hidden release check implemented by
`provider-swift/Sources/darkbloom/RuntimeSmokeCommand.swift` (`RuntimeSmoke`).
It verifies the Gemma runtime configuration/latch and packaged Paged kernels,
printing `gemma-optimizations-runtime-smoke: ok` and
`paged-kernel-runtime-smoke: ok` on success. It does not load a model or verify
persistent Secure Enclave/APNs identity. Use the
[signed artifact qualifier](../operations/app-release.md#signed-artifact-qualification-no-signing-secrets-required),
which supplies the required latch inputs, instead of treating an unseeded
manual invocation as release evidence.

## `darkbloom watchdog`

Internal command used by the launchd crash-recovery watchdog. Not intended for
manual use.

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
| Managed CLI | `~/.darkbloom/Darkbloom.app/Contents/Helpers/DarkbloomProvider.app/Contents/MacOS/darkbloom`; real executable used by GUI, LaunchAgent, and watchdog; legacy regular outer CLI only when helper absent | `provider-swift/Sources/ProviderCoreFoundation/ManagedProviderInstallLayout.swift` (`cliRelativePath`); `provider-swift/Sources/ProviderCoreFoundation/ManagedProviderCLIPathValidator.swift` |
| Outer CLI alias | `Darkbloom.app/Contents/MacOS/darkbloom` → exactly `../Helpers/DarkbloomProvider.app/Contents/MacOS/darkbloom` | `provider-swift/Sources/ProviderCoreFoundation/ManagedProviderInstallLayout.swift` (`compatibilityCLISymlinkTarget`) |
| Shell entry points | `~/.darkbloom/bin/{darkbloom,darkbloom-enclave,mlx.metallib}` → outer `../Darkbloom.app/Contents/MacOS/*` (the CLI resolves through the exact alias); `eigeninference-enclave → darkbloom-enclave`; best-effort `/usr/local/bin/darkbloom` | `scripts/install.sh` |
| Capability markers | `Darkbloom.app/Contents/Resources/darkbloom-runtime-capabilities/{paged-kernel-v1,fan-helper-v1}` | `scripts/install.sh` (`verify_staged_app`, `verify_fan_helper_capability`) |
| Config | `~/.config/darkbloom/provider.toml`; a config at a legacy path is copied here on the next run | `provider-swift/Sources/ProviderCore/Config/ProviderConfig.swift` (`defaultConfigPath`); `provider-swift/Sources/darkbloom/Darkbloom.swift` (`migrateConfigIfNeeded`) |
| Device token | `~/.darkbloom/auth_token` (`DARKBLOOM_AUTH_TOKEN_PATH`) | `provider-swift/Sources/ProviderCore/Auth/DeviceAuth.swift` |
| Local-mode token / discovery | `~/.darkbloom/local_token`, `~/.darkbloom/local.json` (`DARKBLOOM_LOCAL_DIR`), both `0600` | `provider-swift/Sources/ProviderCore/Server/LocalEndpoint.swift` |
| Daemon state | `~/.darkbloom/daemon-state.json` (`DARKBLOOM_STATE_FILE`) | `provider-swift/Sources/ProviderCoreFoundation/DaemonStateFile.swift` |
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
key decodes to its default, and that file is the complete schema (this table
lists the keys an operator is likely to set). Environment variables, which
override `provider.toml` for one process, are in
[`reference/configuration.md`](../reference/configuration.md#provider-cli-darkbloom).

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
| `DARKBLOOM_MLX_CACHE_LIMIT_GB` | `provider-swift/Sources/ProviderCore/Inference/MLXMemoryGuard.swift` (`defaultCacheLimitGB`) |
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
| State-file and capacity refresh | every `max(1, heartbeat_interval_secs / 2)` s; the heartbeat default is in the [`provider.toml` table](#providertoml-keys-read-by-the-cli) | `provider-swift/Sources/ProviderCore/ProviderLoop+Capacity.swift` |
| State-file stale threshold | `isStale(maxAge: 90)` s; `doctor` calls the daemon wedged after `max(8 × refresh period, 90)` s | `provider-swift/Sources/ProviderCoreFoundation/DaemonState.swift`; `provider-swift/Sources/darkbloom/Diagnostics/KVBackendPosture.swift` (`wedgedAfterSeconds`) |
| Idle unload | `idle_timeout_mins` ([`provider.toml` table](#providertoml-keys-read-by-the-cli)); polled every 60 s; unloads the model, the daemon keeps running | `provider-swift/Sources/ProviderCore/ProviderLoop+IdleTimeout.swift` |
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
| Minimum RAM to serve | `hardware.memoryGb` floor — [`../architecture/hardware-support.md#context`](../architecture/hardware-support.md#context) | `provider-swift/Sources/darkbloom/StartCommand+Preflight.swift` |

## Related

- [Installation](./installation.md) · [Quickstart](./quickstart.md) · [Troubleshooting](./troubleshooting.md)
- [Direct mode](./direct-mode.md) · [Self-route](./self-route.md) · [Fan control](./fan-control.md) · [Beta features](./beta-features.md)
- [`reference/configuration.md`](../reference/configuration.md) — every environment variable and config key.
- [Attestation](./attestation.md) — trust levels; [`architecture/security/attestation.md`](../architecture/security/attestation.md) for the mechanism.


GPT-OSS benchmark and foreground execution supports the [performance controls](../reference/configuration.md#gpt-oss-performance-controls). The full-projection and kernel rollback modes support paired comparisons with identical request inputs.
