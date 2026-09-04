# Provider hardware requirements

> Last updated: 2026-09-03 · commit `5d400cf75`

What a Mac needs to run the `darkbloom` provider and which catalog models load
at each unified-memory size. Numbers below are derived from the provider's load
gate and the catalog; the arithmetic itself lives in
[`../architecture/hardware-support.md`](../architecture/hardware-support.md).

## Minimum requirements

| Component | Requirement | Code |
|---|---|---|
| CPU / GPU | Apple Silicon with Metal; `ChipFamily` recognised: `M1`, `M2`, `M3`, `M4`, `M5` (`Unknown` still runs) | `provider-swift/Sources/ProviderCore/Inference/GPUEnforcement.swift` (`requireMetal`), `provider-swift/Sources/ProviderCore/Protocol/Enums.swift` |
| Architecture | `arm64` only; the installer refuses Intel Macs | `coordinator/api/install.sh` |
| RAM | ≥ 8 GB to start at all; per-model needs below | `provider-swift/Sources/darkbloom/StartCommand+Preflight.swift` (`hardware.memoryGb < 8`) |
| macOS | 14 (Sonoma) or later — the build floor; `darkbloom doctor` warns below macOS 26 but does not block | `provider-swift/Package.swift` (`.macOS(.v14)`), `provider-swift/Sources/ProviderCore/Security/BootSecurity.swift` (`recommendedMacOSMajorVersion = 26`) |
| Storage | Weights per model (catalog `size_gb`) under the Hugging Face hub cache, plus up to 20 GiB for the SSD prefix cache when it is active | `provider-swift/Sources/ProviderCoreFoundation/ModelScanner.swift` (`defaultCacheDirectory`), `provider-swift/Sources/ProviderCore/Inference/PrefixCachePolicy.swift` (`defaultSSDDiskBudgetBytes`) |
| Network | Outbound `wss://api.darkbloom.dev/ws/provider` and HTTPS on 443; heartbeat every `heartbeat_interval_secs = 5`; no inbound port | `provider-swift/Sources/ProviderCore/Config/ProviderConfig.swift` |
| Security posture | SIP enabled; a logged-in GUI session for APNs code-identity attestation | [`attestation.md`](attestation.md) |

## Chip families

| Family | Recognised as | Behaviour that differs |
|---|---|---|
| M1, M2 | `ChipFamily.m1`, `.m2` | MTP `maxRectangularTokens = 4` (`provider-swift/Sources/ProviderCore/Inference/MTPAutomaticVerificationPolicy.swift`) |
| M3, M4 | `.m3`, `.m4` | MTP `maxRectangularTokens = 8` |
| M5 | `.m5` | As M3/M4, plus the provider advertises runtime capability `apple_m5` (and `mlx_nax` when the NAX kernels are available); the catalog's `required_provider_capabilities` uses these to decide eligibility (`provider-swift/Sources/ProviderCore/Models/ModelRuntimeRequirements.swift`, `coordinator/registry/provider_capabilities.go`) |
| Other | `.unknown` | Treated like M1/M2 for MTP |

Chip tier (`Base`, `Pro`, `Max`, `Ultra`) is reported to the coordinator but
does not gate any model (`provider-swift/Sources/ProviderCore/Hardware/HardwareDetector.swift`,
`parseChipIdentity`).

## RAM tiers and catalog models

Which model loads on a given Mac is decided twice: the coordinator routes only
to boxes whose total memory is at least the catalog's `min_ram_gb`
(`coordinator/registry/scheduler.go`, `modelFitsHardware`), and the provider
then requires, at load time, free memory of at least the model's padded weights
plus its activation reserve plus 1 GiB
(`provider-swift/Sources/ProviderCore/Inference/ModelLoadAdmission.swift`,
`requiredToLoadGb`). The table applies the provider's rule to the live catalog
as recorded on 2026-08-30
(`docs/reports/2026-08-30-activation-floor-measurements.md`, "Live catalog");
`min_ram_gb` and `size_gb` are catalog data, not code, so re-read them from
`darkbloom models catalog` before relying on a row.

| Catalog id | Catalog `min_ram_gb` | Weights `size_gb` | Activation reserve | Provider needs free at load (GiB) | Smallest Mac where an idle box passes the provider gate |
|---|---|---|---|---|---|
| `gpt-oss-20b` | 24 | 12.1 | 3.5 GiB (measured floor) | 18.0 | 24 GB (tight: 22 GiB of the 24 must be system-available) |
| `gemma-4-26b-qat-4bit` | 36 | 15.6 | 5.5 GiB | 23.9 | 32 GB |
| `qwen3-vl-30b-a3b-instruct` | 32 | 18.3 | 5.5 GiB | 27.0 | 32 GB (tight) |
| `qwen3.5-35b-a3b` | 36 | 20.9 | 5.5 GiB | 29.9 | 36 GB |
| `qwen3.6-35b-a3b-vl-mtp-mxfp8` | 32 | 21.3 | 5.5 GiB | 30.3 | 36 GB — does **not** load on a 32 GB Mac despite the catalog tier |
| `gemma-4-26b` (8bit) | 36 | 28.0 | 5.5 GiB | 37.8 | 48 GB — does **not** load on a 36 GB Mac despite the catalog tier |
| `gemma-4-26b-8bit` | 64 | 28.0 | 5.5 GiB | 37.8 | 48 GB |

Sources for each column: weights are padded by `memoryOverheadFactor = 1.2`
(`provider-swift/Sources/ProviderCore/Models/ModelScanner+Discovery.swift`; the
coordinator mirrors it as `coldLoadCatalogGBToMemGiB` in
`coordinator/registry/scheduler.go`); the activation reserve is
`UnifiedMemoryCap.defaultActivationReserveBytes` (5.5 GiB) or the model's entry
in `measuredActivationFloorsBytes` (`gpt-oss-20b`: 3.5 GiB;
`provider-swift/Sources/ProviderCore/Inference/UnifiedMemoryCap.swift`); the
extra 1 GiB is `minimumLoadKVBytes`; "smallest Mac" assumes nothing else is
loaded, the default `memory_reserve_gb = 4`
(`provider-swift/Sources/ProviderCore/Config/ProviderConfig.swift`) and the
default cap of 90 % of RAM or RAM − 2 GiB, whichever is smaller. "Tight" means
the system-available memory the gate needs (the free-at-load figure plus the
4 GiB reserve) is within 2 GiB of the machine's total. The two rows marked
**not** are the discrepancies the 2026-08-30 report recommends fixing in the
catalog (re-tier `qwen3.6-35b-a3b-vl-mtp-mxfp8` to 36; `gemma-4-26b` 8bit stays
blocked at padded weights until a provider-path residency measurement lands).

Several models can be resident at once (`max_model_slots` default `3`,
`provider-swift/Sources/ProviderCore/Config/ProviderConfig.swift`): each adds its
padded weights, while the activation reserve is charged once at the largest
floor in the serving set. The KV cache for concurrent requests comes out of
whatever the cap leaves after weights and activations; a model that loads with
less than 1 GiB of KV headroom is unloaded again
(`provider-swift/Sources/ProviderCore/Inference/KVHeadroomProbe.swift`).

## Disk for the SSD prefix cache

| Rule | Value | Code |
|---|---|---|
| Location | `~/Library/Caches/darkbloom/kv3/` | `provider-swift/Sources/ProviderCore/KVCacheSSD/SSDPrefixCacheFactory.swift` |
| Budget | `min(20 GiB, free space / 2)`, box-wide LRU; `DARKBLOOM_PREFIX_CACHE_DISK_GB` overrides | `provider-swift/Sources/ProviderCore/Inference/PrefixCachePolicy.swift` (`ssdDiskBudgetBytes`) |
| Writes stop when free space is below | `max(20 GiB, 5 % of the volume)`; reads continue | `provider-swift/Sources/ProviderCore/KVCacheSSD/SSDPrefixCachePolicy.swift` (`lowDiskFloorBytes`) |
| Daily write cap | 150 GB per day (`defaultMaxWriteBytesPerDay`) | `SSDPrefixCachePolicy.swift` |
| When it is used at all | Only on slots configured `engine_v2_kv_backend = "paged"`; the default configuration builds no SSD cache | [`../architecture/prefix-cache.md`](../architecture/prefix-cache.md) |

## Thermal and power

| Behaviour | Code |
|---|---|
| The daemon prevents system sleep while serving | `provider-swift/Sources/ProviderCore/Service/ProcessLifecycle.swift` (`preventSystemSleep`) |
| Thermal state (`nominal`, `fair`, `serious`, `critical`) is sampled from `ProcessInfo.thermalState`, sent to the coordinator as `thermal_state`, and written to the daemon state file read by `darkbloom status` | `provider-swift/Sources/ProviderCore/Hardware/SystemMetrics.swift`, `provider-swift/Sources/ProviderCore/Protocol/Types.swift`, `provider-swift/Sources/ProviderCore/Service/DaemonStateFile.swift` |
| Optional experimental fan control (Macs with a fan and a validated GPU sensor) | [`fan-control.md`](fan-control.md) |

## Related

- [`../architecture/hardware-support.md`](../architecture/hardware-support.md) — the memory model and load gate
- [`../architecture/inference.md`](../architecture/inference.md) — supported model families
- [`../reference/ssd-kv-cache.md`](../reference/ssd-kv-cache.md) — SSD cache paths and knobs
- [`../reference/configuration.md`](../reference/configuration.md) — `memory_reserve_gb`, `max_model_slots`, `engine_v2_kv_backend` and every `DARKBLOOM_*` variable
- [`../consumer/models.md`](../consumer/models.md) — the model catalog as consumers see it
