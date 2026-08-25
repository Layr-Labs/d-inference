# Provider Hardware Requirements

Darkbloom providers run on Apple Silicon Macs. This page describes the minimum
and recommended specs, how memory is accounted, and how to size a machine for
the models you want to serve.

## Minimum requirements

| Component | Minimum | Notes |
|-----------|---------|-------|
| **CPU** | Apple M1 (or later) | Apple Silicon required; Intel Macs are not supported |
| **RAM** | 8 GB | Start path rejects `< 8 GB` (`provider-swift/Sources/darkbloom/StartCommand+Preflight.swift:23-27`) |
| **GPU** | Apple Silicon integrated GPU | CPU-only execution is rejected (`provider-swift/Sources/darkbloom/StartCommand.swift:128-147`) |
| **Storage** | 50 GB free | SSD required; model weights are large |
| **macOS** | 14 (Sonoma) | Newer is better; install script enforces Darwin + arm64 |
| **Network** | Outbound HTTPS to coordinator | No inbound port is required |

## New-machine admission policy

The 8 GB figure above is the CLI's absolute ability-to-start floor. The
coordinator can apply a stricter, runtime-configurable policy to **new public
provider onboarding** using unified memory, catalogued memory bandwidth, and
estimated FP16 vector throughput. Existing admitted physical machines are
grandfathered when enforcement is activated and continue to use the normal live
trust, runtime-integrity, and routing checks.

Current public requirements are available from:

```bash
curl -fsSL https://api.darkbloom.dev/v1/provider-requirements
```

Machines that are not currently eligible can register hardware interest with an
email, chip, memory, optional GPU-core count, or a custom “Others Machines”
description at `https://console.darkbloom.dev/provider-waitlist`. This is a
capacity-planning registry only; submitting does not create an email
notification subscription.

Operators manage immutable policy versions with
`scripts/admin.sh hardware-policy get|set`, and can inspect the admitted-machine
inventory with `scripts/admin.sh hardware-policy machines`. A policy should run
in `shadow` mode before `enforce`; the first enforcement activation atomically
records the trusted serials already in the fleet as grandfathered.
Enforcement requires at least one positive capacity threshold plus configured
MDM and APNs code-attestation dependencies; the coordinator refuses an unsafe
activation or startup.

The initial enforced policy is intentionally simple: **48 GiB minimum unified
memory**, with bandwidth and FP16 thresholds disabled. After deployment, an
operator activates it using the current policy version returned by `get`:

```bash
scripts/admin.sh hardware-policy get
scripts/admin.sh hardware-policy set enforce 48 0 0 <expected-version> \
  "Launch gate: 48 GiB minimum; other capacity metrics optional"
```

Bandwidth and FP16 throughput are derived from the coordinator's versioned Apple
Silicon catalog. They are not accepted from arbitrary provider values. A new
machine's actual memory and GPU-core count are included in its signed Secure
Enclave attestation and must match registration; first admission is committed
only after MDM verification, official-code attestation, and a fresh Apple Device
Attestation correlated to the live SE public-key digest.

This is an operational capacity gate, not an Apple-attested hardware-SKU proof.
MDA attests device identity and security state, but not RAM, GPU cores, or the
residency of an application key named in a caller-selected freshness nonce.
Those hardware fields remain provider measurements constrained by the
coordinator catalog. A colluding relay or deliberately modified provider can
therefore misrepresent capacity; runtime load failures, performance telemetry,
and operator revocation remain the enforcement backstops for adversarial nodes.

## Recommended configurations

| Workload | Mac | RAM | Notes |
|----------|-----|-----|-------|
| Small quantized models | Mac mini / MacBook Air M1 | 16 GB | Serves one model at a time comfortably |
| Standard text models | MacBook Pro / Mac Studio M1 Pro/Max | 32–48 GB | Can hold several slots |
| Large / multi-model | Mac Studio M1 Ultra / M2 Ultra | 64–128 GB | `max_model_slots` default is 3 |

## Memory model

A provider can keep up to `backend.max_model_slots` models resident at once
(default 3, defined in
`provider-swift/Sources/ProviderCore/Config/ProviderConfig.swift:66-74`).

### Load gate

When the provider loads a model it checks that the physical memory available
after the OS reserve and any in-flight KV-cache reservations can fit the model
weights plus a small one-request headroom. The current gate is:

```text
required_gb = weights_gb + default_load_headroom_gb
```

where `default_load_headroom_gb = 2.0`
(`provider-swift/Sources/ProviderCore/Inference/ModelLoadAdmission.swift:19-24`).

This replaces the earlier "3× weights" rule. The runtime still protects each
request via `GlobalKVCacheBudget`, which rejects a request whose KV cache would
not fit in real free memory; the load gate therefore only needs to guarantee
that at least one request can run.

The coordinator has its own admission check (`freeMemoryAdmits` in
`coordinator/registry/registry.go`) that is less conservative than the provider
load gate. A model the coordinator admits can still fail to load on the provider
if the provider's stricter gate is not met.

### Sizing guidance

| What you need | Rule of thumb |
|---------------|---------------|
| Model weights | Use the size shown by `darkbloom models catalog` |
| Load headroom | +2 GB per model |
| OS reserve | `provider.memory_reserve_gb` (default 4 GB) |
| Concurrent requests | Additional KV-cache usage; runtime-enforced |

Example: a 12 GB weights model loads when roughly `12 + 2 + 4 = 18 GB` of usable
memory is available.

## Storage

Models are cached under the Hugging Face hub directory (typically
`~/.cache/huggingface/hub`). The exact path is discovered by
`ModelScanner.defaultCacheDirectory()`
(`provider-swift/Sources/ProviderCoreFoundation/ModelScanner.swift:55`).

Plan disk space per model from the catalog output of `darkbloom models catalog`.
Logs and telemetry are small; the bundle plus `mlx.metallib` is roughly 200 MB.

## Network

| Direction | Requirement |
|-----------|-------------|
| Outbound | `wss://api.darkbloom.dev/ws/provider` and `https://api.darkbloom.dev` on port 443 |
| Inbound | None for normal provider operation |
| Local | Optional: `darkbloom start --local` or `--local-endpoint` binds a loopback/tailnet address |

Persistent WebSocket idle bandwidth is low (heartbeat every 5 seconds by
default).

## Thermal and power

- Laptops throttle under sustained GPU load. For 24/7 operation, prefer a
  desktop Mac (Mac Studio / Mac Pro).
- Use `darkbloom status` and `darkbloom doctor` to check thermal state.
- The provider calls `ProcessLifecycle.preventSystemSleep()` while serving so
  in-flight requests are not interrupted.
- v0.7.9 adds optional experimental fan control. It requires a Mac that reports
  at least one fan and a validated GPU sensor; fanless and unknown hardware stays
  under macOS control. See [Experimental Fan Control](fan-control.md).

## macOS version support

The installer and CLI target macOS 14+. Individual security checks (SIP,
Authenticated Root, RDMA controls) behave differently across macOS versions;
`darkbloom doctor` reports the current state without requiring you to manually
parse tool output.

## Verification checklist

Before relying on a node for public traffic:

- [ ] `darkbloom doctor` passes all critical checks.
- [ ] `darkbloom status` shows the daemon running with a trust verdict.
- [ ] `darkbloom models catalog` lists the models you intend to serve.
- [ ] You have at least `weights + 2 GB + memory_reserve_gb` of usable RAM per
      loaded model.
- [ ] `darkbloom benchmark` completes for your target model.
- [ ] The machine has a stable outbound path to `api.darkbloom.dev`.
- [ ] For hardware trust, the MDM enrollment profile is installed.
