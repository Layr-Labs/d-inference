# Provider Quickstart

Run a Darkbloom inference node on your Apple Silicon Mac and earn credits for
serving the public fleet, or use the same node for your own free inference via
[self-route](./self-route.md) / [direct mode](./direct-mode.md).

## Requirements

| Requirement | Minimum | Recommended |
|-------------|---------|-------------|
| **Chip** | Apple Silicon (M1 or later) | M1 Pro/Max/Ultra or newer |
| **RAM** | 8 GB | 32 GB+ for multi-model or large weights |
| **macOS** | 14 (Sonoma) | Latest stable release |
| **Disk** | 50 GB free | 100 GB+ free |
| **Network** | Outbound HTTPS (port 443) | Low-latency path to `api.darkbloom.dev` |

The installer enforces macOS + Apple Silicon up front
(`scripts/install.sh:41-48`). The start path rejects CPU-only execution via
`GPUEnforcement.requireMetal()` (`provider-swift/Sources/darkbloom/StartCommand.swift:80-85`)
and rejects machines with less than 8 GB RAM
(`provider-swift/Sources/darkbloom/StartCommand.swift:444-447`).

## Install

```bash
curl -fsSL https://api.darkbloom.dev/install.sh | bash
```

The installer (`scripts/install.sh`):

1. Fetches the latest signed release from `/v1/releases/latest`.
2. Downloads the provider bundle to `~/.darkbloom`.
3. Verifies the bundle SHA-256, the binary SHA-256, and the `mlx.metallib` SHA-256
   against the coordinator's release record.
4. Verifies the Apple Developer ID code signature.
5. Adds `~/.darkbloom/bin` to your `PATH`.
6. Provisions the Secure Enclave identity helper (`darkbloom-enclave`).
7. Offers to install the MDM enrollment profile for hardware-trust attestation.

No `sudo` is required for normal operation.

## First run

```bash
# Start as a background launchd service (interactive picker if no models are set)
darkbloom start

# Or run in the foreground
darkbloom start --foreground

# Or serve only yourself on localhost, with no coordinator
darkbloom start --local
```

`darkbloom start` (`provider-swift/Sources/darkbloom/StartCommand.swift`) runs
preflight checks (SIP, debugger, GPU, memory), offers to link your account if
you are not logged in, shows an interactive model picker, then installs and
starts a `launchd` user agent.

## Link your account

Earnings and self-route ownership require the provider to be linked to a
Darkbloom account:

```bash
darkbloom login
```

This uses the RFC 8628 device-code flow
(`provider-swift/Sources/darkbloom/LoginCommand.swift`). The CLI prints a URL
and a one-time code; after you authorize it in the console, the provider stores
an auth token locally.

## Verify it is working

```bash
# Local diagnostics
darkbloom doctor

# Running daemon status
darkbloom status

# View recent logs
darkbloom logs --last 1h
```

`darkbloom doctor` runs local checks (hardware, Metal, SIP, Secure Boot,
hardened runtime, binary hash, MDM enrollment), verifies that each loaded
slot resolved to the KV backend the config asked for, and fetches the
coordinator's view of your provider from `/v1/providers/attestation`
(`provider-swift/Sources/darkbloom/DoctorCommand.swift`).

`darkbloom status` prints config, hardware, schedule, and live daemon state
including the coordinator's current trust verdict and, per loaded model,
the resolved KV backend and MTP posture
(`provider-swift/Sources/darkbloom/StatusCommand.swift`). Both read the
daemon's state file rather than the live engine, so both report the
snapshot's age — see `docs/provider/cli-reference.md`.

## Configuration

The canonical config file is:

```text
~/.config/darkbloom/provider.toml
```

It is created automatically on first start. The TOML schema is defined in
`provider-swift/Sources/ProviderCore/Config/ProviderConfig.swift`.

```toml
config_version = 1

[provider]
name = "darkbloom-mac16-1"
memory_reserve_gb = 4
auto_update = true
auto_restart = true

[backend]
model = ""
enabled_models = []
idle_timeout_mins = 60
max_model_slots = 3

[coordinator]
url = "wss://api.darkbloom.dev/ws/provider"
heartbeat_interval_secs = 5
private_only = false

[[schedule.windows]]
days = ["mon", "tue", "wed", "thu", "fri"]
start = "22:00"
end = "08:00"
```

- `backend.enabled_models` — if non-empty, only these models are advertised.
- `backend.idle_timeout_mins` — minutes of inactivity before an idle model is
  unloaded (default 60; 0 disables eviction).
- `backend.max_model_slots` — maximum resident models at once (default 3).
- `config_version` — schema version of this file, written automatically on
  first start after upgrading. It only dates the file, so the provider can
  tell a value the previous release GENERATED from one you chose. Leave it
  alone; deleting it re-runs the one-time upgrade migrations below.
- `backend.engine_v2_max_concurrent` — box-wide concurrent-request cap per
  engine slot (default 8 as of v0.8.0, clamped to `[1, 8]`). Raised from 4
  in v0.8.0 because B=8 is the better operating point on either KV backend
  (contiguous gains ~1.07x from B=4 to B=8). A `provider.toml` written
  before v0.8.0 carries an
  explicit `= 4` that the old release generated; because that is
  indistinguishable from a deliberate 4, first start after upgrading raises
  it to 8 once, logs a warning saying so, and stamps `config_version`. If
  you want 4, set it again afterwards — from then on it is honoured.
- `backend.engine_v2_kv_backend` — KV-cache backend for the inference engine:
  `"auto"` (default — resolves **PAGED** as of v0.8.0; grep
  `case .auto: resolvedKind` in
  `provider-swift/Sources/ProviderCore/Inference/EngineV2Factory+Production.swift`
  for the argument). On the two models the network serves, paged is the arm
  whose prefix-cache adoption is exact; contiguous is the arm that diverges
  from its own cold decode. **gemma-4 greedy outputs change under paged** —
  measurably closer to an fp32 reference, but different text for the same
  prompt. Set `"contiguous"` per slot, or
  `DARKBLOOM_CBV2_PAGED_KV=0` fleet-wide, to go back. A box that cannot
  build paged degrades to contiguous on its own and keeps serving.
  Vision (VLM) models are NOT forced to contiguous. The
  VLM veto in `EngineV2KVBackendPolicy.applySlotVetoes`
  (`guard isVLM, !pagedHonorsSpanMasks`, `provider-swift/Sources/ProviderCore/Inference/EngineV2KVBackendPolicy.swift:162`)
  fires only when the paged cache does not affirm multimodal span masks, and
  `PagedLayerCache.honorsSpanMaskContextsByConstruction` is `true`
  (`libs/mlx-swift-lm/Libraries/MLXLMCommon/ContinuousBatchingV2/Paged/PagedLayerCache.swift:982`),
  which is what the slot factory passes
  (`provider-swift/Sources/ProviderCore/Inference/EngineV2SlotFactory.swift:190`),
  so the veto is inert: a VLM slot gets paged under `"auto"` like any
  other model.
  The concurrency cap above matters: paged only
  overtakes contiguous above ~5 concurrent rows, so pairing
  `engine_v2_kv_backend = "paged"` with a low `engine_v2_max_concurrent`
  (say 2) buys you paged at a small loss, not a win. Under `"auto"`, a
  model the paged kernel cannot serve still falls back to contiguous
  automatically;
  under an explicit `"paged"` the model REFUSES to load instead, with the
  underlying reason attached:
  `EngineV2KVBackendPolicy.degradesPagedFailure`
  (`selection != .paged`, `provider-swift/Sources/ProviderCore/Inference/EngineV2KVBackendPolicy.swift:183`)
  returns `false` for — and only for — an explicit `.paged` selection, so a
  paged fleet can never silently serve contiguous. That refusal surfaces as
  a 503 and the coordinator reroutes: the engine-construction catch wraps it
  as `InferenceError.modelLoadFailed`
  (`provider-swift/Sources/ProviderCore/ProviderLoop+ModelLoading.swift:543-549`),
  `loadErrorStatusCode` maps that case to 503
  (`same file:975-983`), and the coordinator counts a 503 as
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
