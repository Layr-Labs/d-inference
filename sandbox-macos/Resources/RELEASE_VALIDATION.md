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

Native bridge shutdown removes its own Unix socket entry before returning,
under the descriptor-lifetime lock. It preserves a replacement inode and lets
the accept loop finish closing its descriptors. The broker still allocates a
fresh private endpoint directory on every stopped-to-running transition.

The pinned native test runner executes the full suite plus nineteen required
selectors, including the final-frame half-close exchange and a writer-error
diagnostic control. The relay fixture runs its complete timed exchange on
dedicated test threads, retries interrupted socket IO, preserves actual errno
and byte counts, and joins owned workers during error cleanup. Production relay
code and its timeout are unchanged by that test-only patch. The CI I/O failure
that motivated it did not reproduce in eleven local full-suite baseline runs;
the harness correction is not evidence of a diagnosed production relay defect.
The offline-fence selectors also require denial of fenced native commands,
read-only inspection preserving the marker, and storage alias checks. The
per-image marker is never treated as the automatically cleared provisioning
marker. Normal native commands cannot remove it. These temporary-file and CLI
tests do not establish successful physical root maintenance.

Managed raw Apple restore requires the current managed-installer patch and a new
matching signed Lume artifact. `LumeManagedRestoreProcess` retains exclusive
machine ownership in the installer child and sends broker-lifecycle EOF on
cancellation. The native installer cancels `Progress` after installation starts,
waits for its completion, and proves the VM stopped before deleting temporary
files. An unproven stop retains the native owner and files until process exit.
Legacy unattended preparation is a separate path. Unit tests establish process
and cancellation contracts; they do not qualify a real restored base or replace
the accountless installation and disposable-clone checks.

The native `installer-v1` profile is a separate managed offline boot mode for
the accountless first-boot job. It requires macOS, broker lifecycle control,
disabled display/VNC and inherited exclusive machine ownership in the actual VM
process. It accepts only the private owned `disk.img`; control/workspace disks,
storage/NVRAM overrides, recovery, host shares, USB, clipboard and network
overrides are rejected. The resulting configuration has one writable boot block
device and no IP network, audio, serial/console, host-directory, input, USB or
Virtio socket devices. The serial-log environment path is not opened in either
managed offline profile. The existing `isolated-v1` tenant profile retains its
three disks and authenticated Virtio bridge.

This profile establishes device and owner-lifetime constraints only. It does not
grant permission to retry an installer, prove that the root job completed, or
publish a ready template. The selected-GUI boot owner must first consume a durable
one-use boot intent and, after guest shutdown or cancellation, independently
prove stopped state. Root receipt collection/removal uses a separate maintenance
transaction. The operator phases and durable qualification owner are implemented;
fresh physical profile and complete factory acceptance remain release gates. See
[accountless operator commands](ACCOUNTLESS_RECEIPTS.md#accountless-operator-commands).

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
each supported guest OS. Tenant cleanup removes only `user/2001` and
`gui/2001` (the login-domain alias), then kills tenant UID processes and verifies
quiescence. The user domain is removed first. Verification requires exact GUI
domain absence and zero live tenant processes; it never prints the user domain
again after removal because that query can recreate the domain and load Apple
services. Exit125 and unknown, truncated or malformed results remain failures.
The output format and a submitted-job respawn probe require qualification on
each supported guest OS. This does not establish cancellation of every possible
system service or delegated queue; VM stop/delete remains the outer boundary.
The cleanup worker itself drops to UID2001 and can cause its user domain to be
created. Cleanup therefore removes the fixed domains again after the worker
exits, then checks zero tenant processes and verifies domain quiescence. A
missing successful removal, unrecognized domain output, and a non-absent login
domain retain separate fixed diagnostic codes; no domain contents are logged.
Removal and verification retry a bounded number of transient observations while
launchd finishes teardown. There is no empty-user-domain acceptance path.
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

## Prepare a selected GUI-user host

The host broker must run in an existing user's actual Aqua LaunchAgent context.
A physical nonlogin service launch failed Virtualization security-key creation;
an otherwise matching GUI-user LaunchAgent started and stopped the VM. Guest
readiness is a separate gate. Apple DTS states that Virtualization is not
daemon-safe and recommends a GUI-user agent for independent operation
([daemon context](https://developer.apple.com/forums/thread/841688),
[launch context](https://developer.apple.com/forums/thread/786363)). The old
hidden nonlogin LaunchDaemon plan is unsupported; the preparation tool refuses
to generate its activation script.

The selected user is the trusted host operator, who can already inspect the
host's VM plaintext. An explicitly selected normal administrator is permitted.
A separate nonadmin GUI login account reduces access to unrelated host files,
but this tool neither requires account creation nor changes any account,
password, keychain, group, login or automatic-login setting. Tenant commands
remain inside the VM under never-registered numeric UID/GID 2001. Host account
privileges and the guest VM boundary are separate properties.

`prepare-sandbox-host.py --gui-user-plan` consumes a signed, provisioned package
and an explicit identity assertion for the target Mac. The local DirectoryService
record must match Unix forward/reverse lookup and the configured short name,
UID, primary GID, GeneratedUID and home. A reused numeric UID alone is insufficient.
No protected authentication attributes or credentials are queried. Administrator
and runtime-group memberships are reported; installed validation requires the
runtime group, while actual kernel access remains a check inside the agent.
Use the real, read-only inspected identity values in this example:

```json
{
  "hostUser": {
    "recordName": "selected-user",
    "uid": 501,
    "primaryGID": 20,
    "generatedUID": "9819F283-43E0-49E9-8BB3-FD44CD75B963",
    "homeDirectory": "/Users/selected-user"
  },
  "coordinatorURL": "wss://your-coordinator/ws/sandbox-host",
  "hostID": "assigned host UUID",
  "tokenFile": "/private/var/db/darkbloom-sandbox/host.token",
  "storageDirectory": "/private/var/db/darkbloom-sandbox/vms",
  "capacityDirectory": "/private/var/db/darkbloom-sandbox/capacity",
  "baseImageIDs": ["approved-base-image-id"],
  "maximumCPUCount": 8,
  "maximumMemoryGiB": 32,
  "maximumGrowthGiB": 320,
  "storageHeadroomGiB": 20
}
```

```sh
python3 sandbox-macos/Scripts/prepare-sandbox-host.py --gui-user-plan \
  --package /absolute/signed-package --configuration /absolute/host.json \
  --install-root '/Library/Application Support/DarkbloomSandbox/0.1.0' \
  --output /absolute/new/install-plan
```

This creates a qualification plan, a plist, `host-user.json` and typed `plan.json`, with
`production_ready=false`. It creates no service or activation script. The
root-owned plist destination is outside global `/Library/LaunchAgents`, under
`/Library/Application Support/Darkbloom/host-plans/<host UUID>/`; the reviewed
command loads only `gui/<selected UID>`. It specifies Aqua, no UserName/GroupName,
no shell or credential switching, no HOME override, KeepAlive=false, and a
600-second ExitTimeOut for cooperative shutdown. SIGTERM/SIGINT cancel service
work; every exit after runtime construction awaits VM stop cleanup, including
startup reconciliation failures. An independent monitor checks the process's
actual GUI/audit session throughout startup and service operation. Session loss
cancels work and enters the same cleanup path. Failed stop proof remains an error
and does not release capacity; VM owners retain inherited machine authority.
The launchd allowance does not establish that physical logout cleanup succeeds. It does
not install recurring login startup. Logout makes this host unavailable; login
alone does not restore it. Actual logout/relogin recovery remains a separate
qualification gate.

The job passes `--host-identity-file` for its protected `host-user.json` sibling.
Every serve mode requires it, including development modes. Before acquiring
machine EX ownership or admitting work, the process validates the file's host
UUID and exact user fields against real/effective UID and GID, reentrant account
name/home lookup, and the public membership API's assigned GeneratedUID. Missing,
reused, synthesized or mismatched identities fail closed. This identity check
does not substitute for the separate actual Security/audit session check.

The release tree stays immutable to the selected user: root-owned code, public
0755 directories/executables and 0644 data, preserving pinned Lume's exact
0555/0444 modes, signatures and xattrs. The job definition is root-owned 0644
under root-owned 0755 parents; its identity JSON is root-owned 0444, single-link
and bounded to 8 KiB. Runtime reads walk nofollow directory descriptors, verify
every root-owned ancestor, and check file/path identity before and after reading.
No shared writes, symlinks, hard-linked files or
extended ACLs are accepted. The selected user owns storage/capacity directories
at 0700 and the token at 0600 in a private 0700 parent. All three must reside on
verified encrypted APFS; token contents never enter the plan or argv. Ancestors
must be trusted root/selected-user directories without shared writes or ACLs.

Run `--verify-installed` as root after a separately authorized installation. It
rechecks the explicit identity, signed release, exact plist and identity JSON, protected code,
private token/state, encrypted backing and runtime authority metadata. It
continues to report `production_ready=false`; installed validation is not proof
of actual agent session eligibility, VZ boot, guest readiness or cleanup.

```sh
sudo /usr/bin/python3 sandbox-macos/Scripts/prepare-sandbox-host.py \
  --gui-user-plan --verify-installed \
  --package /absolute/signed-package --configuration /absolute/host.json \
  --install-root '/Library/Application Support/DarkbloomSandbox/0.1.0'
```

Host inspection checks the calling process's Security session and audit user:
authenticated graphical access, matching nonroot real/effective/audit UID, and
neither root nor remote attributes. Console presence is only informational.
Changing BSD credentials or finding someone else's active console login does
not establish the caller's GUI context. An existing GUI session also may not
have newly added runtime groups; the real agent must successfully acquire the
machine authority. Do not infer group removal from `InitGroups=false`: macOS
ambient and nested memberships can still permit access to other host files.

Machine ownership remains under `/Library/Application Support/Darkbloom/runtime`:
root-owned directory 0750 in `darkbloom_runtime`, containing an empty root-owned
single-link `ownership.lock` at 0660 in that group. Only intended runtime users
join it through an explicit operator action. Never replace or truncate the inode.
Inference holds SH through engine cleanup; broker and actual VM owners retain
EX through VM cleanup. Providers running before this coordination was installed
need a separately authorized upgrade/restart before sandbox qualification.
The shared library also refuses ordinary SH/EX admission while root-owned
`maintenance.json` is present. Only root recovery with the exact operation and
journal binding can resume maintenance; the operator must verify and record
cleanup before clearing the fence. All participating binaries need this updated
admission behavior. `AccountlessStagingMaintenance` now binds its protected
journal to `LumeRootBaseImageGuard`: machine fence first, image fence second,
then image IO. Recovery retains the same system EX lease and checks the exact
reservation, original directory/image identity and immutable image fence. A
missing image fence permits staging recovery only when the original disk
snapshot is unchanged. Before clearing either fence, the operator records
`staging-detached.json`, which permanently closes image writes. That checkpoint
also permits completion after a crash between image-fence and machine-fence
removal. Live fence replacement, changed completion snapshots and inconsistent
journals fail closed. Deinitialization never clears either fence.

`LumeRootImageMaintenance` supports bounded asynchronous image work. Its use
gate rejects overlapping work and completion, including reentrant completion
from inside the image callback. System children spawned through
`startOwnedProcess` inherit the existing machine EX lease; recovery remains
excluded if the parent exits before the child. That behavior has passed a real
root parent-exit/child-lifetime test. Child termination remains a prerequisite
for cleanup observations, not proof that an attachment was detached.

`AccountlessDiskTools` supplies bounded read-only diskutil queries, with an
owned-child variant for an active staging operation. Its APFS binding follows
the exact whole disk, one main Apple_APFS physical partition, one synthesized
container with that sole store, and one Data-role volume. Volume labels confer
no authority. Foreign/duplicate identifiers, existing volume mounts, ambiguous
roles and invalid UUIDs fail closed; mounted readback checks the UUID, device,
mountpoint, filesystem, owner handling and requested write policy. These helpers
do not attach or mount disks and do not establish which image owns a whole disk;
that authority must come from the guarded attachment workflow.

`AccountlessStagingMaintenance.stagePayload` now owns the attach/mount/stage/
detach operation. A production-pinned native status query runs as the selected
source owner before source locking; unknown state is rejected. Root keeps the
native locks through cleanup. An append-only, bounded mount journal publishes
intent before attachment, binds each completion to its own attempt, and can
recover an attached image even when attach output was lost. Cleanup selects the
exact current image and revalidates device nodes; saved disk numbers alone never
authorize detach. Preexisting attachments are preserved, and the only opener
exemption is the operator's exact PID and retained image descriptor.

The selected Data volume mounts beneath the root-private journal with owners,
nosuid, nodev, noexec and nobrowse. Both diskutil identity/policy and fstatfs are
checked around payload IO; every Data descriptor closes before detach. A separate
same-binary root system-command worker retains the machine lease but passes no
lease fd to vendor tools. Its narrow system-tool path preserves platform helpers
after foreground exit. Other process execution retains descendant cleanup.
Observation deadlines and caller cancellation do not kill mutating disk clients;
an unresolved worker retains EX and the durable intent for later recovery.

A fresh 1 GiB nonbootable APFS fixture passed an actual attach/crash/recovery
campaign: lost attach output, fenced admission, exact detach, signed payload
staging through the Data mount, final detach and restored native stopped metadata
and ordinary EX/SH admission. The worker retained ownership and its vendor child
did not inherit it. The permanent inode and preexisting Apple toolchain mount
were preserved. Physical testing also found and fixed /private/tmp payload-path
normalization and readable-versus-GUID hdiutil content hints. This fixture emulates
the filesystem contract below the normal 100 GiB VM policy and supplies no guest
boot, actual Apple restore or template qualification evidence.

The `prepare-accountless-base reserve|payload|stage|authorize-boot|boot` commands expose
raw creation in the selected GUI session, root payload materialization and guarded
staging. They require production signatures and report only their completed phase.
Repeated staging verifies the protected final snapshot under fresh ordinary EX
after both fences are removed; it never authorizes another write. CLI options and
context requirements are in `ACCOUNTLESS_RECEIPTS.md`. Root publishes a protected
boot permit only after durably closing staging. The selected GUI owner claims
the attempt before native spawn, uses `installer-v1`, and waits for native exit
and stopped proof. Cancellation cleanup is independent of caller cancellation;
replay can only stop/observe the consumed attempt. Claimed sources cannot return
to ordinary base start, reservation or pre-boot staging.

The one-use boot path has automated subprocess tests; its real-Mac execution is
still unverified. Receipt collection/removal and automatic qualification to
readiness are implemented; the full fresh-VM campaign remains required.
Use `discard-base` with the exact installation ID to remove a stopped failed
raw base after root maintenance is settled. It preserves ready templates and
uses durable stopped/directory identity for interrupted removal. The command
and its recovery boundaries are documented in `ACCOUNTLESS_RECEIPTS.md`.
The existing prepare-base command still follows
its documented unattended path. A staging journal cannot be reused for post-boot
collection.

Keep coordinator admission disabled and capacity draining during qualification.
A job's launchctl exit is insufficient stop proof: independently verify the VM
owner, lifecycle cleanup and image/authority holders. Logout, agent death and
fresh login must be qualified before production activation; retain leases when
cleanup is uncertain. The current plan deliberately supplies no host-mode
activation command and never stops an inference provider.

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
