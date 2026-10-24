# Provider quickstart

> Last updated: 2026-10-23

From a fresh Apple Silicon Mac to a provider that is registered with the
coordinator, linked to your account and serving. For operators; install, check,
log in, pick models, start, then confirm serving authorization. New providers
need macOS 27 or later: the installer refuses a fresh install on older macOS and
asks you to update first. macOS 27 or later uses App Attest without new
Darkbloom MDM enrollment. Darkbloom MDM will be
deactivated soon; upgrade to macOS 27 to avoid the legacy enrollment step.

## Prerequisites

- A Mac that meets [hardware requirements](./hardware-requirements.md#minimum-requirements).
  `darkbloom start` refuses machines below the RAM floor or without a
  Metal GPU (`provider-swift/Sources/darkbloom/Start/StartCommand+Preflight.swift`,
  `Start.runPreflightChecks`; `provider-swift/Sources/darkbloom/Start/StartCommand.swift`,
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

Ordinary non-enrolled `darkbloom start` (`provider-swift/Sources/darkbloom/Start/StartCommand.swift`) runs
preflight checks (SIP, debugger, GPU, memory), offers to link your account if
you are not logged in, shows an interactive model picker, asks whether models
should stay loaded while idle (`Always ready`) or be unloaded after 60 minutes
without requests and reloaded on demand (`Free when idle`, the default; or a
custom window), then installs and starts a `launchd` user agent.
Every idle-memory choice starts loading selected models before the daemon
registers with the coordinator, subject to the startup timeout, model-slot
limit and available memory ([startup preload details](./cli-reference.md#darkbloom-start)).

`darkbloom models download` (`provider-swift/Sources/darkbloom/ModelsCommand.swift`)
resolves the catalog entry and fetches from `https://models.darkbloom.ai`
(`provider-swift/Sources/ProviderCore/Models/ModelDownloader.swift`,
`defaultR2CDNURL`). `darkbloom start` also offers an interactive catalog picker
when nothing is downloaded yet, so this step can be skipped for ordinary serving.
Enrollment needs at least one downloaded network model and downloads nothing
itself. Once enrolled, every verified catalog build
you download is available to Autopilot, and Autopilot may download catalog
models on your behalf. Limit that with `darkbloom autopilot downloads enable
--max-storage-gb N --max-models N`, or turn it off with `darkbloom autopilot
downloads disable`; it never deletes files
([Autopilot](../architecture/model-autopilot.md#downloads-on-the-operators-behalf)).

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

`Start` (`provider-swift/Sources/darkbloom/Start/StartCommand.swift`,
`provider-swift/Sources/darkbloom/Start/StartCommand+Daemon.swift`) prints the
Terms-of-Service notice (starting is acceptance), runs preflight, offers inline
login, uses the ordinary model picker unless explicit selection or Autopilot
enrollment bypasses it, then writes `~/Library/LaunchAgents/io.darkbloom.provider.plist`
(`RunAtLoad = true`, `KeepAlive = false`;
`provider-swift/Sources/ProviderCore/Service/LaunchAgent.swift`) and starts it.
With `provider.auto_restart = true` (the default) it also arms the crash-recovery
watchdog `io.darkbloom.watchdog`
(`provider-swift/Sources/ProviderCore/Service/WatchdogAgent.swift`). The service
starts again at every login.

The experimental Autopilot interest prompt defaults to No. Yes records consent
for the default shadow rollout, **not active residency control**. It skips the
picker and discovers/verifies all eligible already-downloaded active network
models, excluding arbitrary local/off-catalog, retired, ineligible or unverified
builds. Enrollment downloads nothing; if none qualify, it fails before replacing
the daemon. Saved model, preload, idle and other preferences are preserved, and
ordinary startup/serving continues. Check `darkbloom autopilot status` for the
recorded inventory and `shadow` (not activated) phase. Live rollout later chooses
among cached models for utilization, not guaranteed earnings. Models you download
later join Autopilot's set when the provider next starts, with no new consent
step; `darkbloom autopilot models` refreshes the saved selection itself. See
[Autopilot CLI](./cli-reference.md#darkbloom-autopilot).

### 6. Confirm verification

On **macOS 27 or later**, the installer and `darkbloom enroll` skip MDM profile
download and System Settings. Run `darkbloom status` and `darkbloom doctor` to
check App Attest approval. Serving requires a qualified signed provider and an
enabled coordinator; pending or unavailable approval does not trigger MDM
fallback. See [current platform serving authorization](https://github.com/Layr-Labs/darkbloom-platform/blob/master/docs/reference/provider-authorization.md).

On **older macOS**, upgrade to macOS 27 to avoid MDM, or finish the legacy setup:

```bash
darkbloom enroll
```

Approve the Darkbloom profile in System Settings and follow the
[legacy verification steps](./attestation.md#steps). Darkbloom MDM will be
deactivated soon. Keep any employer management profile. Existing Darkbloom
profiles should remain installed until `darkbloom unenroll` approves App Attest
migration; choosing full exit instead stops the provider.

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

The provider becomes eligible for public traffic after the coordinator grants
current App Attest authorization or complete legacy verification. Check recorded
earnings in the dashboard; connection or setup completion alone does not prove
that the provider is serving or earning. See [attestation](./attestation.md).

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

- `gemma_optimizations.prefill_layer18` — default ON, including when an older
  config omits the section or key. Set to `false` and restart to restore legacy
  one-final-submission Gemma prefill. The default and missing-key decode are in
  `provider-swift/Sources/ProviderCore/Config/GemmaOptimizationSettings.swift:16-34`;
  the missing-section fallback is in
  `provider-swift/Sources/ProviderCore/Config/ProviderConfig.swift:397-400`.
- `gemma_optimizations.weighted_r1` — default ON, including when omitted. This
  is one atomic production control for weighted unsort and safe R1; the two
  paths cannot be configured independently
  (`provider-swift/Sources/ProviderCore/Config/GemmaOptimizationSettings.swift:10-18`,
  coupled projection at
  `provider-swift/Sources/ProviderCore/Config/GemmaOptimizationEnvironment.swift:14-22`).
- Provider TOML is authoritative for both controls. Changes take effect at
  process restart; after setting either key to `false`, run `darkbloom restart`
  to activate the rollback. The start path projects config before Metal access
  (`provider-swift/Sources/darkbloom/Start/StartCommand.swift:84-91` and
  `provider-swift/Sources/darkbloom/ServeRuntimePreparer.swift:24-35`), while
  `darkbloom beta` durably locks, reloads, and saves the selected value before
  printing the restart boundary
  (`provider-swift/Sources/darkbloom/BetaCommand.swift:201-235`).
- `backend.enabled_models` — if non-empty, only these models are advertised.
- `backend.idle_timeout_mins` — the idle-memory policy: minutes without
  requests before a model is unloaded and its memory returned to the Mac
  (default 60; reloaded on demand with a ~10-30 s cold start), or `0` to keep
  models loaded for instant responses. `darkbloom start` asks for this
  interactively; change it later with `darkbloom idle keep-loaded` /
  `darkbloom idle unload-after <minutes>`.
- `backend.max_model_slots` — maximum resident models at once (default 3).
- `backend.engine_v2_max_concurrent` configures the per-engine request cap.
  Automatic limits and explicit per-model overrides follow the
  [concurrency settings](./cli-reference.md#providertoml-keys-read-by-the-cli)
  and their runtime qualification, architecture and memory bounds.
- `backend.engine_v2_kv_backend` configures the serving layout. Follow the
  [backend and precision settings](./cli-reference.md#providertoml-keys-read-by-the-cli)
  for allowed values, per-model precedence and precision-dependent fallback
  or refusal. Check `darkbloom status` and `darkbloom doctor` for the actual
  backend and reason rather than assuming `"auto"` proves paged service.
  Checkpoint eligibility and defaults are separate; see the
  [per-family reuse gates](../reference/ssd-kv-cache.md#per-family-reuse-capability)
  and [cache controls](../reference/configuration.md#ssd-prefix-cache).
  A paged model starts with empty segmented storage under
  its admitted KV grant. Pages are reserved and allocated as requests need
  them; changing the grant does not preallocate or free live backing. See
  [KV slot grants](../architecture/hardware-support.md#kv-slot-grants) for
  co-resident shrink/regrow and the unchanged memory admission gates.
- `coordinator.private_only` — serve only your own self-route traffic; never
  join the public fleet.

The [Qwen-first rollout decision](https://github.com/Layr-Labs/d-inference/blob/4230fa03ddbc84e34e2de150c89431744d6f1c55/docs/design/qwen-first-paged-ssd-rollout.md)
preserves historical qualification evidence, not current backend selection.

## Earnings and billing

Current backend behavior is owned by the
[platform's latest default branch](https://github.com/Layr-Labs/darkbloom-platform/tree/master);
the immutable pricing citation below is evidence, not current source or proof
of deployed pricing.

During the public alpha the platform fee is 0%, so providers keep 100% of the
per-token revenue ([coordinator/payments/pricing.go:39-43](https://github.com/Layr-Labs/darkbloom-platform/blob/48a198c71a2d30feec5597bacf1101120f7f955d/coordinator/payments/pricing.go)).

There is no `darkbloom earnings` CLI command. View payouts, Stripe Connect
status, and usage in the console at `https://console.darkbloom.dev`.

Self-route traffic to your own machine is always free; see
[self-route](./self-route.md).

## Next steps

- [Installation details](./installation.md) — manual install, updates, uninstall.
- [Hardware requirements](./hardware-requirements.md) — specs, memory model,
  thermal guidance.
- [CLI reference](./cli-reference.md) — all commands and flags.
- [Attestation](./attestation.md) — trust levels, Secure Enclave, MDM/MDA,
  APNs code-identity.
- [Troubleshooting](./troubleshooting.md) — common failures and fixes.
- [Direct mode](./direct-mode.md) — use your Mac locally without the
  coordinator relay.
