# Provider Troubleshooting

Start every troubleshooting session with:

```bash
darkbloom doctor --strict
darkbloom status
darkbloom logs --last 1h
```

## Installation issues

### `darkbloom: command not found`

The installer adds `~/.darkbloom/bin` to `~/.zshrc` (or `~/.bashrc`). Either open
a new shell or run:

```bash
source ~/.zshrc
```

### Bundle or binary hash mismatch

Re-run `darkbloom update` or reinstall with the one-liner. The coordinator's
`/v1/releases/latest` record is the source of truth for expected hashes
(`scripts/install.sh:67-155`).

### Code signature warning

If `codesign --verify` fails, the binary may be modified or the Gatekeeper cache
is stale. Re-download from the coordinator and verify again.

## Startup issues

### `darkbloom start` fails immediately

Preflight checks are in
`provider-swift/Sources/darkbloom/StartCommand.swift:429-448`.

| Error | Fix |
|-------|-----|
| `SIP disabled` | Reboot to Recovery and run `csrutil enable` |
| `A debugger is attached` | Detach the debugger; the coordinator rejects debugged providers |
| `This Mac has <8 GB RAM` | Upgrade RAM or use a different machine |
| `Metal device not found` | Run on Apple Silicon with a working GPU |
| `No models selected` | Run `darkbloom models catalog`, download a model, or pass `--model` |

### The daemon does not stay running

```bash
# Check if launchd loaded the agent
launchctl list | grep darkbloom

# View launchd logs
log show --predicate 'subsystem == "dev.darkbloom.provider"' --last 30m

# If the watchdog is misbehaving, stop cleanly and reinstall
darkbloom stop --uninstall
darkbloom start
```

Common causes:

- The user logged out, killing the GUI launchd agent. Enable automatic login and
disable auto-logout-after-idle.
- A crash triggered the watchdog; `darkbloom status` shows the recovery state.
- `auto_restart = false` in `provider.toml`.

## Connection issues

### `WebSocket connection failed`

```bash
curl -v https://api.darkbloom.dev/health
```

Check DNS, TLS certificates, date/time, and any corporate firewall that blocks
port 443.

### Provider shows offline in the console

```bash
darkbloom status        # is the daemon running?
darkbloom logs --last 1h
```

Possible causes:

- Network interruption.
- Coordinator restart (provider reconnects automatically).
- The provider was marked `untrusted` after failing attestation challenges.
- The provider version is below the coordinator's minimum; run `darkbloom update`.

### Heartbeat timeout / forced reconnect

If the outbound path is wedged, the provider keeps heartbeating but cannot
answer challenges. After six consecutive timeouts the coordinator closes the
connection (`coordinator/api/provider.go:69`). A manual `darkbloom restart`
usually clears it.

## Attestation issues

### `trust_level` stays `self_signed`

`hardware` trust requires MDM/ACME/MDA verification. Run:

```bash
darkbloom enroll
```

Install the profile in System Settings → Device Management, then wait a few
minutes and re-run `darkbloom doctor`.

### Code-identity attestation never passes

Code identity requires a real macOS Aqua session. Check:

```bash
darkbloom doctor
```

Look for the "attestation readiness" section
(`provider-swift/Sources/ProviderCore/Diagnostics/AttestationReadiness.swift`).
Required:

- A real console user (not `loginwindow` or `root`).
- Automatic login enabled.
- Auto-logout-after-idle disabled.

If the machine reboots to the login window, APNs registration will not succeed
until someone logs in.

### `mdm_verified: false` but profile is installed

MDM SecurityInfo queries can time out, especially on sleeping devices. The
coordinator retries after the next successful challenge
(`coordinator/api/provider.go:1413-1427`). If it persists, remove and re-add the
profile with `darkbloom unenroll` / `darkbloom enroll`.

## Model issues

### `Model not found`

```bash
# List supported models
darkbloom models catalog

# List local models
darkbloom models list

# Download the model
darkbloom models download <id>
```

### `Insufficient memory headroom to load model`

The provider load gate requires `weights_gb + 2 GB` of free memory after the OS
reserve (`provider-swift/Sources/ProviderCore/Inference/ModelLoadAdmission.swift:19-24`).

Fixes:

- Close other applications.
- Reduce `backend.max_model_slots` so fewer models are resident.
- Increase `provider.memory_reserve_gb` only if you want the provider to be more
  conservative.
- Serve a smaller quantized model.

### Model load failures after a catalog update

The coordinator may have published a new build for an alias. The provider fetches
the new desired builds via `desired_models` and prefetches them. If a build
fails, check `darkbloom logs` for the mismatch and run `darkbloom models remove
<id>` followed by `darkbloom models download <id>`.

## Performance issues

### Low throughput

```bash
darkbloom benchmark --model <id> --iterations 5
darkbloom status
```

Common causes:

- Thermal throttling on a laptop.
- Memory pressure causing excessive swapping.
- Another application is using the GPU.
- The model is too large for the machine's memory bandwidth.

### High TTFT (time-to-first-token)

- Cold start: the model was not loaded. Subsequent requests will be faster.
- The coordinator's TTFT deadline includes a speculative backup dispatch at 50%
of the deadline (`coordinator/api/consumer.go:72-76`).
- Network latency to the coordinator increases dispatch time.

## Billing / earnings issues

### Earnings not updating

- Confirm the provider is online and routed traffic (`darkbloom status`).
- Usage can take a few minutes to appear in the console.
- Stripe Connect onboarding must be complete before payouts.

There is no `darkbloom earnings` CLI command; use the console.

### Self-route request failed

Self-route never falls back to the paid fleet. Common errors:

| Error code | Meaning | Fix |
|------------|---------|-----|
| `no_linked_machine` | No provider linked to your account | Run `darkbloom login` on your Mac |
| `machine_offline` | Linked provider is offline | Start the provider |
| `model_not_loaded` | Your provider does not advertise this model | Download/load the model |
| `machine_busy` | Your provider is at capacity | Retry later or reduce load |

See [self-route](./self-route.md) for details.

## Collecting a support bundle

```bash
darkbloom doctor --support > doctor.txt
darkbloom status --config ~/.config/darkbloom/provider.toml > status.txt
darkbloom logs --last 24h > logs.txt
```

Or upload logs directly to the Darkbloom team:

```bash
darkbloom report --last 6h
```

The report includes only `dev.darkbloom.provider` unified logs and is indexed by
your device's serial number.
