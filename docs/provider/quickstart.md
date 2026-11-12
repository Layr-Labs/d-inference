# Provider quickstart

> Last updated: 2026-11-11

From a fresh Apple Silicon Mac to OpenCode or Hermes on this Mac's own models;
then, if you want, to earning on the Darkbloom network. For anyone setting up a
Mac.

```text
curl -fsSL https://api.darkbloom.dev/install.sh | bash
exec $SHELL -l                       # or open a new Terminal window
darkbloom --opencode                 # or --hermes
  your models (downloads offered) → memory when idle → serves Darkbloom and your local API
  Serving Darkbloom and your local API at http://127.0.0.1:8001/v1 (`darkbloom local` for local only).
  ⠙ Loading Gemma 4 26B before setting up OpenCode… 42s
  ✓ OpenCode can use Darkbloom
opencode                             # then /models → Darkbloom
```

Two Macs: run `darkbloom cluster` on each, then `darkbloom --opencode` on
either Mac.

## Prerequisites

- A Mac that meets [hardware requirements](./hardware-requirements.md#minimum-requirements).
  `darkbloom start` refuses machines below the RAM floor or without a
  Metal GPU (`provider-swift/Sources/darkbloom/Start/StartCommand+Preflight.swift`,
  `Start.runPreflightChecks`; `provider-swift/Sources/darkbloom/Start/StartCommand.swift`,
  `Start.prepareServeRuntime`).
- macOS 27 or later: the installer refuses a fresh install on older macOS and
  asks you to update first ([installation](./installation.md)).
- OpenCode 2, or Hermes Agent v0.20.2 or later, already installed: Darkbloom
  never installs them.
- For **Only me**, nothing else: no account. To serve the Darkbloom network, a
  Darkbloom account for `darkbloom login` (the login flow prints the URL to
  open), and outbound HTTPS (443) to `api.darkbloom.dev`: the provider is an
  outbound-only WebSocket client to `wss://api.darkbloom.dev/ws/provider`
  (`provider-swift/Sources/ProviderCore/Config/ProviderConfig.swift`,
  `CoordinatorSettings.url`).

## Steps

### 1. Install

```bash
curl -fsSL https://api.darkbloom.dev/install.sh | bash
exec $SHELL -l        # or open a new Terminal window, so your shell finds darkbloom
```

The installer puts `darkbloom` on your `PATH` in `~/.zshrc`, which only a new
shell reads. What the script verifies and writes is in
[installation](./installation.md).

### 2. Start, and set up OpenCode

```bash
darkbloom --opencode            # --hermes for Hermes; both flags for both
```

It runs `darkbloom start`, then sets OpenCode up. `start` prints the
Terms-of-Service notice (starting is acceptance) and asks nothing about how
this Mac serves: a first start serves **Both**, Darkbloom's requests, which
earn, and a local API for your tools, and Darkbloom keeps serving while you use
the Mac. It says so in one line and saves the choice. To serve only you, run
`darkbloom local` (or add `--local`); to pause Darkbloom while you use the Mac,
add `--me-first`; for the network alone, `darkbloom start --network`, which
gives your tools no address on this Mac.

What each choice runs, costs and earns is in
[Use your Mac yourself, first](./local-first.md#start). With **Both** (and
**Only me**, without the first question), `start` then checks the Mac and goes
on
(`provider-swift/Sources/darkbloom/Start/StartCommand.swift`,
`provider-swift/Sources/darkbloom/Start/StartCommand+Daemon.swift`):

1. **One optional question:** when this Mac isn't linked to an account, it
   offers to link it (`Link account? [Y/n]`). Answer `n` to leave it for
   [step 4](#4-earn-on-the-darkbloom-network). The experimental Autopilot
   question comes only with **Darkbloom network** (step 4).
2. **Your models:** a picker lists the models on this Mac and in Darkbloom's
   catalog, and downloads the ones you pick from `https://models.darkbloom.ai`
   (`provider-swift/Sources/ProviderCore/Models/ModelDownloader.swift`,
   `defaultR2CDNURL`). It opens with your last selection still on this Mac
   selected, else the largest downloaded model that fits with room to spare,
   else the smallest downloaded one that fits; never one it would download
   (`Start.pickerPreselection`). Check which ones are selected before you
   press Enter.
   `--model <id>` skips the picker. A Mac with no model it can serve ends with
   ``No model to serve yet. See them: `darkbloom models catalog`. Get one:
   `darkbloom models download <id>`, then `darkbloom start`.``
3. **Memory when idle:** keep models loaded (`Always ready`), or unload them
   after 60 minutes without requests and load them again on demand
   (`Free when idle`, the default), or another window. `darkbloom idle`
   changes it later. Selected models start loading right away
   ([startup preload](./cli-reference.md#darkbloom-start)).
4. **In the background, until `darkbloom stop`:** it writes
   `~/Library/LaunchAgents/io.darkbloom.provider.plist` (`RunAtLoad = true`,
   `KeepAlive = false`; `provider-swift/Sources/ProviderCore/Service/LaunchAgent.swift`)
   and starts it, so it starts again at every login. With
   `provider.auto_restart = true` (the default) it also arms the crash-recovery
   watchdog `io.darkbloom.watchdog`
   (`provider-swift/Sources/ProviderCore/Service/WatchdogAgent.swift`).
5. **OpenCode:** once this Mac's local API answers (it waits up to 30 seconds)
   and the models it started with are loaded (one live line,
   `⠙ Loading Gemma 4 26B before setting up OpenCode… 42s`, for up to 10
   minutes; Ctrl-C stops it and writes nothing), it adds a `darkbloom` provider
   to OpenCode's config with the limits this Mac gives each model, keeps a
   backup and prints the one-line undo. OpenCode's config never holds your key:
   OpenCode reads it from Darkbloom's key file
   ([Use it from OpenCode or Hermes](./local-first.md#use-it-from-opencode-or-hermes)).

With **Only me**, the background service runs `darkbloom start --foreground
--local` on this Mac's port, and OpenCode is set up the same way once it
listens: it listens once its models are loaded, so the start waits up to
`[backend] startup_preload_timeout_secs` (120) more. `darkbloom start --local
--here` serves Only me in the Terminal window instead, until you close it.

### 3. Use it

```bash
opencode
```

In OpenCode, `/models` → **Darkbloom**, then pick a model; OpenCode remembers
the pick. If neither your OpenCode config sets a default model nor OpenCode
remembers one you picked, Darkbloom's first model becomes the default for new
sessions; otherwise yours stays. The start says which on a line of its own
(`New OpenCode sessions now use Darkbloom's …`, `Your default stays …` or
`Pick Darkbloom once with /models; OpenCode remembers it.`).
With `--hermes`, Darkbloom is Hermes' main model: run `hermes`. Any other OpenAI
client: `darkbloom local` prints the address, the key and a `curl` to try
([the local API](./direct-mode.md)).

- **Switch later:** `darkbloom local` serves only you (where Darkbloom serves, it
  asks first in a terminal); `darkbloom start --network` or `--me-first` saves
  another choice ([switch](./local-first.md#switch)).
- **Two Macs:** run `darkbloom cluster` on each Mac to pair them (the pair
  serves through Darkbloom with your local API beside it; `darkbloom cluster
  local` serves it for you alone), then `darkbloom --opencode` on either Mac
  ([Two Macs as one provider](./two-mac-cluster.md)). The wait for your model
  and the line when a tool points elsewhere are for one Mac for now: on a pair
  that is still loading, run it again once the pair serves.

<!-- pending LS-2: a one-step switch that keeps the models, the address and the key. -->

### 4. Earn on the Darkbloom network

Only for **Both** and **Darkbloom network**: **Only me** never contacts
Darkbloom, so skip to [Verify](#verify).

1. **Link your account**, unless `start` already did:

   ```bash
   darkbloom login
   darkbloom restart     # the running provider picks the account up when it starts
   ```

   `Login` (`provider-swift/Sources/darkbloom/LoginCommand.swift`) runs the RFC 8628
   device-code flow (`provider-swift/Sources/ProviderCore/Auth/DeviceAuth.swift`,
   `performDeviceCodeLogin`): `POST /v1/device/code`, print the verification URL
   and one-time code, open the browser, poll `POST /v1/device/token` until you
   approve. The token is saved to `~/.darkbloom/auth_token`. This link is what
   makes the machine "yours" for [self-route](./self-route.md) and credits
   earnings to your account.

2. **Confirm verification.** On **macOS 27 or later**, the installer and
   `darkbloom enroll` skip MDM profile download and System Settings: App Attest
   replaces new Darkbloom MDM enrollment. Run `darkbloom status` and
   `darkbloom doctor` to check App Attest approval. Serving requires a
   qualified signed provider and an enabled coordinator; pending or unavailable
   approval does not trigger MDM fallback. See [current platform serving authorization](https://github.com/Layr-Labs/darkbloom-platform/blob/master/docs/reference/provider-authorization.md).

   On **older macOS**, upgrade to macOS 27 to avoid MDM, or finish the legacy
   setup:

   ```bash
   darkbloom enroll
   ```

   Approve the Darkbloom profile in System Settings and follow the
   [legacy verification steps](./attestation.md#steps). Darkbloom MDM will be
   deactivated soon. Keep any employer management profile. Existing Darkbloom
   profiles should remain installed until `darkbloom unenroll` approves App Attest
   migration; choosing full exit instead stops the provider.

3. **Autopilot (experimental, optional).** Autopilot is for the Darkbloom
   network, so `start` asks whether to join it only with **Darkbloom network**;
   the answer defaults to No. **Both** never asks and keeps your
   saved answer: `darkbloom autopilot enable` enrolls it. **Only me** has no
   Autopilot: there, `darkbloom autopilot enable` says
   `Autopilot requires a network provider. Nothing was saved.`
   Yes records consent for the default shadow rollout, **not active
   residency control**. It skips the picker and discovers/verifies all eligible
   already-downloaded active network models, excluding arbitrary
   local/off-catalog, retired, ineligible or unverified builds. Enrollment
   downloads nothing; if none qualify, it fails before replacing the daemon.
   Saved model, preload, idle and other preferences are preserved, and ordinary
   startup/serving continues. Check `darkbloom autopilot status` for the
   recorded inventory and `shadow` (not activated) phase. Live rollout later
   chooses among cached models for utilization, not guaranteed earnings. Once
   enrolled, every verified catalog build you download is available to
   Autopilot, and Autopilot may download catalog models on your behalf. Limit
   that with `darkbloom autopilot downloads enable --max-storage-gb N
   --max-models N`, or turn it off with `darkbloom autopilot downloads disable`;
   it never deletes files
   ([Autopilot](../architecture/model-autopilot.md#downloads-on-the-operators-behalf)).
   Models you download later join Autopilot's set when the provider next
   starts, with no new consent step; `darkbloom autopilot models` refreshes the
   saved selection itself. See [Autopilot CLI](./cli-reference.md#darkbloom-autopilot).

The provider becomes eligible for public traffic after the coordinator grants
current App Attest authorization or complete legacy verification. Check
recorded earnings in the dashboard; connection or setup completion alone does
not prove that the provider is serving or earning. See [attestation](./attestation.md).

## Verify

```bash
darkbloom status            # how this Mac serves, live daemon state, trust level
darkbloom local             # the local API's address and key (Both or Only me; starts Only me where nothing serves)
darkbloom doctor            # the local API and your tools first; with the network also ✓ trust level, ✓ account link
darkbloom logs --last 1h    # unified logs, subsystem dev.darkbloom.provider
```

`status` (`provider-swift/Sources/darkbloom/StatusCommand.swift`) and `doctor`
read the daemon's snapshot `~/.darkbloom/daemon-state.json`; its refresh period
and the stale threshold are in
[troubleshooting → Doctor checks](./troubleshooting.md#doctor-checks). A stale
snapshot is reported as such
(`provider-swift/Sources/ProviderCore/Service/DaemonStateFile.swift`, `isStale`).
`doctor` also checks hardware, Metal, SIP, MDM enrollment and the coordinator;
lines marked `✗` are failures. **Only me** needs none of its network checks:
the account link, verification and the coordinator.

## Configuration

The config file is optional: `~/.config/darkbloom/provider.toml`
(`provider-swift/Sources/ProviderCore/Config/ProviderConfig.swift`,
`defaultConfigPath`). Without it every key takes the code default; `darkbloom
autoupdate` and `darkbloom beta` write it when they change a value, and
`darkbloom start` writes how this Mac serves in `[local]`
([configuration](../reference/configuration.md#local-first-use-local)). The keys
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
A green `doctor` and live inference rows do not prove a `model=base_reward`
grant. [Check a missing base reward](base-rewards.md).

A request this Mac's local API serves itself is never billed, and self-route
traffic to your own machine is always free; see [self-route](./self-route.md).

## Next steps

- [Use your Mac yourself, first](./local-first.md) — the three choices,
  switching, and OpenCode or Hermes in detail.
- [The local API](./direct-mode.md) — its address, key, routes and the local
  router, for any OpenAI client.
- [Installation details](./installation.md) — manual install, updates, uninstall.
- [Hardware requirements](./hardware-requirements.md) — specs, memory model,
  thermal guidance.
- [CLI reference](./cli-reference.md) — all commands and flags.
- [Attestation](./attestation.md) — trust levels, Secure Enclave, MDM/MDA,
  APNs code-identity.
- [Troubleshooting](./troubleshooting.md) — common failures and fixes.
