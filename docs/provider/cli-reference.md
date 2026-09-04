# Provider CLI Reference

The `darkbloom` CLI is the Swift provider for macOS. The command tree is defined
in `provider-swift/Sources/darkbloom/Darkbloom.swift:29-48`.

## Global flags

| Flag | Description |
|------|-------------|
| `--config <path>` | Path to `provider.toml` (default: `~/.config/darkbloom/provider.toml`) |
| `--version` | Print the provider version |
| `--help`, `-h` | Show help for a command |

`--config` is the only config-related global flag. There is no `DARKBLOOM_CONFIG`
environment variable.

## `darkbloom start`

Start serving inference. By default this installs and starts a `launchd` user
agent; use `--foreground` to stay attached to the terminal, or `--local` to run
a coordinator-less local server.

```bash
darkbloom start [flags]
```

| Flag | Description |
|------|-------------|
| `--coordinator-url <url>` | Override the coordinator WebSocket URL |
| `--model <id>` | Model to serve; repeatable (skips the interactive picker) |
| `--all` | Serve all downloaded models |
| `--idle-timeout <mins>` | Idle-memory policy, saved to `[backend] idle_timeout_mins` (0 = always ready); skips the memory prompt |
| `--foreground` | Run in the foreground (used by launchd; normally implicit) |
| `--local` | Run a local OpenAI server only; do not connect to the coordinator |
| `--local-endpoint` | Serve a local OpenAI endpoint alongside the coordinator |
| `--port <port>` | Port for `--local` / `--local-endpoint` (default 8000) |
| `--bind <addr>` | Bind address for local modes (default 127.0.0.1) |
| `--no-auth` | Disable local API-key auth (trusted/airgapped only) |

Preflight checks for boot security, debugger attachment, and memory run before
the model picker (`provider-swift/Sources/darkbloom/StartCommand+Preflight.swift:9-27`);
the Metal requirement is enforced by `Start.prepareServeRuntime`
(`provider-swift/Sources/darkbloom/StartCommand.swift:128-147`).

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

```bash
# Interactive daemon install
darkbloom start

# Skip picker, serve specific models
darkbloom start --model gemma-4-26b --model gpt-oss-20b

# Foreground with explicit coordinator
darkbloom start --foreground --coordinator-url wss://api.dev.darkbloom.xyz/ws/provider

# Local-only OpenAI endpoint on port 8080
darkbloom start --local --port 8080

# Unified: public fleet + local endpoint
darkbloom start --local-endpoint --bind 100.x.y.z
```

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

Stop the launchd service. By default the command waits for in-flight inference
to finish before booting the daemon out, polling the daemon state file once a
second for an idle moment. The coordinator may keep routing new requests while
it waits, so a busy provider can reach the timeout; re-run with `--force` then.

```bash
darkbloom stop [--uninstall] [--force] [--timeout <seconds>]
```

| Flag | Description |
|------|-------------|
| `--uninstall` | Also remove the launchd plist |
| `--force` | Stop immediately without waiting for in-flight requests |
| `--timeout <seconds>` | Maximum seconds to wait for in-flight requests (default 60; `0` refuses to stop while requests are active unless `--force`) |

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

The update path verifies bundle, binary, and `mlx.metallib` hashes before
replacing the running binary (`provider-swift/Sources/ProviderCore/Update/SelfUpdater.swift`).

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

## `darkbloom watchdog`

Internal command used by the launchd crash-recovery watchdog. Not intended for
manual use.

## Exit codes

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | General failure |
| 2 | Invalid arguments (ArgumentParser) |
| 3 | Config error |
| 4 | Authentication / authorization error |
| 5 | Network error |
| 6 | Hardware incompatible |
| 7 | Binary verification failed |
| 8 | Update failed |

These are the standard `ExitCode` values used by the ArgumentParser-based CLI.

## Environment variables

| Variable | Description |
|----------|-------------|
| `DARKBLOOM_NO_UPDATE_CHECK` | Skip the update banner at CLI startup |

There is no `DARKBLOOM_LOG_LEVEL` or `DARKBLOOM_CONFIG` environment variable;
use `--config` and the TOML file for configuration.
