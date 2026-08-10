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
`BetaFeatures.all` in
`provider-swift/Sources/ProviderCore/Config/BetaFeatures.swift:73-133`.

### Canonical implementation references

- Default-on decoding for omitted keys is implemented by
  `GemmaOptimizationSettings.init(from:)` in
  `provider-swift/Sources/ProviderCore/Config/GemmaOptimizationSettings.swift:29-35`.
  The missing-section fallback is `ProviderConfig.init(from:)` in
  `provider-swift/Sources/ProviderCore/Config/ProviderConfig.swift:391-400`.
- Startup projection before the first MLX device access (daemon, foreground,
  `--local`, and `benchmark` processes): the shared ordering seam is
  `provider-swift/Sources/darkbloom/ServeRuntimePreparer.swift:24-35`
  (`ServeRuntimePreparer.prepareRuntime`); the serve path calls it through
  `Start.prepareServeRuntime` at
  `provider-swift/Sources/darkbloom/StartCommand.swift:84-91,128-147`.
  `Benchmark.run` rejects a conflicting shell override at
  `provider-swift/Sources/darkbloom/BenchmarkCommand.swift:147-159`, prepares
  the runtime at `:160-165`, and reports the effective controls at `:166-170`.
  The guard helper is `ServeRuntimePreparer.conflictingEnvironmentOverride`
  in `provider-swift/Sources/darkbloom/ServeRuntimePreparer.swift:48-79`.
- The config→environment projection and its overwrite authority:
  `GemmaOptimizationEnvironment.projection(for:)` in
  `provider-swift/Sources/ProviderCore/Config/GemmaOptimizationEnvironment.swift:10-23`
  and `GemmaOptimizationEnvironment.apply(_:)` at `:52-64`.
- The `benchmark`-selected coupling of weighted unsort with safe R1 as one
  control: `GemmaOptimizationSettings.weightedR1` in
  `provider-swift/Sources/ProviderCore/Config/GemmaOptimizationSettings.swift:10-14`.

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

### `mtp` — Gemma 4 multi-token prediction code path

Providers v0.7.12 and later contain the default-off MTP implementation, but
shipping that code does not activate speculative decoding:

```bash
darkbloom beta enable mtp
darkbloom restart
```

Without a valid local `[backend] mtp_drafter_path` override, activation also
requires a verified `spec_dec` assistant artifact in the model catalog. The
current public production catalog publishes `metadata.spec_dec` for
`gemma-4-26b-qat-4bit` ([live catalog](https://api.darkbloom.dev/v1/models/catalog?type=text));
other catalog models and providers without the explicit beta setting continue
with target-only decoding. Artifact resolution and target-only fallback are in
`ProviderLoop.specDecPreparation` at
`provider-swift/Sources/ProviderCore/ProviderLoop+MTP.swift:35-54`.

The implementation has target-authoritative verification and focused parity
coverage. That is not a universal certification of token-identical behavior on
every M1, M2, M3, or unknown Apple chip/model combination. Those hardware
cohorts require separate canaries and the supervised benchmark matrix before
activation. Provider publication, exact-cache routing activation, and MTP
activation are three independent rollout decisions.

## Retired features

### `kv-quant` — removed in v0.8.0

KV-cache quantization has been removed from the product. `darkbloom beta
enable kv-quant` now fails with `Unknown beta feature 'kv-quant'`.

The `[backend] kv_quant` TOML key is **retired, not rejected**: a
`provider.toml` that still sets it loads normally and keeps every other
setting. The value is ignored and startup logs one warning per retired key:

```
provider.toml sets [backend] kv_quant, which is a RETIRED knob and is IGNORED — remove the key
```

Remove the line to silence it. Any config the provider rewrites (for example
via `darkbloom beta enable mtp`) sheds retired keys automatically.

No provider ever served quantized KV: v0.7.5 through v0.7.15 already served
fp16-only KV and warned that the setting did not apply, so removing it
changes no serving behaviour, memory footprint, or capacity. Quantized paged
pages are separate future work.
