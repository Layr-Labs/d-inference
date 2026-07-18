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
darkbloom beta enable kv-quant
darkbloom restart
```

You can also see which beta features are active in `darkbloom status` (the
`Beta features:` line), or edit the TOML directly.

## Available features

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

The v0.7.11 provider contains the default-off MTP implementation, but shipping
that code does not activate speculative decoding:

```bash
darkbloom beta enable mtp
darkbloom restart
```

Activation additionally requires a verified `spec_dec` assistant artifact in
the model catalog. Production has no such artifact as of the v0.7.11 release
preparation, so an enabled provider still falls back to target-only decoding.

The implementation has target-authoritative verification and focused parity
coverage. That is not a universal certification of token-identical behavior on
every M1, M2, M3, or unknown Apple chip/model combination. Those hardware
cohorts require separate canaries and the supervised benchmark matrix before
activation. Provider publication, exact-cache routing activation, and MTP
activation are three independent rollout decisions.
