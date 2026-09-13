# Fan control (experimental)

> Last updated: 2026-09-03 · commit `5d400cf75`

Hold the fans of an Apple Silicon Mac at a fixed speed while the provider is
serving and the GPU is hot, so thermal throttling does not cut decode
throughput. For operators who run the daemon on a Mac they own; the result is
a root helper that engages above a GPU-temperature threshold and hands control
back to macOS whenever the provider stops. Optional: inference never depends on
it.

## Prerequisites

- Provider installed from a signed `Darkbloom.app` release
  ([installation](./installation.md)). `darkbloom fan enable` refuses to run
  from a bare binary: it locates `Darkbloom.app/Contents/Helpers/darkbloom-fan-helper`
  relative to its own executable and verifies the app, the CLI and the helper
  together (`provider-swift/Sources/darkbloom/Fan/FanServiceManager+Install.swift`,
  `bundledHelperURL`, `verifyBundledApp`).
- The build advertises the capability: `scripts/install.sh` requires the CLI
  marker string, the file `Contents/Resources/darkbloom-runtime-capabilities/fan-helper-v1`
  and the nested helper (signed to `identifier "io.darkbloom.fan-helper"`,
  Team `SLDQ2GJ6TL`, mode `0755`) to be present together
  (`verify_fan_helper_capability`).
- A Mac with SMC-controllable fans and GPU temperature sensors; fanless
  machines (MacBook Air) report `unsupported`.
- Administrator rights: `enable`, `configure`, `disable` and `uninstall` run
  through `sudo` from the provider's user account.

## Steps

1. Check what the hardware exposes (no root needed):

   ```bash
   darkbloom fan diagnose          # chip, fans, GPU sensors, supported: true/false
   darkbloom fan diagnose --json
   ```

   `Fan.diagnosticReport` (`provider-swift/Sources/darkbloom/Fan/FanCommand.swift`)
   opens the SMC read-only through `AppleSMCBackend`
   (`provider-swift/Sources/DarkbloomFanCore/SMCBackend.swift`) and lists every
   fan and GPU temperature key. `supported` is true only when both lists are
   non-empty.

2. Install and enable the helper:

   ```bash
   sudo darkbloom fan enable                          # policy defaults (table below)
   sudo darkbloom fan enable --speed 70 --temperature 50
   ```

   `--speed` is a percentage of each fan's maximum RPM; `--temperature` is the
   engage threshold in °C, and the release threshold sits a fixed margin below
   it (`FanPolicyConfiguration`, `provider-swift/Sources/DarkbloomFanCore/FanPolicy.swift`).
   Defaults and the accepted speed range are in
   [`cli-reference.md` → `darkbloom fan`](./cli-reference.md#darkbloom-fan).
   `FanServiceManager.enable` (`provider-swift/Sources/darkbloom/Fan/FanServiceManager.swift`)
   requires `geteuid() == 0` and a non-root `SUDO_UID` naming the provider
   account (error otherwise: `run this command through sudo from the provider
   account (SUDO_UID is required)`); it verifies the bundled helper's code
   signature, restores automatic control on any helper already loaded, then
   copies the helper to `/Library/PrivilegedHelperTools/io.darkbloom.fan-helper`,
   writes `/Library/LaunchDaemons/io.darkbloom.fan.plist` and
   `/Library/Application Support/Darkbloom/fan-policy.json` (`0600`, records
   `enabled`, the configured UID and policy), and bootstraps the LaunchDaemon.

3. Serve. Every serve path — the LaunchAgent daemon, `--foreground` and
   `--local` — wraps its run in `withFanActivityLease`
   (`provider-swift/Sources/darkbloom/StartCommand+Modes.swift`;
   `provider-swift/Sources/darkbloom/FanActivityLease.swift`). The provider
   asks the helper for a short lease and renews it well inside its lifetime
   (`FanIPC.leaseDurationSeconds`, `renewalIntervalSeconds`,
   `provider-swift/Sources/DarkbloomFanProtocol/FanIPC.swift`; values in
   [runtime constants](./cli-reference.md#runtime-constants)); a missing or
   failing helper is logged and ignored.

4. Adjust later without reinstalling:

   ```bash
   sudo darkbloom fan configure --speed 85
   sudo darkbloom fan configure --temperature 55
   ```

   At least one option is required (usage error otherwise). `configure`
   rewrites `fan-policy.json` and, if the daemon is loaded, `launchctl
   kickstart -k system/io.darkbloom.fan` so it re-reads the policy.

## How the helper decides

`FanDaemon` (`provider-swift/Sources/DarkbloomFanHelper/FanDaemon.swift`) ticks
once per second and runs `FanPolicyStateMachine`
(`provider-swift/Sources/DarkbloomFanCore/FanPolicy.swift`):

| Rule | Value |
|---|---|
| Engage | GPU temperature ≥ `--temperature` for the engage sample count **and** a provider lease is active |
| Release | temperature ≤ the release threshold below `--temperature` for the release sample count, or the lease lapses |
| Speed while engaged | `--speed` % of each fan's maximum RPM, within the allowed range |
| No lease | `waiting_for_provider`: fans stay under macOS control even when hot |
| Lease lapse | Without a renewal inside `leaseDurationSeconds` (provider stopped, crashed, slept) the helper restores automatic control |
| Defaults | Trigger and release temperatures, speed and its range, sample counts, lease and renewal periods: [`cli-reference.md` → Runtime constants](./cli-reference.md#runtime-constants) |
| Safety | If a reading fails or the SMC refuses a write the helper restores automatic control and reports `safety_override` / `error` |

Modes reported by `fan status` are `disabled`, `waiting_for_provider`,
`waiting_for_temperature`, `manual`, `safety_override`, `unsupported`, `error`
(`FanServiceMode`). The helper journals ownership in
`/Library/Application Support/Darkbloom/fan-session.json` so a crash or reboot
mid-override is reconciled on the next start
(`provider-swift/Sources/DarkbloomFanService/FanOwnershipRecovery.swift`).

Only signed Darkbloom code can talk to the helper: the XPC service
`io.darkbloom.fan` (`FanIPC.machServiceName`) checks the connecting process's
Team ID against `FanIPC.teamID` = `SLDQ2GJ6TL`
(`provider-swift/Sources/DarkbloomFanService/FanPeerAuthentication.swift`),
and the helper itself is verified against the same Team-ID requirement before
installation.

## Verify

```bash
darkbloom fan status          # capability, installed, loaded, mode, policy, temperatures, fans
darkbloom fan status --json
sudo launchctl print system/io.darkbloom.fan | head
```

With the provider serving and the GPU above threshold for a few seconds,
`mode` moves from `waiting_for_temperature` to `manual` and the fan RPM column
rises to the configured percentage. Stop the provider (`darkbloom stop`); once
the lease lapses the mode returns to `waiting_for_provider` and macOS controls
the fans.

## Disable and uninstall

```bash
sudo darkbloom fan disable     # restore automatic control; keep helper + LaunchDaemon installed
sudo darkbloom fan uninstall   # disable, then remove plist, helper and fan-policy.json
```

`uninstall` runs `disable` first and refuses to continue while
`fan-session.json` still records an override it could not undo
(`ownership journal remains after restore; refusing to remove recovery
material`) — fix the SMC problem `fan status` shows, then retry.
`darkbloom stop --uninstall` and the installer never touch these root-owned
files, and the unprivileged self-updater cannot replace the helper: after
`darkbloom update` run `sudo darkbloom fan enable` again so the helper matches
the new app bundle.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `fan: this operation requires administrator privileges; rerun it with sudo` | Not root | Prefix with `sudo` |
| `fan: run this command through sudo from the provider account (SUDO_UID is required)` | Run from a root shell (`sudo -i`) or with `SUDO_UID` stripped | Run `sudo darkbloom fan …` from the provider user's shell |
| `fan: signed fan helper was not found; reinstall Darkbloom` | CLI not running from `Darkbloom.app/Contents/MacOS`, or the helper is missing from the bundle | Reinstall with `scripts/install.sh`; use `~/.darkbloom/bin/darkbloom` |
| `fan: fan helper signature verification failed` | Helper not signed by Team `SLDQ2GJ6TL` | Reinstall from the official release |
| `fan: fan control is unavailable: …` / `supported: false` | No SMC fans or GPU sensors | Nothing to do on this model |
| Fans never engage although the GPU is hot | No provider lease (`fan status` shows `waiting_for_provider`): the daemon is not running, or fewer than 3 consecutive samples were above threshold | `darkbloom status`; `darkbloom restart` |
| `fan status` mode `error` or `safety_override` | SMC write refused or reading failed | `sudo darkbloom fan disable`, check `fan diagnose`, re-enable |
| Fan control stops after an update | Helper is not replaced by the unprivileged updater | `sudo darkbloom fan enable` |

## Related

- [CLI reference](./cli-reference.md) — `darkbloom fan` flag table and helper paths.
- [Installation](./installation.md) — capability markers verified by `scripts/install.sh`.
- [Troubleshooting](./troubleshooting.md) — daemon lifecycle and `doctor`.
- [Hardware requirements](./hardware-requirements.md).
