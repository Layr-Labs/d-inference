# Provider Hardware Requirements

Darkbloom providers run on Apple Silicon Macs. This page describes the minimum
and recommended specs, how memory is accounted, and how to size a machine for
the models you want to serve.

## Minimum requirements

| Component | Minimum | Notes |
|-----------|---------|-------|
| **CPU** | Apple M1 (or later) | Apple Silicon required; Intel Macs are not supported |
| **RAM** | 8 GB | Start path rejects `< 8 GB` (`provider-swift/Sources/darkbloom/StartCommand.swift:444-447`) |
| **GPU** | Apple Silicon integrated GPU | CPU-only execution is rejected (`provider-swift/Sources/darkbloom/StartCommand.swift:80-85`) |
| **Storage** | 50 GB free | SSD required; model weights are large |
| **macOS** | 14 (Sonoma) | Newer is better; install script enforces Darwin + arm64 |
| **Network** | Outbound HTTPS to coordinator | No inbound port is required |

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
