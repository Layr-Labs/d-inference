# Hardware Support

Providers run on Apple Silicon Macs (M1 or later). Minimum requirements depend
on the model being served.

## Supported chips

| Chip | Memory | Bandwidth | Typical models |
|---|---|---|---|
| M1 | 8–16 GB | 68 GB/s | 3B–8B |
| M1 Pro/Max | 16–64 GB | 200–400 GB/s | 8B–33B |
| M2 Pro/Max | 16–96 GB | 200–400 GB/s | 8B–70B |
| M3 Pro/Max | 18–128 GB | 150–400 GB/s | 8B–122B |
| M3 Ultra | 96–256 GB | 819 GB/s | 8B–230B |
| M4 Pro/Max | 24–128 GB | 273–546 GB/s | 8B–122B |

These are guidelines, not guarantees. A provider's `ensureModelLoaded` requires
`estimatedMemoryGb * 3.0` headroom (`provider-swift/Sources/ProviderCore/...`).
The coordinator's `freeMemoryAdmits` check is less conservative, so a model the
coordinator admits can still fail to load on the provider.

## macOS requirements

- macOS 15 or later is the current minimum target.
- System Integrity Protection (SIP) must be enabled.
- Secure Boot must be set to Full (for `hardware` trust).
- A logged-in GUI Aqua session is required for APNs code-identity attestation.

The floor is set by the packaged Metal kernel libraries, not by the Swift
binary. Releases ship two of them
(`.github/workflows/release-swift.yml`, `scripts/fetch-metallib.sh`):

| Library | Deployment target | `_nax` kernels | Location in `Darkbloom.app` |
|---|---|---|---|
| Primary | 26.2 | yes | `Contents/MacOS/mlx.metallib` |
| Baseline | 15.0 | no | `Contents/MacOS/Resources/mlx.metallib` |

The M5 `_nax` kernels compile only against Metal 4.0 with a macOS 26.2
deployment target, and a metallib linked for 26.2 is rejected outright by every
older Metal runtime. MLX's `load_default_library`
(`libs/mlx-swift/Source/Cmlx/mlx/mlx/backend/metal/device.cpp`) probes the
colocated `mlx.metallib` first and the colocated `Resources/mlx.metallib`
second, falling through only when the first fails to load — so macOS 26.2+ hosts
get the NAX kernels and older hosts land on the baseline. `is_nax_available()`
is itself gated on macOS 26.2, so a host on the baseline never asks for a kernel
it lacks.

Below the floor neither library loads, MLX's `Device()` constructor throws, and
the provider cannot serve at all. `scripts/install.sh` refuses to install there,
and `PackagedRuntimeSmoke` reports the OS and the underlying Metal error rather
than a downstream symptom. `scripts/check-macos-floor.sh` pins the floor across
the installers, the release workflow, and
`provider-swift/Sources/ProviderCore/Inference/PackagedMetallib.swift`.

## Networking

Providers need outbound HTTPS/WebSocket to the coordinator. No inbound port
forwarding is required because the provider initiates the WebSocket.
