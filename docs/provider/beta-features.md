# Beta Releases And Features

The beta release cohort is opt-in and receives signed prereleases through the
same automatic update, rollback, and traffic-serving path as stable providers.
Joining beta does not remove the provider from public traffic.

```bash
darkbloom beta enable
darkbloom restart
```

This writes `provider.release_channel = "beta"` to
`~/.config/darkbloom/provider.toml`. The provider reports the cohort when it
registers, and manual, startup, background, and watchdog update checks request
the beta channel. Joining also enables `provider.auto_update` so the machine
stays on the beta track. Beta discovery includes stable releases, so a final `X.Y.Z`
naturally supersedes `X.Y.Z-beta.N`.

To stop receiving future beta releases:

```bash
darkbloom beta disable
darkbloom restart
```

Leaving beta does not downgrade an already-installed prerelease. It remains in
place until a newer stable version is published.

Individual beta features are experimental provider capabilities that are **off by default**.
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
darkbloom beta enable               # join the beta release cohort
darkbloom beta disable              # return to stable release discovery
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

You can also see the release channel and active beta features in `darkbloom
status`, or edit the TOML directly.

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
