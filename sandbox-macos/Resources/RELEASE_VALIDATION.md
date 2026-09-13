# Sandbox release and validation

The scripts prepare artifacts and evidence. A passing signature or unit suite
does not establish production isolation or deployment readiness.

## Build artifacts

Run from the repository root with a new output directory:

```sh
python3 sandbox-macos/Scripts/package-sandbox-release.py \
  --output /absolute/new/development-package
```

The default is an ad-hoc host and guest package. The production guest agent
intentionally rejects ad-hoc identity. Use `--sign` for the installed Eigen Labs
Developer ID identity. Add `--profile` only with an unexpired all-devices profile
that explicitly authorizes `SLDQ2GJ6TL.io.darkbloom.sandbox`; the provider's
`io.darkbloom.provider` profile is rejected. Without that profile, the host gets
only development virtualization entitlements and makes no persistent-keychain
claim. `--binary-directory` stages previously built release products and records
their source directory; final signed hashes remain in the release manifest.

Add `--lume-runtime /absolute/pinned/runtime` to include a complete immutable
Lume tree from `build-pinned-lume.sh`. Both its executable and separately signed
provenance must match the audited lock. The packaging script uses `ditto` to
preserve signing extended attributes and does not re-sign any Lume artifact.
Distribute with a format preserving those attributes, such as a `ditto` archive.
The release manifest is separately signed and covers the guest bootstrap files.

For a host, Lume, or tooling update that retains an already qualified guest,
add `--guest-release /absolute/existing/signed-release`. Packaging verifies that
release's signed manifest, complete file inventory, guest code identity and safe
metadata, then copies its four guest artifacts with their exact hashes and
signing xattrs. It does not re-sign the reused guest or require a newly built
guest binary. `guest_origin` records the source manifest and guest hashes.
The template retains its original manifest hash as provenance and compares all
four guest artifact hashes for reuse. Changing any guest binary, bootstrap
script, installer, or LaunchDaemon plist requires fresh base qualification.
Re-signing an unchanged guest binary can change its hash and is not reuse.

## Guest base image

Copy the complete `guest` directory into a fresh, disposable macOS VM and run
`/bin/zsh install-sandbox-guest.sh --install --retire-lume-bootstrap` as guest root. It verifies the guest
signature, rejects identity collisions, creates the nonadmin UID/GID 2001, and
stages a LaunchDaemon without starting it. The script refuses physical hosts.
It retires only the expected `lume` UID 501 bootstrap account, removes its known
passwordless sudo rule, and disables SSH on future boots. Unexpected users or
sudo policy fail closed. The provisioning session may finish; shut down the
prepared base before cloning it for tenants.
Installation stages a one-column `workspace` manifest under `/etc/synthetic.d`.
macOS synthesizes this empty root mountpoint at the next boot; the installer
does not attempt to create a physical directory on the sealed root filesystem.
Conflicting workspace symlink definitions or duplicate manifests are rejected.
The signed installer disables and unloads `com.vix.cron` and `com.apple.atrun`,
and provisions root-owned `cron.allow` and `at.allow` containing only `root`.
The guest verifies both allowlists, the explicit launchd disabled overrides,
and absent scheduler services before admitting commands. Tenant cleanup removes
only `gui/2001` (the login-domain alias) and `user/2001`, then kills tenant UID
processes and rechecks domain absence. Unknown launchctl diagnostics fail closed;
this output format and a submitted-job respawn probe require qualification on
each supported guest OS. No physical-host scheduler configuration is changed.
There is no Python, package manager, or Xcode dependency inside the guest.

Bootstrap uses native macOS tools. It requires exactly one read-only APFS volume
named `DBCONTROL` and one separate writable APFS volume named `DBWORK`.
`DBCONTROL/instance.json` must be mode 0600 and single-link. It may be owned by
root or the host broker's numeric UID, provided that UID is neither 2001 nor
assigned to any non-root guest account. Guest root copies it into root-owned
0600 state before admitting work:

```json
{
  "version": 1,
  "instanceID": "per-instance UUID",
  "credential": "32 random bytes encoded as base64",
  "workspacePath": "/workspace",
  "workspaceDiskBytes": 26843545600,
  "tenantUID": 2001,
  "tenantGID": 2001
}
```

The workspace disk's whole-device byte size must exactly match
`workspaceDiskBytes`. Its APFS usable capacity will be smaller due to metadata.
Bootstrap first quiesces surviving tenant processes, then mounts at `/workspace`.
The native supervisor repeats cleanup before preparing root:GID2001 mode 1770
and `.tmp` through nofollow directory descriptors; tenant-controlled symlinks
cannot redirect privileged ownership or mode changes. Credentials stay in a root-only directory and are
never supplied as command arguments or logged. Missing, duplicated, writable
control media or mismatched workspace capacity prevents guest-agent startup.
The base image must not contain per-instance credentials or tenant data.
Actual boot/media behavior must be validated in the signed VM campaign.

The packaged `tools/prepare-sandbox-instance.py` creates materials as the
unprivileged host broker. No root helper is required per VM:

```sh
/usr/bin/python3 tools/prepare-sandbox-instance.py \
  --output /absolute/owned-vm/.darkbloom-guest \
  --instance-id 60f6a1b2-77db-40d2-bf27-98fce61c8b0d --workspace-gib 25
```

Its stdout names the public material manifest. The separate `broker.json` is
mode 0600 and contains the random 32-byte credential. The generator verifies
raw image sizes and reads back the private control configuration through its
own read-only attachment, which it then detaches. It reserves full image sizes
plus 20 GiB of free space. `--plan-only` prepares inputs without creating images.
Use a new directory after a partial failure; failed materials are retained for
reconciliation. The backing APFS volume must have verified FileVault encryption
before credentials are written. The raw disks have no separate per-image
encryption. The artifact codec and per-VM cryptoerase are not integrated into
this preparation path; the manifest records those boundaries separately.

## Prepare a dedicated host

`prepare-sandbox-host.py` consumes a signed, provisioned package, explicit
installation destination and non-secret configuration. It writes launchd
configuration and an installation plan; it creates no account or service.

```json
{
  "coordinatorURL": "wss://your-coordinator/v1/sandbox-hosts/ws",
  "hostID": "assigned host UUID",
  "tokenFile": "/var/db/darkbloom-sandbox/host.token",
  "storageDirectory": "/var/db/darkbloom-sandbox/vms",
  "capacityDirectory": "/var/db/darkbloom-sandbox/capacity",
  "baseImageIDs": ["approved-base-image-id"],
  "maximumCPUCount": 8,
  "maximumMemoryGiB": 32,
  "maximumGrowthGiB": 320,
  "storageHeadroomGiB": 20
}
```

```sh
python3 sandbox-macos/Scripts/prepare-sandbox-host.py \
  --package /absolute/signed-package --configuration /absolute/host.json \
  --install-root '/Library/Application Support/DarkbloomSandbox/0.1.0' \
  --output /absolute/new/install-plan
```

Use `--verify-installed` in place of `--output` after operator installation.
The broker must have its own non-root account, immutable root-owned executable
tree, private APFS state/storage and a private token file. A host running the
inference provider must not be converted implicitly. Confirm Aqua-session and
provisioned-keychain behavior under the actual launchd identity before admission.
The private staging root is 0700; installation must explicitly normalize public
code directories to 0755, data to 0644 and executables to 0755 so the broker can
read and traverse them. Preserve the pinned Lume subtree's 0555/0444 modes and
signing xattrs. The installed verifier rejects inaccessible roots, symlinks,
hard-linked code files and extended ACLs. Token/state paths remain 0600/0700.

Machine ownership is separately provisioned under
`/Library/Application Support/Darkbloom/runtime`: root-owned directory mode 0750,
group `darkbloom_runtime`, and an empty root-owned single-link `ownership.lock`
mode 0660 in that group. Only broker/provider service identities join the group.
Preserve the inode across upgrades. Inference holds shared ownership through
engine cleanup; sandbox service and actual VM owner processes retain exclusive
ownership. Existing providers that started before installation need a separately
authorized restart into the coordinated implementation before activation.

Activation is an offline local operation. A draining broker still holds the
machine's exclusive runtime lease, and its launchd `KeepAlive` policy restarts
a killed process. The generated `activate-sandbox-offline.sh --activate` runs
this ordered sequence only when explicitly invoked by a root operator:

```sh
/bin/launchctl bootout system/io.darkbloom.sandbox
/usr/bin/sudo -u _darkbloom_sandbox -- /absolute/installed/DarkbloomSandbox.app/Contents/MacOS/darkbloom-sandboxd host-mode --storage /absolute/private/vms --capacity-dir /absolute/private/capacity --mode sandbox_dedicated
/bin/launchctl bootstrap system /Library/LaunchDaemons/io.darkbloom.sandbox.plist
```

The plan substitutes the configured paths. Initialize a new capacity store
in draining mode first, then unload the service before changing its mode.
The mode command must obtain exclusive ownership and refuses while an inference
provider or surviving sandbox VM still holds authority. A failure leaves the
service offline; it does not bootstrap automatically or stop other workloads.
If already unloaded, first verify that state and run only the final two commands.

## Retain validation evidence

```sh
python3 sandbox-macos/Scripts/validate-sandbox.py \
  --output /absolute/new/evidence --coordinator
```

The default runs release, consumer-harness and benchmark-tool tests, Lume publication contracts, separate-process
host runtime ownership tests and serialized Swift tests. `--coordinator` adds Go race tests for sandbox control, host auth,
storage, protocol and API integration. Logs and their hashes, command exit
codes, source digest before/after, skip mentions and untested gates are retained
in `evidence.json`. A source change during a run prevents a clean exit. Inherited
live-test environment flags are removed; optional VM work always needs explicit
arguments. Failures stop later stages while retaining prior evidence.

Optional stages:

- `--lume PATH`: real pinned binary and empty-storage contracts.
- `--live-restore`: entitled Apple restore-catalog request.
- `--prepare-base --lume PATH --storage DIR --ipsw FILE`: creates/prepares a
  no-secrets base VM in the explicitly selected directory.
- `--two-vms --lume PATH --storage DIR`: clone, concurrent execution, cancellation,
  isolation marker and teardown proof using the prepared base.
- `--consumer-config FILE`: real consumer CLI acceptance against an explicitly
  configured nonproduction deployment; creates two new sandboxes and waits for
  natural lease expiry (currently 30 minutes). No services or hosts are installed.
- `--workspace-exhaustion` together with `--consumer-config`: write up to the
  configured workspace plus 1 GiB inside one newly created guest, require ENOSPC,
  delete only that unique test file, and prove control/upload/read recovery.
  This opt-in is required for physical quota acceptance; the command has a
  900-second limit. No host filesystem path is used as the write destination.

The last two stages use the existing development VM proof. They do not prove
the production guest channel, network policy, workspace exhaustion, host-owner
privacy, production keychain persistence or post-reboot cleanup. Name those
separate gates in release evidence until their actual physical tests pass.
Notarization is never inferred or submitted by these scripts.

The consumer harness can also run independently:

```sh
python3 -B sandbox-macos/Scripts/test-sandbox-live.py \
  --config /absolute/lab.json --output /absolute/new/consumer-evidence
```

Set `DARKBLOOM_API_KEY` in the process environment. A configuration has this
shape; replace the binary path, coordinator origin, qualified image and host ID
with the explicit disposable deployment. HTTP requires a loopback origin plus
`allow_insecure_localhost: true`; known production origins are refused.

```json
{
  "environment": "nonproduction",
  "api_url": "https://sandbox-lab.example",
  "cli": "/absolute/darkbloom-sandbox",
  "base_image_id": "qualified-test-base-v1",
  "host_id": "31dbb7e8-3332-4dc3-b882-5a9c5c6b0fb0",
  "cpu": 4,
  "memory_gib": 8,
  "workspace_gib": 25,
  "readiness_seconds": 600,
  "expiry_seconds": 2100
}
```

The harness checks multichunk binary round trips, cross-instance denial with
working positive controls, tenant identity, scheduler and sudo denial, absent
non-loopback IP interfaces, bounded output, timeout/cancellation cleanup,
stop/start persistence, overlapping jobs, delete and real expiry. It saves raw
CLI output with hashes, per-case status, create idempotency keys before mutation,
and a scoped cleanup ledger. An uncertain create is reconciled with its original
key. Cleanup addresses only IDs returned to this run, never a global list.
An API `deleted` state does not prove physical directory cleanup: retain the
matching host inventory separately. Host assignment is operator-provided because
the current CLI output omits host ID. Without `--workspace-exhaustion` (or
`workspace_exhaustion: true` in its explicit configuration), the summary retains
`workspace_exhaustion` under `not_covered`. The suite does not replace
scheduler-respawn, crash/reboot, or release-signature tests.
