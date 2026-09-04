# Provider hardware requirements

> Last updated: 2026-09-03 · commit `5d400cf75`

Reference for what a Mac needs to run the `darkbloom` provider: the minimum
requirements, the chip families the provider distinguishes, which catalog
models load at each unified-memory size, and the disk and thermal behaviour an
operator has to plan for. For operators choosing or checking a machine. The
memory constants and the load-gate arithmetic behind the RAM table are stated
once in [`../architecture/hardware-support.md`](../architecture/hardware-support.md)
and are not repeated here.

## Minimum requirements

| Component | Requirement | Code |
|---|---|---|
| CPU / GPU | Apple Silicon with Metal; `ChipFamily` recognised: `M1`, `M2`, `M3`, `M4`, `M5` (`Unknown` still runs) | `provider-swift/Sources/ProviderCore/Inference/GPUEnforcement.swift` (`requireMetal`), `provider-swift/Sources/ProviderCore/Protocol/Enums.swift` |
| Architecture | `arm64` only; the installer refuses Intel Macs | `coordinator/api/install.sh` |
| RAM | At least 8 GB to start at all ([`../architecture/hardware-support.md#context`](../architecture/hardware-support.md#context)); per-model needs below | `provider-swift/Sources/darkbloom/StartCommand+Preflight.swift` (`hardware.memoryGb < 8`) |
| macOS | 14 (Sonoma) or later, the build floor; `darkbloom doctor` warns below macOS 26 (`recommendedMacOSMajorVersion`, [`../architecture/hardware-support.md#context`](../architecture/hardware-support.md#context)) but does not block | `provider-swift/Package.swift` (`.macOS(.v14)`), `provider-swift/Sources/ProviderCore/Security/BootSecurity.swift` |
| Storage | Weights per model (catalog `size_gb`) under the Hugging Face hub cache, plus the SSD prefix-cache budget (`defaultSSDDiskBudgetBytes`, [`../reference/ssd-kv-cache.md#size-and-eviction-rules`](../reference/ssd-kv-cache.md#size-and-eviction-rules)) when that cache is active | `provider-swift/Sources/ProviderCoreFoundation/ModelScanner.swift` (`defaultCacheDirectory`), `provider-swift/Sources/ProviderCore/Inference/PrefixCachePolicy.swift` |
| Network | Outbound `wss://api.darkbloom.dev/ws/provider` and HTTPS on 443; a heartbeat every `heartbeat_interval_secs` ([`cli-reference.md`](./cli-reference.md#providertoml-keys-read-by-the-cli)); no inbound port | `provider-swift/Sources/ProviderCore/Config/ProviderConfig.swift` |
| Security posture | SIP enabled and Full Security boot; a logged-in GUI session for APNs code-identity attestation | [`attestation.md`](./attestation.md) |

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
plus its activation reserve plus the minimum KV headroom
(`requiredToLoadGb`, [load gate](../architecture/hardware-support.md#load-gate-modelloadadmission)).
The table applies the provider's rule to the live catalog as recorded on
2026-08-30 ([`../reports/2026-08-30-activation-floor-measurements.md`](../reports/2026-08-30-activation-floor-measurements.md),
"Live catalog"); `min_ram_gb` and `size_gb` are catalog data, not code, so
re-read them from `darkbloom models catalog` before relying on a row.

| Catalog id | Catalog `min_ram_gb` | Weights `size_gb` | Activation reserve | Provider needs free at load (GiB) | Smallest Mac where an idle box passes the provider gate |
|---|---|---|---|---|---|
| `gpt-oss-20b` | 24 | 12.1 | measured floor | 18.0 | 24 GB (tight) |
| `gemma-4-26b-qat-4bit` | 36 | 15.6 | default | 23.9 | 32 GB |
| `qwen3-vl-30b-a3b-instruct` | 32 | 18.3 | default | 27.0 | 32 GB (tight) |
| `qwen3.5-35b-a3b` | 36 | 20.9 | default | 29.9 | 36 GB |
| `qwen3.6-35b-a3b-vl-mtp-mxfp8` | 32 | 21.3 | default | 30.3 | 36 GB — does **not** load on a 32 GB Mac despite the catalog tier |
| `gemma-4-26b` (8bit) | 36 | 28.0 | default | 37.8 | 48 GB — does **not** load on a 36 GB Mac despite the catalog tier |
| `gemma-4-26b-8bit` | 64 | 28.0 | default | 37.8 | 48 GB |

How each column is computed: weights are the catalog `size_gb` padded by
`memoryOverheadFactor`; the activation reserve is
`UnifiedMemoryCap.defaultActivationReserveBytes`, or the model's entry in
`measuredActivationFloorsBytes` where one exists (today only `gpt-oss-20b`);
the load also needs `minimumLoadKVBytes` of KV headroom. The values of those
constants are in [`../architecture/hardware-support.md#constants`](../architecture/hardware-support.md#constants)
and the formulas in [Cap and reserves](../architecture/hardware-support.md#cap-and-reserves-unifiedmemorycap).
"Smallest Mac" assumes nothing else is loaded, the default `memory_reserve_gb`
([`cli-reference.md`](./cli-reference.md#providertoml-keys-read-by-the-cli))
and the default hard cap; "tight" means the system-available memory the gate
needs (the free-at-load figure plus the config reserve) is within 2 GiB of the
machine's total. The two rows marked **not** are the discrepancies the
2026-08-30 report recommends fixing in the catalog (re-tier
`qwen3.6-35b-a3b-vl-mtp-mxfp8` to 36; `gemma-4-26b` 8bit stays blocked at
padded weights until a provider-path residency measurement lands).

Several models can be resident at once, up to `max_model_slots`
([`cli-reference.md`](./cli-reference.md#providertoml-keys-read-by-the-cli)):
each adds its padded weights, while the activation reserve is charged once at
the largest floor in the serving set. The KV cache for concurrent requests comes
out of whatever the cap leaves after weights and activations; a model that loads
with less than `minimumLoadKVBytes` of KV headroom is unloaded again
(`provider-swift/Sources/ProviderCore/Inference/KVHeadroomProbe.swift`;
[after the load](../architecture/hardware-support.md#after-the-load)).

## Disk for the SSD prefix cache

| Rule | Where it is specified | Code |
|---|---|---|
| Location | [`../reference/ssd-kv-cache.md#paths`](../reference/ssd-kv-cache.md#paths) | `provider-swift/Sources/ProviderCore/KVCacheSSD/SSDPrefixCacheFactory.swift` |
| Box-wide budget (`defaultSSDDiskBudgetBytes`, halved when the volume is short on free space), the `DARKBLOOM_PREFIX_CACHE_DISK_GB` override, LRU eviction | [`../reference/ssd-kv-cache.md#size-and-eviction-rules`](../reference/ssd-kv-cache.md#size-and-eviction-rules) | `provider-swift/Sources/ProviderCore/Inference/PrefixCachePolicy.swift` (`ssdDiskBudgetBytes`) |
| Low-disk write stop (`lowDiskFloorBytes`; reads continue) and the daily write cap (`defaultMaxWriteBytesPerDay`) | [`../reference/ssd-kv-cache.md#size-and-eviction-rules`](../reference/ssd-kv-cache.md#size-and-eviction-rules) | `provider-swift/Sources/ProviderCore/KVCacheSSD/SSDPrefixCachePolicy.swift` |
| When it is used at all | Only on slots configured `engine_v2_kv_backend = "paged"`; the default configuration builds no SSD cache | [`../architecture/prefix-cache.md`](../architecture/prefix-cache.md) |

## Thermal and power

| Behaviour | Code |
|---|---|
| The daemon prevents system sleep while serving | `provider-swift/Sources/ProviderCore/Service/ProcessLifecycle.swift` (`preventSystemSleep`) |
| Thermal state (`nominal`, `fair`, `serious`, `critical`) is sampled from `ProcessInfo.thermalState`, sent to the coordinator as `thermal_state`, and written to the daemon state file read by `darkbloom status` | `provider-swift/Sources/ProviderCore/Hardware/SystemMetrics.swift`, `provider-swift/Sources/ProviderCore/Protocol/Types.swift`, `provider-swift/Sources/ProviderCore/Service/DaemonStateFile.swift` |
| Optional experimental fan control (Macs with a fan and a validated GPU sensor) | [`fan-control.md`](./fan-control.md) |

## Related

- [`../architecture/hardware-support.md`](../architecture/hardware-support.md) — the memory constants, cap formulas and load gate
- [`../architecture/inference.md`](../architecture/inference.md) — supported model families
- [`../reference/ssd-kv-cache.md`](../reference/ssd-kv-cache.md) — SSD cache paths, budget and knobs
- [`../reference/configuration.md`](../reference/configuration.md) — every `DARKBLOOM_*` variable
- [`cli-reference.md`](./cli-reference.md) — `provider.toml` keys and their defaults
- [`../consumer/models.md`](../consumer/models.md) — the model catalog as consumers see it
