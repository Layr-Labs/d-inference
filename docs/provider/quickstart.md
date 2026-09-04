# Provider quickstart

> Last updated: 2026-09-03 · commit `5d400cf75`

From a fresh Apple Silicon Mac to a provider that is registered with the
coordinator, linked to your account and serving. For operators; install, check,
log in, pick models, start — then enrol for the `hardware` trust level that
public traffic requires.

## Prerequisites

- A Mac that meets [hardware requirements](./hardware-requirements.md#minimum-requirements).
  `darkbloom start` refuses machines below the RAM floor or without a
  Metal GPU (`provider-swift/Sources/darkbloom/StartCommand+Preflight.swift`,
  `Start.runPreflightChecks`; `provider-swift/Sources/darkbloom/StartCommand.swift`,
  `Start.prepareServeRuntime`).
- Outbound HTTPS (443) to `api.darkbloom.dev`; the provider is an outbound-only
  WebSocket client to `wss://api.darkbloom.dev/ws/provider`
  (`provider-swift/Sources/ProviderCore/Config/ProviderConfig.swift`,
  `CoordinatorSettings.url`).
- A Darkbloom account for `darkbloom login`; the login flow prints the URL to
  open.

## Steps

### 1. Install

```bash
curl -fsSL https://api.darkbloom.dev/install.sh | bash
source ~/.zshrc
```

What the script verifies and writes is in [installation](./installation.md).

### 2. Check the machine

```bash
darkbloom doctor
```

Lines marked `✗` are failures. Hardware, Metal, SIP, account link, MDM
enrollment and coordinator reachability are all covered; the check names are
listed in [troubleshooting](./troubleshooting.md#doctor-checks).

### 3. Download a model

```bash
darkbloom models catalog              # coordinator catalog with size and min RAM
darkbloom models download <id>        # into ~/.cache/huggingface/hub
darkbloom models list                 # what this Mac can serve
```

`darkbloom models download` (`provider-swift/Sources/darkbloom/ModelsCommand.swift`)
resolves the catalog entry and fetches from `https://models.darkbloom.ai`
(`provider-swift/Sources/ProviderCore/Models/ModelDownloader.swift`,
`defaultR2CDNURL`). `darkbloom start` also offers an interactive catalog picker
when nothing is downloaded yet, so this step can be skipped.

### 4. Link your account

```bash
darkbloom login
```

`Login` (`provider-swift/Sources/darkbloom/LoginCommand.swift`) runs the RFC 8628
device-code flow (`provider-swift/Sources/ProviderCore/Auth/DeviceAuth.swift`,
`performDeviceCodeLogin`): `POST /v1/device/code`, print the verification URL
and one-time code, open the browser, poll `POST /v1/device/token` until you
approve. The token is saved to `~/.darkbloom/auth_token`. This link is what
makes the machine "yours" for [self-route](./self-route.md) and credits earnings
to your account. `darkbloom start` offers this step inline if you skip it.

### 5. Start serving

```bash
darkbloom start
```

`Start` (`provider-swift/Sources/darkbloom/StartCommand.swift`,
`provider-swift/Sources/darkbloom/StartCommand+Daemon.swift`) prints the
Terms-of-Service notice (starting is acceptance), runs preflight, offers inline
login, shows the model picker unless `--model <id>` (repeatable) or `--all` is
given, then writes `~/Library/LaunchAgents/io.darkbloom.provider.plist`
(`RunAtLoad = true`, `KeepAlive = false`;
`provider-swift/Sources/ProviderCore/Service/LaunchAgent.swift`) and starts it.
With `provider.auto_restart = true` (the default) it also arms the crash-recovery
watchdog `io.darkbloom.watchdog`
(`provider-swift/Sources/ProviderCore/Service/WatchdogAgent.swift`). The service
starts again at every login.

### 6. Enrol for public traffic

```bash
darkbloom enroll
```

A freshly started provider is `self_signed`; the coordinator sends public
requests only to `hardware`-level machines, which requires MDM enrolment of
this Mac. What the command does, how long the upgrade takes and how to read the
result are in [Reaching and keeping `hardware` trust](./attestation.md#steps).
Until then only your own [self-route](./self-route.md) requests reach the
machine.

## Verify

```bash
darkbloom status            # config, hardware, live daemon state, trust level
darkbloom doctor            # ✓ daemon connected, ✓ trust level, ✓ account link
darkbloom logs --last 1h    # unified logs, subsystem dev.darkbloom.provider
```

`status` (`provider-swift/Sources/darkbloom/StatusCommand.swift`) and `doctor`
read the daemon's snapshot `~/.darkbloom/daemon-state.json`; its refresh period
and the stale threshold are in
[troubleshooting → Doctor checks](./troubleshooting.md#doctor-checks). A stale
snapshot is reported as such
(`provider-swift/Sources/ProviderCore/Service/DaemonStateFile.swift`, `isStale`).

The provider is earning once `doctor` shows the trust level the coordinator
requires for routing; see [attestation](./attestation.md) for the levels and how
to reach `hardware` trust.

## Configuration

The config file is optional: `~/.config/darkbloom/provider.toml`
(`provider-swift/Sources/ProviderCore/Config/ProviderConfig.swift`,
`defaultConfigPath`). Without it every key takes the code default; `darkbloom
autoupdate` and `darkbloom beta` write it when they change a value. The keys
that matter on day one, with an omitted key taking its code default:

```toml
[provider]
# memory_reserve_gb, auto_update, auto_restart, update_jitter_seconds

[backend]
enabled_models = []          # empty = every local model the box can serve
# idle_timeout_mins (0 disables unloading), max_model_slots, engine_v2_max_concurrent

[coordinator]
private_only = false         # true = serve only your own self-route traffic
# url, heartbeat_interval_secs
```

Every key and its default is in the
[`provider.toml` table](./cli-reference.md#providertoml-keys-read-by-the-cli);
every environment variable is in
[`reference/configuration.md`](../reference/configuration.md).

## Earning

Prices, the platform fee and payout rules are defined once, in
[`architecture/billing.md`](../architecture/billing.md#invariants). There is no
`darkbloom earnings` command; usage and payouts are in the console at
`https://console.darkbloom.dev/providers/earnings` (page described in
[`architecture/components/console-ui.md`](../architecture/components/console-ui.md)).
Requests you
send to your own machine through [self-route](./self-route.md) or
[direct mode](./direct-mode.md) are not billed.

## Related

- [Installation](./installation.md) — installer steps, update, uninstall.
- [CLI reference](./cli-reference.md) — every command and flag.
- [Attestation](./attestation.md) — trust levels and enrollment.
- [Troubleshooting](./troubleshooting.md) — symptom → check → fix.
- [Hardware requirements](./hardware-requirements.md).
