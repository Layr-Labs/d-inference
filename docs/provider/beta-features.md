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

### `kv-quant` — KV-cache quantization

Stores attention keys/values in 8-bit for the validated model families
(**GPT-OSS** and **Gemma 4**), roughly doubling the number of tokens a provider
can admit concurrently (~1.9x more KV capacity). Other model families are
unaffected and continue to serve fp16.

```bash
darkbloom beta enable kv-quant
darkbloom restart
```

Equivalent TOML:

```toml
[backend]
kv_quant = true
```

After restarting, confirm quantization actually engaged for a served model with:

```bash
darkbloom logs        # look for the `kv-quant` logger
```

Notes and caveats:

- Only GPT-OSS and Gemma 4 are quantized; the provider falls back to fp16 for any
  other family, so enabling it is safe across a mixed catalog.
- The setting is read at backend start, so a restart is required after toggling.
- Default is `false` (fp16). The field is defined in
  `provider-swift/Sources/ProviderCore/Config/ProviderConfig.swift` and consumed
  by the scheduler via `resolveKVQuantScheme(...)`.
