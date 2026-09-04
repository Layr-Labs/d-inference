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

`darkbloom start` (`provider-swift/Sources/darkbloom/StartCommand.swift`) runs
preflight checks (SIP, debugger, GPU, memory), offers to link your account if
you are not logged in, shows an interactive model picker, asks whether models
should stay loaded while idle (`Always ready`) or be unloaded after 60 minutes
without requests and reloaded on demand (`Free when idle`, the default; or a
custom window), then installs and starts a `launchd` user agent.

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
  (`provider-swift/Sources/darkbloom/StartCommand.swift:84-91` and
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
- `config_version` — schema version of this file, written automatically on
  first start after upgrading. It only dates the file, so the provider can
  tell a value the previous release GENERATED from one you chose. Leave it
  alone; deleting it re-runs the one-time upgrade migrations below.
- `backend.engine_v2_max_concurrent` — box-wide concurrent-request cap per
  engine slot (default **4** as of v0.8.1, clamped to `[1, 8]`). v0.8.0 raised
  it to 8 because PagedAttention made the batch curve keep climbing (paged
  gains 1.27x from B=4 to B=8, contiguous only 1.069x); v0.8.1 reverts the
  paged default, so the raise goes back with it. 4 is the knee of the measured
  contiguous curve — aggregate throughput is flat from B=4 to B=8 and collapses
  below it, while per-request decode is aggregate/B and so improves as the
  batch shrinks, which is what a time-to-first-token deadline is scored on.
  A `provider.toml` written by v0.8.0 carries an explicit `= 8` that release
  generated; because that is **indistinguishable from a deliberate 8**, first
  start after upgrading changes it to 4 once, logs a warning saying so, and
  bumps `config_version` to 2. If you want 8, set it again afterwards — from
  then on it is honoured. The `[1, 8]` upper bound is unchanged, so 8 stays
  available both box-wide and per-model, which is what a box running
  `engine_v2_kv_backend = "paged"` wants.
- `backend.engine_v2_kv_backend` — KV-cache backend for the inference engine:
  `"auto"` (default — resolves **CONTIGUOUS** as of v0.8.1, reverting the
  v0.8.0 paged default; grep `case .auto: resolvedKind` in
  `provider-swift/Sources/ProviderCore/Inference/EngineV2Factory+Production.swift`
  for the argument). Paged sizes its KV pool from a physical-capacity policy
  rather than the slot's logical grant, which cost the fleet roughly 10x its
  KV and produced widespread admission failures; contiguous gets the whole
  grant. Set `"paged"` to opt a box back in — note that an explicit `"paged"`
  on a box that cannot build it **refuses the load (503)** rather than
  degrading, which is the point of naming it. There is no env var that turns
  paged on: `DARKBLOOM_CBV2_PAGED_KV=0` is a kill switch and only forces
  contiguous. **gemma-4 greedy outputs differ between the two backends** —
  paged is measurably closer to an fp32 reference, but the text is not
  identical. A resolved-contiguous slot also runs with the SSD prefix cache
  OFF: adoption is not bit-exact on contiguous for the served models, so the
  cache is not constructed there.
  Vision (VLM) models are NOT forced to contiguous. The
  VLM veto in `EngineV2KVBackendPolicy.applySlotVetoes`
  (`guard isVLM, !pagedHonorsSpanMasks`, `provider-swift/Sources/ProviderCore/Inference/EngineV2KVBackendPolicy.swift:202-210`)
  fires only when the paged cache does not affirm multimodal span masks, and
  `PagedLayerCache.honorsSpanMaskContextsByConstruction` is `true`
  (`libs/mlx-swift-lm/Libraries/MLXLMCommon/ContinuousBatchingV2/Paged/PagedLayerCache.swift:994`),
  which is what the slot factory passes
  (`provider-swift/Sources/ProviderCore/Inference/EngineV2SlotFactory.swift:301-304`),
  so the veto is inert: an explicitly paged VLM slot can use paged like any
  other model. Under `"auto"`, every slot resolves contiguous as described
  above.
  The concurrency cap above matters: paged only
  overtakes contiguous above ~5 concurrent rows, so pairing
  `engine_v2_kv_backend = "paged"` with a low `engine_v2_max_concurrent`
  (say 2) buys you paged at a small loss, not a win. Under `"auto"`, a
  model the paged kernel cannot serve still falls back to contiguous
  automatically;
  under an explicit `"paged"` the model REFUSES to load instead, with the
  underlying reason attached:
  `EngineV2KVBackendPolicy.degradesPagedFailure`
  (`selection != .paged`, `provider-swift/Sources/ProviderCore/Inference/EngineV2KVBackendPolicy.swift:229-233`)
  returns `false` for — and only for — an explicit `.paged` selection, so a
  paged fleet can never silently serve contiguous. That refusal surfaces as
  a 503 and the coordinator reroutes: the engine-construction catch wraps it
  as `InferenceError.modelLoadFailed`
  (`provider-swift/Sources/ProviderCore/ProviderLoop+ModelLoading.swift:543-549`),
  `loadErrorStatusCode` maps that case to 503
  (`same file:979-1007`), and the coordinator counts a 503 as
  `capacityRejection` — no reputation strike — then cools the load-rejecting
  pair so retries skip it (`coordinator/api/provider.go:2332`, cool-down at
  `:2343-2351`).
  Per-model overrides: `engine_v2_kv_backend_by_model` (TOML table of model
  id → value). Fleet kill switch: launch with `DARKBLOOM_CBV2_PAGED_KV=0`
  (survives restarts — it is forwarded into the launchd service
  environment); the kill switch always degrades and never refuses, so
  pulling it on a paged fleet gives you contiguous service, not failed
  loads. An explicit paged model PLANS a separately capped physical pool
  derived from useful concurrent context demand, live memory, machine size,
  and Metal buffer limits, but does not commit it eagerly: slabs become
  MLX-resident lazily, at first admission
  (`PagedKVPhysicalCapacityPolicy.slabCommitment = .atFirstAdmission`,
  `provider-swift/Sources/ProviderCore/Inference/PagedKVPhysicalCapacityPolicy.swift:58`),
  so an admitted-but-idle pool contributes 0 bytes of idle residency
  (`PagedKVPhysicalCapacityPolicy.idleResidencyBytes`, same file:101). It
  never preallocates the full logical admission grant.
- `coordinator.private_only` — serve only your own self-route traffic; never
  join the public fleet.

## Earnings and billing

During the public alpha the platform fee is 0%, so providers keep 100% of the
per-token revenue (`coordinator/payments/pricing.go:39-43`).

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
