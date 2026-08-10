# Beta Features

Beta features are experimental provider capabilities with feature-specific
defaults. The benchmark-selected Gemma stack is **on by default**, including for
existing configs that omit its section; reserved and opt-in features remain off
until enabled. Every feature can be changed per provider.

## How beta features are toggled

Beta features are **config-backed**. Each one is a field in your provider TOML
config (`~/.config/darkbloom/provider.toml`), and that config is authoritative
for daemon, `--foreground`, and `--local` processes. Low-level environment
variables are implementation details, not an independent production control
surface. Process-wide optimization state is resolved at startup, so restart
after changing a restart-required feature.

The registry of available features lives in
`provider-swift/Sources/ProviderCore/Config/BetaFeatures.swift:73-80`.

### Canonical implementation references

- Default-on decoding for omitted config sections:
  `provider-swift/Sources/ProviderCore/Config/GemmaOptimizationSettings.swift:16-20`
  (both fields default to `true`) and
  `provider-swift/Sources/ProviderCore/Config/ProviderConfig.swift:332-334`
  (`decodeIfPresent` with the defaulted struct as fallback).
- Startup projection before the first MLX device access (daemon, foreground,
  `--local`, and `benchmark` processes): the shared ordering seam is
  `provider-swift/Sources/darkbloom/ServeRuntimePreparer.swift:24-35`
  (`ServeRuntimePreparer.prepareRuntime`); the serve path calls it through
  `Start`'s forwarding shim at
  `provider-swift/Sources/darkbloom/StartCommand.swift:87`, and the benchmark
  path calls it directly at
  `provider-swift/Sources/darkbloom/BenchmarkCommand.swift:105`.
  Benchmark A/B is config-driven — a shell-preset low-level key that
  conflicts with the config projection is rejected rather than overwritten,
  and the effective controls are printed before measuring
  (`provider-swift/Sources/darkbloom/BenchmarkCommand.swift:91-110`, guard
  helper `provider-swift/Sources/darkbloom/ServeRuntimePreparer.swift:58-79`).
- The config→environment projection and its overwrite authority:
  `provider-swift/Sources/ProviderCore/Config/GemmaOptimizationEnvironment.swift:14-25`
  (`projection(for:)`) and `:57` (`apply(_:)`).
- The `benchmark`-selected coupling of weighted unsort with safe R1 as one
  control: `provider-swift/Sources/ProviderCore/Config/GemmaOptimizationSettings.swift:11-14`.

## The `darkbloom beta` command

```bash
darkbloom beta list                 # show all beta features and whether each is on (default)
darkbloom beta status [feature]     # show details for all features, or one
darkbloom beta enable <feature>     # turn a feature on
darkbloom beta disable <feature>    # turn a feature off
```

`enable`/`disable` perform a read-modify-write of the TOML config and print
whether a restart is required. For example, to roll back the default-on coupled
Gemma expert optimization:

```bash
darkbloom beta disable gemma-weighted-r1
darkbloom restart
```

The restart is the activation boundary. Re-enable and restart to restore the
selected default. You can also see which beta features are active in
`darkbloom status` (the `Beta features:` line), or edit the TOML directly.

## Available features

### `gemma-prefill-layer18` — layer-18 prefill submission

This optimization submits queued Gemma prefill work every 18 transformer
layers instead of waiting for one final submission. It defaults ON for both new
and pre-existing provider configs.

```toml
[gemma_optimizations]
prefill_layer18 = true
```

Rollback is config-backed and restart-required:

```bash
darkbloom beta disable gemma-prefill-layer18
darkbloom restart
```

Setting the key to `false` (or using the command above) restores the legacy
one-final-submission behavior after restart.

### `gemma-weighted-r1` — coupled weighted unsort + safe R1

This optimization defaults ON and is deliberately one atomic production
control. It enables both the direct weighted expert reduction and the safe
exact-shape R1 QMM path. There is no supported config or beta combination that
enables one without the other.

```toml
[gemma_optimizations]
weighted_r1 = true
```

To roll back both paths together:

```bash
darkbloom beta disable gemma-weighted-r1
darkbloom restart
```

Missing `[gemma_optimizations]` sections and missing keys decode as `true`, so
old configs receive the selected v0.8.2 stack. An explicit `false` plus restart
is the durable rollback.

### `kv-quant` — reserved KV-cache quantization toggle

v0.7.5 serves fp16-only KV through ContinuousBatchingV2. The configuration
field remains so operators can express intent for a future CBv2-native
implementation, but enabling it now logs a startup/per-load warning and does
not change cache precision or capacity.

```bash
darkbloom beta enable kv-quant
darkbloom restart
```

Equivalent TOML:

```toml
[backend]
kv_quant = true
```

After restarting, the logs state that quantization is unavailable:

```bash
darkbloom logs
```

Notes and caveats:

- No v0.7.5 model family is quantized; all EngineV2 KV caches remain fp16.
- The setting is read at backend start, so a restart is required after toggling.
- Default is `false`. The field is retained in
  `provider-swift/Sources/ProviderCore/Config/ProviderConfig.swift` for a
  future EngineV2 implementation.

### `mtp` — Gemma 4 multi-token prediction code path

Providers v0.7.12 and later contain the default-off MTP implementation, but
shipping that code does not activate speculative decoding:

```bash
darkbloom beta enable mtp
darkbloom restart
```

Activation additionally requires a verified `spec_dec` assistant artifact in
the model catalog. Production publishes that artifact for
`gemma-4-26b-qat-4bit`; other models and providers without the explicit beta
setting continue with target-only decoding.

The implementation has target-authoritative verification and focused parity
coverage. That is not a universal certification of token-identical behavior on
every M1, M2, M3, or unknown Apple chip/model combination. Those hardware
cohorts require separate canaries and the supervised benchmark matrix before
activation. Provider publication, exact-cache routing activation, and MTP
activation are three independent rollout decisions.
