# Set provider cache writes and storage

> Last updated: 2026-10-08

Set a persistent write limit and optionally store encrypted inference caches on
a separate disk. These commands affect cache payloads; use
[`models location`](cli-reference.md#darkbloom-models-location) for downloaded weights.

## Prerequisites

- Use a storage device you own and trust. Darkbloom does not certify any disk
  model or vendor as free of malicious firmware. The
  [storage trust model](../architecture/security/encryption.md#provider-cache-storage)
  describes what the checks establish and the residual risks.
- The selected disk must be mounted, local, writable APFS with ownership enabled.
  External volumes must use APFS (Encrypted). In Disk Utility, inspect the format;
  Apple documents [supported formats](https://support.apple.com/en-ie/guide/disk-utility/dsku19ed921c/mac).
  Back up existing data before changing a disk's format. Darkbloom does not format
  disks or change their encryption, permissions or mount settings.
- Keep `provider.toml` (including any custom `--config` file) on trusted local storage, separate from the removable cache payloads.
- Use an existing directory owned by your user without group/other write
  permission. On an external volume, ensure **Ignore ownership on this volume**
  is off in Finder's Get Info panel.

## Steps

1. Choose the daily write allowance in decimal GB. For example, `100` permits
   at most 100 GB of reserved cache-file writes in the rolling-day accounting
   window. `0` means unlimited. Failed writes consume their reservation;
   metadata writes and the drive's internal write amplification are additional.
   The [accounting reference](../reference/ssd-kv-cache.md#size-and-eviction-rules)
   defines the window and disk-space safeguards.

   ```sh
   darkbloom cache set --daily-write-gb 100
   ```

2. To select a separate disk, create a private directory on the mounted volume,
   then save it. You can combine both settings in one command:

   ```sh
   mkdir -m 700 "/Volumes/Cache SSD/provider-cache"
   darkbloom cache set --daily-write-gb 100 --directory "/Volumes/Cache SSD/provider-cache"
   ```

   The CLI records the volume UUID. Cache files use its `darkbloom/kv3` child;
   existing files are not copied or removed. A missing or different volume
   disables SSD caching while inference can continue without it.

3. Restart the provider to load the saved settings:

   ```sh
   darkbloom restart
   ```

   If you selected a custom `--config` file, pass that same file to all commands.
   A foreground/local provider needs to be stopped and started with its original
   serving command. The settings are read at process start.

## Verify

```sh
darkbloom cache status
darkbloom cache status --json
```

Check the directory, saved daily allowance and storage result. Status is read-only
and does not establish that an already-running provider reloaded its settings.
Use [runtime cache observations](../reference/ssd-kv-cache.md#verification) to
check caching activity. A valid disk does not imply every model supports caching.

## Troubleshooting

| Result | Action |
|---|---|
| Missing directory / volume | Mount and unlock the original volume, then restart the provider; recreate the private directory only on that volume |
| Volume UUID differs | Reconnect the original disk. To deliberately select a replacement, run `cache set --directory` again |
| Ownership, filesystem or encryption check fails | Inspect the volume and directory properties; do not disable macOS security controls to bypass the check |
| Return to the internal cache | Run `darkbloom cache set --reset-directory`, then restart. This keeps the daily write choice and does not delete the external files |
| Daily cap exhausted | Wait for old reservations to age out or explicitly change the allowance. Restarting or selecting another disk preserves the ledger on the Mac |

## Related

- [CLI reference](cli-reference.md#darkbloom-cache)
- [Configuration fields and defaults](../reference/configuration.md#ssd-prefix-cache)
- [Encryption and device trust](../architecture/security/encryption.md#provider-cache-storage)
