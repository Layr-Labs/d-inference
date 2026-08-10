# Provider Installation

This guide covers installing, updating, and removing the Darkbloom provider CLI.

## One-line install (recommended)

```bash
curl -fsSL https://api.darkbloom.dev/install.sh | bash
```

The coordinator serves the same script at `/install.sh` with environment-specific
templating. `scripts/install.sh` is the sole editable source;
`scripts/sync-install-embed.sh` deterministically generates the byte-identical
`coordinator/api/install.sh` file consumed by `go:embed`. CI rejects drift.

### What the installer does

1. **Preflight** — confirms macOS on Apple Silicon (`uname`/`uname -m`).
2. **Fetches release metadata** — `GET /v1/releases/latest` returns version,
   bundle URL, bundle hash, binary hash, and `mlx.metallib` hash.
3. **Downloads the bundle** into a temporary path.
4. **Verifies hashes** — bundle, `darkbloom` binary, and `mlx.metallib` are
   checked against the coordinator record.
5. **Verifies code signature** — `codesign --verify` on the `darkbloom` binary.
6. **Installs into `~/.darkbloom`** — creates `~/.darkbloom/bin/` and symlinks
   the binaries from `Darkbloom.app/Contents/MacOS/` when the `.app` bundle is
   used.
7. **Updates `PATH`** — appends `export PATH="$HOME/.darkbloom/bin:$PATH"` to
   `~/.zshrc` (or `~/.bashrc`).
8. **Migrates legacy state** — copies tokens/keys from `~/.dginf` or
   `~/.eigeninference` if present.
9. **Provisions Secure Enclave identity** — runs `darkbloom-enclave info`.
10. **Offers MDM enrollment** — downloads the device-attestation profile from
    `POST /v1/enroll` and opens System Settings.

No `sudo` is required. The installer will try to create `/usr/local/bin/darkbloom`
as a convenience symlink, but it falls back to the shell `PATH` update if that
fails.

The v0.7.9+ app also contains a separately signed experimental fan helper under
`Darkbloom.app/Contents/Helpers`. The installer verifies and preserves it but
does not copy it into `/Library`, register launchd, request administrator access,
or write AppleSMC. Only `sudo darkbloom fan enable` performs that separate opt-in
step; see [Experimental Fan Control](fan-control.md).

## Manual install

If you cannot run the curl installer:

1. Download the latest macOS ARM64 bundle from the coordinator's
   `/v1/releases/latest` endpoint (or from the GitHub Release the coordinator
   points to).
2. Verify the bundle SHA-256 against the value in the release record.
3. Extract it to `~/.darkbloom`.
4. Ensure `~/.darkbloom/bin/darkbloom` is executable and signed:
   ```bash
   codesign --verify --verbose ~/.darkbloom/bin/darkbloom
   ```
5. Add `~/.darkbloom/bin` to your `PATH`.
6. Run `darkbloom doctor`.

## Post-install verification

```bash
darkbloom --version
# darkbloom 0.6.5

darkbloom doctor
darkbloom status
```

`darkbloom doctor` exits non-zero if any critical check fails. Add `--strict` to
also treat warnings as failures.

## Configuration file

The canonical path is `~/.config/darkbloom/provider.toml`. The loader also reads
legacy paths for backward compatibility; see
`provider-swift/Sources/ProviderCore/Config/ProviderConfig.swift:485-513`.

A minimal example:

```toml
[provider]
name = "darkbloom-mac16-1"
memory_reserve_gb = 4
auto_update = true
auto_restart = true

[backend]
enabled_models = []
idle_timeout_mins = 60
max_model_slots = 3

[gemma_optimizations]
prefill_layer18 = true
weighted_r1 = true

[coordinator]
url = "wss://api.darkbloom.dev/ws/provider"
private_only = false
```

Both Gemma controls default ON when the section or either key is absent, so
older configs receive the selected stack. Provider TOML is authoritative; set
a key to `false` and run `darkbloom restart` for a durable rollback. The defaults
and missing-key decode are canonical in
`provider-swift/Sources/ProviderCore/Config/GemmaOptimizationSettings.swift:16-34`,
with the missing-section fallback in
`provider-swift/Sources/ProviderCore/Config/ProviderConfig.swift:397-400`.
Startup applies that config before Metal initialization
(`provider-swift/Sources/darkbloom/StartCommand.swift:82-88` and
`provider-swift/Sources/darkbloom/ServeRuntimePreparer.swift:24-35`), and the
beta command's locked read-modify-write plus restart instruction is implemented
at `provider-swift/Sources/darkbloom/BetaCommand.swift:201-235`.

## Updating the provider

```bash
# Check for a newer release without installing
darkbloom update --check-only

# Download, verify hashes, and atomically replace the binary
darkbloom update
```

`darkbloom update` (`provider-swift/Sources/darkbloom/UpdateCommand.swift`)
queries `/v1/releases/latest`, verifies the bundle/binary/metallib hashes, and
replaces the running binary. If the launchd service is loaded, the update path
restarts it automatically.

To enable automatic update checks at every startup:

```bash
darkbloom autoupdate enable
```

To disable:

```bash
darkbloom autoupdate disable
```

Auto-update is controlled by `provider.auto_update` in `provider.toml`
(`provider-swift/Sources/darkbloom/AutoUpdateCommand.swift`).

## Uninstalling

```bash
# If experimental fan control was enabled, restore Auto and remove it first
sudo darkbloom fan uninstall

# Stop the daemon and remove the launchd plist
darkbloom stop --uninstall

# Remove the MDM profile (System Settings must be used for the actual removal)
darkbloom unenroll

# Remove local data (optional)
rm -rf ~/.darkbloom
rm -rf ~/.config/darkbloom
```

`darkbloom stop --uninstall` (`provider-swift/Sources/darkbloom/StopCommand.swift`)
disarms the crash-recovery watchdog and removes the launchd user agent.
It deliberately does not remove the separately opted-in root fan helper; use the
fan-specific uninstall command above.
`darkbloom unenroll` opens System Settings → Device Management so you can remove
the profile.

## Troubleshooting installation

| Issue | Cause | Fix |
|---|---|---|
| `Error: Darkbloom requires macOS with Apple Silicon` | Wrong OS or architecture | Run on an Apple Silicon Mac |
| `Bundle hash mismatch` | Corrupted download or tampered bundle | Re-run the installer; check `/v1/releases/latest` |
| `Code signature could not be verified` | Binary unsigned or modified | Re-download from the coordinator |
| `darkbloom: command not found` | `PATH` not updated | `source ~/.zshrc` or add `~/.darkbloom/bin` to `PATH` |
| `Coordinator unreachable` | Firewall / DNS / coordinator maintenance | Check `curl https://api.darkbloom.dev/health` |
