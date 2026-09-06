# Beta features

> Last updated: 2026-09-06 · commit `615d96328`

Turn experimental engine behaviour on or off per machine with `darkbloom beta`,
which writes keys into `provider.toml` so every serve path (LaunchAgent daemon,
`--foreground`, `--local`) sees the same value. For operators; the result is a
durable, restart-safe toggle plus a clear picture of which environment
variables still do anything.

Beta toggles are config-backed on purpose: the launchd daemon inherits only a
short allow-list of `DARKBLOOM_*` variables (see
[CLI reference → LaunchAgent environment passthrough](./cli-reference.md#launchagent-environment-passthrough)),
so an environment-variable toggle would silently no-op for the normal daemon
(`provider-swift/Sources/ProviderCore/Config/BetaFeatures.swift`, `BetaFeature`).

## Prerequisites

- Provider installed ([installation](./installation.md)).
- Know which config file the daemon reads: `~/.config/darkbloom/provider.toml`
  unless you pass `--config` to both `darkbloom beta` and `darkbloom start`.

## Steps

1. List the features this build knows about:

   ```bash
   darkbloom beta            # same as `darkbloom beta list`
   darkbloom beta list --json
   ```

   Each line shows `[on]`, `[off]` or `[auto]` and the one-line summary
   (`Beta.List`, `provider-swift/Sources/darkbloom/BetaCommand.swift`).

2. Read the details and current posture of one feature:

   ```bash
   darkbloom beta status mtp
   darkbloom beta status      # every feature
   ```

3. Toggle it:

   ```bash
   darkbloom beta enable mtp
   darkbloom beta disable gemma-weighted-r1
   ```

   `setBetaFeature` loads the config, takes an exclusive lock on the file,
   reloads inside the lock, writes the feature's key, and saves. An absent key
   is always written on an explicit toggle, so a future default flip cannot
   silently move your provider; `… is already enabled.` is printed only when
   the file already pins the requested value. Without `--config`, the write
   goes to the canonical `~/.config/darkbloom/provider.toml` even if the
   snapshot was just migrated from a legacy location. Unknown ids exit with
   `Unknown beta feature '<id>'. Available: …`.

4. Restart when told to. Every current feature is a process-start latch:

   ```bash
   darkbloom restart
   ```

## Features in v0.8.16

`BetaFeatures.all` (`provider-swift/Sources/ProviderCore/Config/BetaFeatures.swift`):

| Id | `provider.toml` key | Default | Restart | Effect |
|---|---|---|---|---|
| `gemma-prefill-layer18` | `[gemma_optimizations] prefill_layer18` | `true` | yes | Submit Gemma prefill work every 18 layers. Disable to restore the legacy one-final-submission prefill. Projected into the process as `DARKBLOOM_GEMMA4_PREFILL_CHUNK_EVAL=18` / `0` |
| `gemma-weighted-r1` | `[gemma_optimizations] weighted_r1` | `true` | yes | Coupled weighted-unsort + safe exact-shape R1 expert paths for Gemma MoE; neither half can be selected alone. Projected as `MLX_GEMMA4_FUSED_WEIGHTED_UNSORT=1/0` and `MLX_GATHER_QMM_EXPERT_SLICES=trust/0` |
| `mtp` | `[backend] mtp_mode` | `auto` | yes | Multi-token prediction (speculative decoding) on CBv2 targets. `auto` turns MTP on for Qwen 3.5-family checkpoints (`qwen3_5`, `qwen3_5_moe`) whose `config.json` declares an embedded head after artifact validation, and leaves other models target-only. `enable` writes `on` (required for separately published catalog assistants and `mtp_drafter_path` overrides); `disable` writes `off`. Resolution and load fail open to target-only decode |

`darkbloom beta list` shows `auto (model-aware)` for MTP until you pin it;
`darkbloom status` prints the resulting per-slot MTP and KV posture.

## Environment variables and precedence

| Variable | Relationship to the toggle | Source |
|---|---|---|
| `DARKBLOOM_CBV2_MTP` | Process-wide **kill switch**: `0`, `false`, `no` or `off` disables MTP regardless of `mtp_mode`; any other value, or unset, defers to config. On the LaunchAgent passthrough list | `provider-swift/Sources/ProviderCore/SpecDec/SpecDecArtifactFunnel.swift` (`killSwitchEnabled`) |
| `DARKBLOOM_CBV2_PAGED_KV` | Kill switch for the paged KV backend (`0` forces contiguous everywhere) — not a beta feature. Candidate `auto` selects paged only for the [exact Qwen allowlist](../architecture/prefix-cache.md#kv-layouts), with automatic fallback; all other IDs stay contiguous. Explicit global/per-model backend settings remain available. There is no env var that turns paged on. Passthrough-listed | `provider-swift/Sources/ProviderCore/Inference/EngineV2KVBackendPolicy.swift` (`killSwitchEnvKey`, `preferredBackend`) |
| `DARKBLOOM_GEMMA4_PREFILL_CHUNK_EVAL`, `MLX_GEMMA4_FUSED_WEIGHTED_UNSORT`, `MLX_GATHER_QMM_EXPERT_SLICES` | **Outputs**, not inputs: `GemmaOptimizationEnvironment.apply` overwrites them from config at every serve start. The single exception is a shell `MLX_GATHER_QMM_EXPERT_SLICES=1`, which restores the descriptor-retract drain instead of the `trust` default and is copied into the daemon plist for that reason | `provider-swift/Sources/ProviderCore/Config/GemmaOptimizationEnvironment.swift` (`projection`, `daemonDrainPassthrough`) |
| `DARKBLOOM_MTP_MAX_RECTANGULAR_TOKENS` | Tighten-only cap on MTP verification width; passthrough-listed | [`reference/configuration.md`](../reference/configuration.md) |

The [Qwen-first paging rollout](../design/qwen-first-paged-ssd-rollout.md) is
**not yet validated**. Its candidate backend selection does not change the
[SSD-enabled, no-resident-retention defaults](../architecture/prefix-cache.md#invariants)
or enable coordinator cache routing.

Order of precedence for MTP at load time: kill switch off → target-only;
otherwise `mtp_mode` (`on` / `off` / `auto`) → artifact validation → fail-open
to target-only.

## Retired

Setting any of these prints one `warning: … RETIRED knob and is IGNORED` line at
every `darkbloom start` and changes nothing
(`provider-swift/Sources/ProviderCore/Config/RetiredKnobWarnings.swift`).

Environment variables (`EngineV2Config.retiredEnvironmentKeys`,
`provider-swift/Sources/ProviderCore/Inference/EngineV2Config.swift`):

| Variable | Was |
|---|---|
| `DARKBLOOM_ENGINE_V2` | Engine-v2 master flag; there is one engine now |
| `DARKBLOOM_ENGINE_V2_MODELS` | Engine-v2 model allow-list |
| `DARKBLOOM_COMPILED_DECODE` | Legacy compiled-decode switch |
| `DARKBLOOM_GEMMA_B1_FAST_PATH` | Legacy Gemma batch-1 fast path |
| `DARKBLOOM_B1_GREEDY_FAST_PATH` | Legacy batch-1 greedy fast path |
| `DARKBLOOM_KV_GPTOSS_KERNEL` | Legacy GPT-OSS KV kernel switch |
| `DARKBLOOM_ADAPTIVE_PREFILL_ALLOW_8192` | Legacy adaptive-prefill cap |
| `DARKBLOOM_KV_CAPTURE_MAX_INFLIGHT` | Legacy checkpoint-capture inflight cap |
| `DARKBLOOM_PREFIX_CACHE_MIN_PERSIST_TOKENS` | Legacy SSD prefix-cache per-persist threshold |

`DARKBLOOM_PREFIX_CACHE`, `DARKBLOOM_PREFIX_CACHE_DISK_GB` and
`DARKBLOOM_PREFIX_CACHE_ALLOW_EPHEMERAL` are **not** retired; the SSD offload
tier re-adopted them. Their semantics are in
[`reference/configuration.md`](../reference/configuration.md).

`provider.toml` keys (`BackendSettings.RetiredCodingKeys`,
`provider-swift/Sources/ProviderCore/Config/ProviderConfig.swift`): `[backend]
continuous_batching`, `adaptive_prefill`, `engine_v2`, `legacy_compiled_decode`,
`kv_quant`. Delete them from the file to silence the warnings. The former beta
ids `adaptive-prefill` and `kv-quant` no longer exist.

## Verify

```bash
darkbloom beta list
grep -A3 '^\[gemma_optimizations\]' ~/.config/darkbloom/provider.toml
grep mtp_mode ~/.config/darkbloom/provider.toml
darkbloom status         # per-slot KV/MTP posture after restart
```

## Related

- [CLI reference](./cli-reference.md) — `beta` flags, config keys and defaults, passthrough list.
- [`reference/configuration.md`](../reference/configuration.md) — every environment variable.
- [Troubleshooting](./troubleshooting.md) — KV-backend guard and `RETIRED knob` warnings.
- [Direct mode](./direct-mode.md) — beta features apply to the local endpoint too.
