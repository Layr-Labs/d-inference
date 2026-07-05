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
hardened runtime, binary hash, MDM enrollment) and fetches the coordinator's
view of your provider from `/v1/providers/attestation`
(`provider-swift/Sources/darkbloom/DoctorCommand.swift`).

`darkbloom status` prints config, hardware, schedule, and live daemon state
including the coordinator's current trust verdict
(`provider-swift/Sources/darkbloom/StatusCommand.swift`).

## Configuration

The canonical config file is:

```text
~/.config/darkbloom/provider.toml
```

It is created automatically on first start. The TOML schema is defined in
`provider-swift/Sources/ProviderCore/Config/ProviderConfig.swift`.

```toml
[provider]
name = "darkbloom-mac16-1"
memory_reserve_gb = 4
auto_update = true
auto_restart = true

[backend]
model = ""
continuous_batching = true
enabled_models = []
idle_timeout_mins = 60
max_model_slots = 3
kv_quant = false

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
- `backend.kv_quant` — opt-in beta: 8-bit KV cache for GPT-OSS / Gemma 4 (~1.9x
  more concurrent context). Off by default. Manage it with `darkbloom beta` — see
  [Beta Features](beta-features.md).
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
