# Experimental Fan Control

`darkbloom fan` is an opt-in cooling controller for Apple Silicon provider Macs.
It ships dormant: installing or updating Darkbloom does not request `sudo`, create
root files, register a background service, or write to AppleSMC.

This feature uses undocumented AppleSMC interfaces and is experimental. A Mac is
eligible only when Darkbloom detects at least one fan and a known GPU-temperature
sensor for its M1-M5 chip family. Fanless and unknown hardware remains under macOS
automatic control.

## Commands

```bash
# Read-only; no sudo required
darkbloom fan status
darkbloom fan diagnose --json

# Explicit opt-in with defaults: 80% at 45 C
sudo darkbloom fan enable

# Normal targets are restricted to 60-90% of each fan's reported maximum
sudo darkbloom fan configure --speed 70 --temperature 50

# Both commands restore and verify macOS automatic control
sudo darkbloom fan disable
sudo darkbloom fan uninstall
```

`enable` must be run through `sudo` from the account that runs the provider. The
numeric `SUDO_UID` and the account's directory-service `GeneratedUID` bind the
system helper to that account; `$HOME` and `SUDO_USER` are not trusted for this decision
(`provider-swift/Sources/darkbloom/Fan/FanServiceManager.swift`).

## Control Policy

The default policy is:

| Setting | Default |
|---|---|
| Engage | Hottest validated GPU sensor at or above 45 C for 3 samples |
| Release | All validated GPU readings at or below 40 C for 30 samples |
| Target | 80% of each fan's reported maximum RPM |
| User range | 60-90% |
| Poll interval | 1 second |

Darkbloom first captures each fan's actual, target, minimum, and maximum RPM. It
never lowers the target present at takeover. If macOS already requests more than
the configured percentage, that higher target is retained. Multi-fan changes are
transactional: a partial mode or target failure restores every touched fan.

The policy state machine is in
`provider-swift/Sources/DarkbloomFanCore/FanPolicy.swift`; AppleSMC capability
detection and writes are in `DarkbloomFanCore/FanHardware.swift` and
`DarkbloomFanCore/FanController.swift`.

## Provider-Only Lease

Enabling the helper does not make it control every GPU workload. The signed
provider opens an authenticated XPC session only while a Darkbloom serving loop
is active:

- Public and unified serving acquire a lease around `ProviderLoop.run()`.
- Standalone local serving acquires a lease only after its HTTP socket binds.
- A scheduled provider has no lease outside its availability window.
- Benchmarks and unrelated applications do not acquire a lease.

The provider renews every 5 seconds and the helper expires the lease after 15
seconds. Provider stop, crash, schedule cancellation, XPC interruption, or a
downgrade to a version without lease support restores automatic control. See
`provider-swift/Sources/darkbloom/FanActivityLease.swift` and the call sites in
`StartCommand+Modes.swift`.

Both XPC peers pin the exact Developer ID team and signing identifiers using
macOS code-signing requirements. The helper also requires the configured user ID.
The interface exposes only lease, status, and root-only automatic restoration; it
does not expose arbitrary SMC reads or writes
(`DarkbloomFanProtocol/FanIPC.swift`, `DarkbloomFanHelper/FanXPCService.swift`).

## Safety And Recovery

The helper restores macOS automatic mode when:

- the provider lease ends or expires;
- GPU sensors disappear or return invalid data;
- macOS reports serious or critical thermal pressure;
- a mode, target, or verification write fails;
- the machine sleeps or the helper receives a termination signal;
- the administrator disables or uninstalls the feature.

Before the first possible manual-mode write, the helper durably records the fan
indices it may touch. A launchd restart after `SIGKILL` reads this root-owned
journal and restores those fans before accepting a new lease. `Ftst` is cleared
only when Darkbloom recorded possible ownership. The journal implementation is in
`DarkbloomFanService/FanDurableFile.swift` and `FanOwnershipRecovery.swift`.

Darkbloom refuses to take over a fan or global `Ftst` gate already held by
another fan-control application. Stop that application and restore its Auto mode
before enabling Darkbloom.

## Privileged Files

Explicit enablement creates only these root-owned files:

| Path | Purpose |
|---|---|
| `/Library/PrivilegedHelperTools/io.darkbloom.fan-helper` | Minimal signed SMC helper |
| `/Library/LaunchDaemons/io.darkbloom.fan.plist` | System launchd job |
| `/Library/Application Support/Darkbloom/fan-policy.json` | Validated policy and provider UID |
| `/Library/Application Support/Darkbloom/fan-session.json` | Crash-recovery ownership journal, present only while control may be active |

The helper links only the fan core, XPC protocol, Foundation, IOKit, and Security.
It has no coordinator client, network code, provider credentials, model access,
or prompt access.

## Updates And Rollback

The signed application bundle contains a dormant helper, but the unprivileged
self-updater never replaces the root-installed copy. A compatible helper keeps
working; a protocol mismatch grants no lease and leaves the fans in Auto. Run
`sudo darkbloom fan enable` again to install a newer bundled helper.

The release workflow, installer, and self-updater require agreement between the
CLI capability string, sealed `fan-helper-v1` marker, nested executable mode, and
the helper's exact Developer ID signature. Pre-v0.7.9 bundles with none of these
remain valid rollback targets.

## Hardware Coverage

The command is distributed to all supported Apple Silicon providers, but active
control is capability-gated. GPU sensor names are private and change between chip
families. `darkbloom fan diagnose --json` reports exactly which sensors and fans
were detected. Do not describe a machine family as validated until a real-device
test has covered engage, release, provider stop, sleep/wake, helper restart, and
uninstall restoration.

Current v0.7.9 evidence:

| Hardware | Validation |
|---|---|
| M3 Max MacBook Pro (`Mac15,9`, macOS 26.4) | Active control validated: eight GPU sensors, per-fan 80% targets, provider-lease restoration, forced helper `SIGKILL` recovery, reconnect, and uninstall Auto verification |
| M4 Max MacBook Pro (`Mac16,5`) | Read-only discovery validated; active control not yet exercised |
| Other M1-M5 models | Catalog support is implemented but remains unvalidated; `enable` fails closed when required keys or plausible GPU sensors are absent |
