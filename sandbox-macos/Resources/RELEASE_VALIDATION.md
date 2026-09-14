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

Managed raw Apple restore requires the current managed-installer patch and a new
matching signed Lume artifact. `LumeManagedRestoreProcess` retains exclusive
machine ownership in the installer child and sends broker-lifecycle EOF on
cancellation. The native installer cancels `Progress` after installation starts,
waits for its completion, and proves the VM stopped before deleting temporary
files. An unproven stop retains the native owner and files until process exit.
Legacy unattended preparation is a separate path. Unit tests establish process
and cancellation contracts; they do not qualify a real restored base or replace
the accountless installation and disposable-clone checks.

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
signature, rejects identity collisions, leaves UID/GID 2001 unregistered, and
stages a LaunchDaemon without starting it. The script refuses physical hosts.
It retires only the expected `lume` UID 501 bootstrap account, removes its known
passwordless sudo rule, and disables SSH on future boots. Unexpected users or
sudo policy fail closed. Automated base preparation verifies the expected
virtualized `lume` UID501 identity, then passes the pinned unattended preset's
public temporary password to sudo on stdin. It does not assume passwordless
sudo or request a host password. The provisioning session may finish; shut down
the prepared base before cloning it for tenants.
Installation stages a one-column `workspace` manifest under `/etc/synthetic.d`.
macOS synthesizes this empty root mountpoint at the next boot; the installer
does not attempt to create a physical directory on the sealed root filesystem.
Conflicting workspace symlink definitions or duplicate manifests are rejected.
The signed installer never creates tenant Directory Services records and does
not alter cron/at spools or system scheduler services. Its native identity check
uses reentrant password/group lookups, with buffers bounded at 1 MiB: only
successful absent results permit UID/GID 2001. Lookup errors and registered IDs
fail closed. The same check runs at agent startup, before every command and
inside the privileged worker before it drops credentials. Apple's cron/at
submission tools require a resolvable password-database identity; verify both
list and actual submission denial, including forged `USER` and `LOGNAME`, on
each supported guest OS. Tenant cleanup removes
only `gui/2001` (the login-domain alias) and `user/2001`, then kills tenant UID
processes and verifies quiescence. The GUI domain must be absent. macOS lazily
recreates an empty user domain when queried: only after successful user-domain
bootout and zero tenant processes, a strictly parsed `user/2001` domain with
empty services, unmanaged-process and endpoint blocks is also accepted. Unknown,
truncated, malformed or nonempty launchctl output fails closed;
this output format and a submitted-job respawn probe require qualification on
each supported guest OS. This does not establish cancellation of every possible
system service or delegated queue; VM stop/delete remains the outer boundary.
No physical-host scheduler configuration is changed.
There is no Python, package manager, or Xcode dependency inside the guest.
The offline CPU profile intentionally has no tenant username. Account-dependent
APIs such as Node `os.userInfo()`, Python `pwd`, `whoami`, and SSH client identity
lookup cannot be assumed compatible. `HOME=/workspace` is explicit, but is not
a password-database entry. Qualification must execute the real required build
tools, file operations, cancellation, and restart under the unregistered UID;
successful `id -u` alone is insufficient.
Native installation helpers report fixed `guest_bootstrap.<stage>.<reason>`
diagnostics, with a numeric errno for filesystem failures. They never print
configuration contents. `/etc`, `/var` and `/tmp` use only their known physical
`/private` aliases, followed by descriptor traversal that rejects other symlinks.

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
  "coordinatorURL": "wss://your-coordinator/ws/sandbox-host",
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

Run `--verify-installed` as root in place of `--output` after operator installation:

```sh
sudo /usr/bin/python3 sandbox-macos/Scripts/prepare-sandbox-host.py \
  --package /absolute/signed-package --configuration /absolute/host.json \
  --install-root '/Library/Application Support/DarkbloomSandbox/0.1.0' \
  --verify-installed
```

The broker must have its own non-root account, immutable root-owned executable
tree, private APFS state/storage and a private token file. A host running the
inference provider must not be converted implicitly. Confirm Aqua-session and
provisioned-keychain behavior under the actual launchd identity before admission.
The private staging root is 0700; installation must explicitly normalize public
code directories to 0755, data to 0644 and executables to 0755 so the broker can
read and traverse them. Preserve the pinned Lume subtree's 0555/0444 modes and
signing xattrs. The installed verifier rejects inaccessible roots, symlinks,
hard-linked code files and extended ACLs. Token/state paths remain 0600/0700.

The broker is a trusted nonadmin host service. A separate account protects
private owner-only state. The broker retains access to other host files allowed
by Unix permissions.
macOS can grant ambient local-account, public-share and print-operator access
through nested groups; `InitGroups=false` does not establish their removal.
Inspect both explicit and resolved memberships, exclude explicit privileged
memberships, and verify the actual service's file access when qualifying a host.
The verifier requires a root reader for the protected authentication attribute.
It checks hidden/nonlogin settings, the `/var/empty` home (including its known
`/private/var/empty` spelling), dedicated Unix user/group consistency, native
admin/wheel nonmembership and runtime-group membership. Supported disabled
authentication shapes are the standalone `DisabledUser` marker and fully
disabled ShadowHash wrappers; active or unknown authority entries, missing
protected attributes and unrecognized membership responses fail verification.
It reports account-policy validation, without claiming to strip ambient groups.
`sandbox_dedicated` controls workload admission and ownership of the machine;
it does not remove these Unix permissions. Tenant commands remain inside the VM
under their separate numeric identity.

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
- `--second-account` together with `--consumer-config`: also require private
  `DARKBLOOM_SECONDARY_API_KEY`; create, exercise and delete a second account's
  sandbox between creation of primary VMs 1 and 2. At most two VMs are allocated
  concurrently. Without this option, second-account ownership remains untested.
- `--workspace-exhaustion` together with `--consumer-config`: write up to the
  configured workspace plus 1 GiB inside one newly created guest, require ENOSPC,
  delete only that unique test file, and prove control/upload/read recovery.
  This opt-in is required for physical quota acceptance; the command has a
  900-second limit. No host filesystem path is used as the write destination.

`--prepare-base` and `--two-vms` use the development VM proof. They do not prove
the production guest channel or its tenant policies. `--consumer-config` uses
the actual configured consumer API and host; retain its signed artifact identities
and physical host inventory with the selected observations. Consumer success
does not establish host-owner privacy, production keychain persistence or
post-reboot cleanup. Notarization is never inferred or submitted by these scripts.

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

Add `--second-account` to the standalone command and supply a distinct
`DARKBLOOM_SECONDARY_API_KEY` privately to select account isolation. The
[version-2 acceptance fixture](../../docs/developer/sandbox-acceptance.md) seeds
both ordinary consumers and selects this option automatically. Version-1
primary-only fixtures remain usable without claiming this gate.

The harness checks multichunk binary round trips, cross-instance denial with
working positive controls, command replay/conflict without duplicate execution,
tenant identity, scheduler and sudo denial, absent non-loopback IP interfaces,
bounded output, timeout/cancellation cleanup, stop/start persistence, overlapping
jobs, delete and real expiry. A bounded file REST adapter starts an upload and
acknowledges one chunk; a fresh CLI process resumes the same transfer ID. This
tests interruption between requests, not a disconnect during an in-flight request.
Additional cases verify partial abort without publication, committed-abort denial
without data loss, and stale download-version rejection after a tenant mutation,
followed by an exact new-version download. REST probes use the same account key
and only sandbox IDs owned by the current run; they do not call raw guest operations.

The second-account case requires 404 for inspect, exec, file download, command
cancellation and deletion against primary VM 1. It also proves successful own
inspect/exec/upload/download/cancel/delete, then rechecks primary execution and
file access. Only IDs created by this campaign are used. The second account has
its own `second-account/ownership.json` create-key ledger and cleanup, including
uncertain-create replay; the primary key never deletes its resources. Failed
second-account cleanup blocks primary VM 2 creation. `second-account/account-isolation.json`
indexes that account's evidence and cleanup status.

Natural expiry leaves the second VM ready and submits a long-running process in
its final minute. The harness requires a running observation in the final twelve
seconds, followed by natural deletion and terminal command cleanup. Command
deadlines must fit the lease, so command timeout and lease expiry can race;
`natural-expiry.json` records this limit. There is no Stop, Renew, shortened lease
or clock mutation in this expiry case.

The harness saves raw CLI output and bounded REST responses with hashes,
per-case status, create/replay/transfer identities before requests, and a scoped cleanup
ledger. An uncertain create is reconciled with its original key. Cleanup
addresses only IDs returned to this run, never a global list.
An API `deleted` state does not prove physical directory cleanup: retain the
matching host inventory separately. Host assignment is operator-provided because
the current CLI output omits host ID. Without `--workspace-exhaustion` (or
`workspace_exhaustion: true` in its explicit configuration), the summary retains
`workspace_exhaustion` under `not_covered`. Every summary labels its selected
API/guest observations and retains `production_ready: false`. The closed list in
`sandbox-macos/Scripts/sandbox_live_coverage.py` names separate-account authorization until
that selected case and its cleanup pass, together with
in-flight disconnect recovery, scheduler respawn, broker/host crash and reboot,
physical removal, renewal/drain, CI build performance, cold boot/contention,
release and privacy gates that this suite does not prove.

`test-sandbox-live-tools.py` exercises harness assertions through fake CLI/REST
transports and simulated time. Those offline tests never constitute physical
isolation, natural-expiry or performance evidence.
