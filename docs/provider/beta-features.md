# Beta Features

Beta features are experimental provider capabilities that are **off by default**.
They are validated enough to try in production but may change, carry caveats, or
only apply to specific model families. Enable them per provider when you want to
opt in.

## How beta features are toggled

Beta features are **config-backed**, not environment-variable backed. Each one is
a field in your provider TOML config (`~/.config/darkbloom/provider.toml`). This
matters: the launchd daemon started by `darkbloom start` only inherits a tiny
allowlist of `DARKBLOOM_*` environment variables
(`provider-swift/Sources/ProviderCore/Daemon/LaunchAgent.swift`), so an env-var
toggle would silently have no effect on the running daemon. A TOML field is always
read by every serve path (daemon, `--foreground`, and `--local`).

The registry of available features lives in
`provider-swift/Sources/ProviderCore/Config/BetaFeatures.swift`.

## The `darkbloom beta` command

```bash
darkbloom beta list                 # show all beta features and whether each is on (default)
darkbloom beta status [feature]     # show details for all features, or one
darkbloom beta enable <feature>     # turn a feature on
darkbloom beta disable <feature>    # turn a feature off
```

`enable`/`disable` perform a read-modify-write of the TOML config and print
whether a restart is required. Most beta features take effect on the next backend
start:

```bash
darkbloom beta enable mtp
darkbloom restart
```

You can also see which beta features are active in `darkbloom status` (the
`Beta features:` line), or edit the TOML directly.

## Available features

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
