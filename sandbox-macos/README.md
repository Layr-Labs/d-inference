# Darkbloom macOS sandbox runtime

This package is the isolated macOS host substrate for Darkbloom sandboxes. It
does not link the inference provider or MLX. The current executable slice:

- validates Apple Silicon, Virtualization.framework, capacity, Aqua-session,
  Secure Enclave, and code-signing prerequisites;
- resolves the latest host-supported macOS restore image through Apple's
  Virtualization.framework API;
- invokes an audited, exact-commit Lume build behind a narrow runtime adapter
  for the macOS 26 unattended-install proof;
- defines fenced sandbox identities, resource limits, lifecycle transitions,
  and a runtime boundary for VM implementations;
- persists host mode and at most two resource leases behind a process-safe
  lock, monotonic fencing tokens, and atomic durable state;
- provides chunked authenticated encryption for large VM artifacts; and
- wraps data-encryption keys with a distinct Secure Enclave identity.

The guest agent, packet gateway, and coordinator lease protocol will sit behind
the interfaces in this package. Lume's temporary unattended guest uses its
known `lume` / `lume` bootstrap credentials, so this slice is restricted to the
approved no-secrets alpha. Until randomized bootstrap credentials, guest
control, and egress enforcement pass their live tests, this package is a
host-substrate proof, not a multi-tenant service. The public lease-fenced
runtime deliberately has no guest-command method.
`baseImagePreparationAndDevelopment` is an explicit package-only policy for
base-image preparation and live tests; it is not a production security boundary
because OpenSSH startup files, launchd metadata, and command-monitor files
remain writable by the same guest identity.

The development bootstrap executor captures stdout and stderr independently,
drains both streams without retaining unbounded data, and returns at most 1 MiB
per stream in a versioned result envelope with explicit truncation flags. Host
child processes also start with close-on-exec-by-default descriptor isolation.

Artifact authentication binds sandbox generation, disk role, and a random
per-encryption revision ID, so chunks from separate revisions cannot be spliced.
It does not establish which of two complete, valid ciphertext revisions is
newest. Cached-image restore therefore remains disabled until the
coordinator-backed artifact manifest supplies and verifies a monotonic revision.

Storage destinations must be inside an extended-ACL-free `0700` directory
owned by the daemon's dedicated Unix identity. Staging and committed files are
also rejected if they carry extended ACL entries. The codec writes to an
unlinked file descriptor and publishes it with APFS `fclonefileat`, so there is
no temporary pathname to replace and an existing destination is never
overwritten. A post-clone sync failure is reported as `publicationUncertain`:
the destination may exist and must be reconciled, never blindly deleted.
Filesystem permissions are not a security boundary against another hostile
process running as that same Unix identity; production launchd packaging must
reserve the identity for the sandbox broker.

## Build and test

The package requires Apple Silicon macOS 14 or newer with a full Xcode
toolchain.

```bash
swift build --package-path sandbox-macos
swift test --package-path sandbox-macos
```

The Apple restore-catalog test is opt-in because it makes a live network
request. SwiftPM does not attach custom entitlements to its XCTest runner, so
the test ad-hoc signs the package's debug daemon with
`com.apple.security.virtualization` and executes the real
`VZMacOSRestoreImage.fetchLatestSupported` path in that entitled process:

```bash
DARKBLOOM_SANDBOX_LIVE_RESTORE=1 swift test \
  --package-path sandbox-macos \
  --filter SandboxRuntimeVZTests
```

## Host proof

Sign the debug executable with the sandbox entitlements before running the
strict host check:

```bash
bin_path="$(swift build --package-path sandbox-macos --show-bin-path)"
codesign --force --sign - \
  --entitlements sandbox-macos/Resources/DarkbloomSandboxDevelopment.entitlements \
  "$bin_path/darkbloom-sandboxd"
"$bin_path/darkbloom-sandboxd" doctor --json
"$bin_path/darkbloom-sandboxd" restore-image latest --json
```

The development entitlement grants Virtualization.framework access only.
`DarkbloomSandbox.entitlements` is the production profile input and additionally
names the provisioned keychain access group; macOS kills an ad-hoc binary that
claims that provisioned group.

`--development-unsigned` downgrades only the missing virtualization entitlement
to a warning. It does not bypass architecture, hypervisor, capacity, Aqua, or
Secure Enclave checks.

Production persistence uses the dedicated
`SLDQ2GJ6TL.io.darkbloom.sandbox` keychain access group. Ad-hoc signatures can
exercise transient Secure Enclave cryptography but cannot prove production
keychain persistence; that path must be verified with the provisioned release
identity.

## Host capacity and inference coexistence

`SandboxHostCapacityArbiter` stores a host mode and crash-durable leases under a
caller-owned, extended-ACL-free `0700` directory. Authority paths are opened
component by component without following symlinks; state and lock files must be
private, single-link regular files and are revalidated through their open
descriptors. State replacement is synchronized in file-before-directory order,
and a post-rename directory-sync failure is reported as an uncertain
publication rather than a clean failure. The broker must quarantine the host
and reconcile durable state before accepting another mutation; a matching
immediate read proves visibility, not reboot durability. Lume operation locks,
VM ownership
markers, workspace configuration, provenance, and guest-command journals apply
the same owner, mode, ACL, hard-link, and ancestor-path checks. Staged ownership,
configuration, commitment, and result bytes are unlinked before writing and
published from their descriptors. These controls assume the production broker
runs under a dedicated Unix identity; processes with that exact credential can
change owner-controlled mode and file flags, so sharing the broker identity
with tenant jobs is prohibited.

The state machine requires
`inference -> draining -> sandbox_dedicated` before accepting sandbox work, and
requires all leases to be released before returning to inference mode. Every
reservation receives a monotonically increasing fencing token. A bounded,
durable per-sandbox generation high-water mark survives release and restart;
equal or older generations fail closed instead of reclaiming prior authority.
Capacity state also binds the canonical runtime storage path, directory inode,
and device. All pre-v3 state is quarantined because neither complete released
generation history nor the runtime storage identity can be reconstructed.
The alpha history admits 4,096 distinct sandbox IDs and then fails closed.
Resetting that history is safe only during host reprovisioning after the broker
is stopped, the host is drained, and every VM/artifact on the bound storage
directory has been destroyed; deleting capacity state alone is unsafe.
Retries are idempotent only when sandbox generation, VM name, CPU, memory,
workspace reservation, boot disk, and reserved growth charge match.
`LumeLeaseFencedVirtualMachineRuntime` is the public workload mutation surface:
create, start, inspect, stop, and release carry the complete operation scope.
Release stops and verifies the owned VM before its package-internal capacity
release. The VM-operation and lease-operation locks remain held through the
capacity-state commit, so a concurrent start cannot run between stop and
release; callers cannot remove capacity directly. Physical deletion remains
package-internal until deletion intent has its own durable crash-recovery state,
so a crash cannot strand a running or missing VM behind released capacity.
Guest execution is absent until the signed guest-control agent replaces Lume's
shared bootstrap identity. The underlying Lume actor is package-only, validates
the scope before creating a per-VM operation lock and again while holding it,
and binds create authorization to the reserved CPU, memory, workspace, and
boot-disk bytes. Mutations use a deterministic fixed set of 64 inter-process
lease-lock slots, so attacker-selected identifiers cannot grow authority
storage without bound. Inspection authorizes immediately before and after its
VM-locked Lume observation, so renewal and release do not wait on external I/O
and any observation made under a rotated or released token is discarded.
Expired or draining leases may only stop or delete their own VM; they cannot
start additional work.
Each workload VM also carries a fail-closed ownership marker binding its
installation to the sandbox ID and generation plus its CPU, memory, disk, and
image source. Renewed fencing tokens retain access to that same generation, but
a later generation cannot reuse its VM or disks. Base templates use a distinct
marker role, and clones commit the source template installation ID; workload
VMs cannot be used as clone templates. Legacy unscoped markers are rejected and
must be rebuilt rather than inferred.

The alpha policy admits exactly two running sandboxes, fixes the sparse macOS
boot disk at 100 GiB, and reserves each clone's worst-case boot-disk CoW growth,
25/50 GiB workspace, and 1 GiB host overhead. Aggregate CPU, memory, and growth
admission runs under an inter-process `flock` on the already-bound state
directory inode. Reservation and VM creation both require the configured
storage directory's live descriptor-bound filesystem capacity to cover all
reserved growth plus operator-configured headroom. Every fenced operation
revalidates that the configured path still resolves to the persisted directory
identity. This host reservation is not yet a guest-visible disk quota;
production quota enforcement still requires the signed guest-control agent and
a separately bounded workspace volume. Expiry reconciliation first persists a
new fencing token, then stops and verifies the owned VM before releasing that
exact token. A missing VM, replaced storage path, stop failure, or ownership
failure retains the fenced lease for retry or host quarantine, preventing a
stalled control plane from overbooking a host whose guest may still be running.

## Pinned Lume substrate

`ThirdParty/lume.lock.json` pins the exact Cua source commit, expected version,
and the SHA-256 of every Darkbloom patch. Build it without a background service:

```bash
sandbox-macos/Scripts/build-pinned-lume.sh \
  "$HOME/.local/libexec/darkbloom-sandbox/lume/bin"
```

The build verifies and applies the pinned patch before compilation, then writes
`lume.provenance.json` beside the executable with the source commit, patch
digests, and post-signing SHA-256 for every runtime file. It signs that canonical
manifest separately as `io.darkbloom.sandbox.lume.provenance`, binding all
resource bytes to the release identity instead of trusting a self-authenticated
digest list. Production validation requires Apple-designated requirements for
both the executable and manifest under team `SLDQ2GJ6TL`; the
`--development-ad-hoc-lume` daemon flag is an explicit local-only bypass.
Before executing Lume, the adapter requires the complete immutable directory
tree and provenance to match the audited lock; it rejects added, removed,
replaced, or modified runtime entries. The production installation must be
recursively root-owned and non-writable by the dedicated broker identity; the
validator rejects broker-owned production files even when their modes are
read-only. The operator must apply `chown -R root:wheel` after installing the
signed tree. Every invocation sets
`LUME_TELEMETRY_ENABLED=false` and `LUME_LOG_LEVEL=error`; the latter prevents
Lume informational diagnostics from corrupting its machine-readable JSON
output. Moving the pin requires source review plus the opt-in real-binary and VM
lifecycle tests.

Guest-command idempotency is enforced on the host, outside the guest's trust
boundary. Before SSH launch, the runtime durably commits the VM installation ID,
idempotency key, and a canonical request digest under the private runtime
directory. A completed bounded result is replayed without a second guest
execution. Reusing a key for different input, or retrying a claim whose outcome
was not durably recorded, fails closed. Journal entries are namespaced by VM
installation and retained; their bytes are part of the host's cached-sandbox
storage footprint.

The default build is ad-hoc signed for local testing. A production build must
have the Darkbloom Developer ID identity installed and select it explicitly:

```bash
DARKBLOOM_LUME_CODESIGN_IDENTITY='Developer ID Application: Eigen Labs, Inc. (SLDQ2GJ6TL)' \
  sandbox-macos/Scripts/build-pinned-lume.sh /absolute/install/path
```

```bash
DARKBLOOM_SANDBOX_LUME_PATH=/absolute/path/to/lume \
  swift test --package-path sandbox-macos \
  --filter LumeRuntimeContractTests
```

Prepare and verify a stopped Tahoe base image through the production adapter:

```bash
darkbloom-sandboxd prepare-base \
  --lume /absolute/path/to/lume \
  --storage /absolute/path/to/vms \
  --ipsw /absolute/path/to/tahoe.ipsw \
  --name darkbloom-phase0-base \
  --json
```

The command installs macOS, applies Lume's no-secrets-alpha unattended preset,
boots the guest without VNC, and waits until a bounded, NIO-only,
launchd-supervised no-op returns a valid development proof envelope. It then
reads the guest OS and architecture and leaves the base stopped. The opt-in live
suite can clone and run exactly two guests concurrently, prove their filesystems
are isolated, and leave both clones stopped:

Run crash-retryable expiry cleanup as the dedicated broker identity. The command
returns exit status 75 if any lease remains fenced because stop, ownership, or
durability verification failed:

```bash
darkbloom-sandboxd reconcile-expired \
  --lume /absolute/path/to/lume \
  --storage /absolute/path/to/vms \
  --capacity-dir /absolute/path/to/capacity \
  --max-cpu 12 \
  --max-memory-gib 32 \
  --max-growth-gib 320 \
  --storage-headroom-gib 20 \
  --json
```

```bash
DARKBLOOM_SANDBOX_LIVE_VM=1 \
DARKBLOOM_SANDBOX_LIVE_TWO_VMS=1 \
DARKBLOOM_SANDBOX_LUME_PATH=/absolute/path/to/lume \
DARKBLOOM_SANDBOX_IPSW_PATH=/absolute/path/to/tahoe.ipsw \
DARKBLOOM_SANDBOX_VM_STORAGE=/absolute/path/to/vms \
  swift test --package-path sandbox-macos \
  --filter LumeRuntimeContractTests
```
