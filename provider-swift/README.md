# Swift provider package

> Last updated: 2026-09-11 · commit `645d22c6d`

The Apple Silicon provider runs inference through MLX-Swift and exposes the
`darkbloom` CLI. Release packaging places the provider and its runtime resources
in a signed `Darkbloom.app`; CLI entry points in the installation's `bin`
directory point into that app.

## Products and responsibilities

[Package.swift](Package.swift) declares the products, targets, dependencies and
test suites. The executable products are:

| Product | Responsibility |
|---|---|
| `darkbloom` | Provider lifecycle, local serving, account setup, diagnostics, model management and benchmarks |
| `darkbloom-enclave` | Secure Enclave attestation and signing helper; also exposed by the legacy `eigeninference-enclave` installation link |
| `darkbloom-fan-helper` | Fan-control helper packaged for opt-in activation |
| `darkbloom-publish` | Build and hash model manifests for publishing |

`ProviderCoreFoundation` contains manifest, hashing and template helpers.
`ProviderCore` owns coordinator connectivity, request lifecycle, model loading,
inference, cache persistence, telemetry, platform checks and updates.
`DarkbloomFanCore`, `DarkbloomFanProtocol` and `DarkbloomFanService` separate fan
policy, messages and service operations. Benchmark support lives in the
`ProviderBenchmark` target. Tests are grouped by their package targets under
[Tests](Tests).

## Build and test

Use the repository's [build guide](../docs/developer/build.md) for toolchain and
submodule setup. From the repository root:

```bash
make provider-build
make provider-test
```

These targets build the provider and stage its source-matched `mlx.metallib`.
The metallib must match the nested MLX source used by `Cmlx`; use the canonical
[scripts/fetch-metallib.sh](../scripts/fetch-metallib.sh) helper after a manual
build. See the [test guide](../docs/developer/test.md) for focused suites and
hardware-dependent checks.

## Runtime and operations

The [CLI reference](../docs/provider/cli-reference.md) describes supported
commands and flags. The [provider architecture](../docs/architecture/components/provider.md)
and [inference architecture](../docs/architecture/inference.md) explain the
request lifecycle, continuous batching, model admission and cache behavior.
Release packaging and rollback are covered by the
[provider release runbook](../docs/operations/provider-release.md).
