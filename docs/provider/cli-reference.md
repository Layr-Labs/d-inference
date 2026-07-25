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
| `--idle-timeout <mins>` | Idle timeout before unloading a model |
| `--foreground` | Run in the foreground (used by launchd; normally implicit) |
| `--local` | Run a local OpenAI server only; do not connect to the coordinator |
| `--local-endpoint` | Serve a local OpenAI endpoint alongside the coordinator |
| `--port <port>` | Port for `--local` / `--local-endpoint` (default 8000) |
| `--bind <addr>` | Bind address for local modes (default 127.0.0.1) |
| `--no-auth` | Disable local API-key auth (trusted/airgapped only) |

Preflight checks (SIP, debugger, GPU, memory) run before the model picker
(`provider-swift/Sources/darkbloom/StartCommand.swift:429-448`).

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

## `darkbloom stop`

Stop the launchd service.

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
| `daemon state freshness` | The daemon is running but has not rewritten its state file for 90 s — it is wedged, and every live value below it is a guess. |
| `kv backend posture` | An EXPLICIT `paged` or `contiguous` request was not honoured: refused (no engine built, the box serves nothing for that model) or silently degraded to another backend. |

`auto` never fails this check — it resolves to contiguous by design. When
the state file is past the wedge bar the backend verdict is WITHHELD rather
than asserted from a snapshot that may predate a reload.

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

Manage opt-in beta features. Beta features are off by default and config-backed
(a TOML field), so they apply to the launchd daemon too — unlike environment
variables, which the daemon does not inherit.

```bash
darkbloom beta list                 # all features + on/off (default subcommand)
darkbloom beta status [feature]     # details for all features, or one
darkbloom beta enable <feature>     # turn on (then: darkbloom restart)
darkbloom beta disable <feature>    # turn off
```

| Feature | Effect |
|---------|--------|
| `mtp` | Default-off Gemma 4 MTP code path; requires a separately published and verified `spec_dec` artifact, which production does not currently have |

`enable`/`disable` read-modify-write the TOML config and report whether a restart
is required. See [Beta Features](beta-features.md) for the full guide. `darkbloom
beta list` also accepts `--json`. Installing a provider release does not enable
MTP, and local parity results are not a blanket M1–M3/unknown-chip certification.
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

Collect the last 24 hours of Darkbloom provider unified logs and upload them to
the coordinator for troubleshooting.

```bash
darkbloom report [--last <duration>] [--dry-run]
```

| Flag | Description |
|------|-------------|
| `--last <duration>` | Time window, e.g. `1h`, `6h`, `24h` |
| `--dry-run` | Print the log content instead of uploading |

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
