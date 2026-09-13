# Sandbox completion checkpoint

Status: goal active; implementation committed for review, physical qualification incomplete.
No production deployment or host administrator installation has occurred.

## Source and ownership

- Worktree: `.worktrees/sandbox-completion-20260913`.
- Branch: `codex/sandbox-completion-20260913`.
- Starting sandbox tip: `0950ac41e`; integrated master: `93337ef05` in `453b37667`.
- Latest pushed commit: `2ee8a4c87` (after `1ad135ab7` and `cadaa7fdb`).
- Draft PR: https://github.com/Layr-Labs/d-inference/pull/996.
- Main checkout and its unrelated edits remain untouched.
- Evidence: `/private/tmp/darkbloom-sandbox-completion-evidence`.
- Disposable lab: `/private/tmp/darkbloom-sandbox-lab-20260913`.
- Root exclusively owns VM start/stop; agents must coordinate source/build changes.

## Implemented product and boundaries

The initial product is an opt-in, offline macOS CPU sandbox service. The
coordinator owns admission, resource leases, fencing, idempotent lifecycle and
command records. A separate host daemon holds machine-wide exclusive runtime
ownership, manages VM disks, and authenticates the root guest supervisor over
vsock. Tenant commands irreversibly drop to UID/GID2001. File operations are
bounded, descriptor-based, resumable within the VM lifetime, and version-bound
for downloads. The consumer Go CLI covers creation, inspection, execution, jobs,
logs, cancellation, files, start/stop, renewal and deletion.

Service enablement, account admission and operator drain are separate states.
Cleanup remains possible after admission closes. Cancellation and uncertain
runtime failures require VM stopped proof before resources can be reused.
Durable deletion intent survives crashes and retains capacity until cleanup is
proven. Start rotates fencing without extending the lease. Command journals have
a256-command lifetime bound; accepted IDs always replay without re-execution.

The offline profile has no IP NIC, audio, clipboard, host-directory sharing or
GPU claim. Raw VM storage requires FileVault-encrypted APFS; it does not provide
per-VM cryptographic erasure. Encrypted snapshot artifacts are a separate library
and are not an integrated restore product. Billing and public access remain out
of scope for this private alpha.

Machine authority is rooted at
`/Library/Application Support/Darkbloom/runtime/ownership.lock`. Inference retains
shared ownership for its full lifetime; sandbox broker and actual Lume VM retain
exclusive ownership. No authority has been installed on this Mac. Existing
providers must not be stopped or bypassed without the pending explicit test-host
decision.

## Current validation

- Full sandbox Swift suite at the pushed revision:392 tests,7 physical opt-in
  skips,0 failures (`swift-integrated-wave7.log`). Later diagnostic/test changes
  still require final integration verification.
- Full coordinator suite:5996 passing events (3518 top-level,2478 subtests),
 29 packages,3 opt-in skips. Disposable PostgreSQL, focused race tests, vet,
  Linux coordinator build and macOS/Linux consumer CLI builds passed.
- Pinned Lume:186 tests plus6 required lifecycle checks passed in the canonical
  signed build. Native stop coalescing has9 focused tests; fail-stop diagnostics
  have3 tests. Physical base creation, boot, SSH and cooperative stop succeeded.
- Provider lifetime/ownership:14 focused tests passed; benchmark CLI target built.
- Release tooling:24 tests; live acceptance harness:13 offline tests; CPU
  benchmark harness:3 tests. Docs lint:278 files passed.
- GitHub checks at `2ee8a4c87`: sandbox, provider, coordinator, E2E integration,
  UI, release integrity, docs, lint and CodeQL all passed. E2E benchmarks await
  their external gate. Threat Model Review failed because its configured API
  credential returned401; no secret or workflow was modified.
- The live two-VM acceptance and paired VM/host performance harnesses are built
  but have not run against the isolated service. A reproducible offline Go CI
  workload benchmark is being completed independently.

## Physical installation defect under investigation

The signed guest base has not qualified. Current partial image:
`vms/darkbloom-sandbox-base-20260913`, in the disposable lab. Root probes stop the
VM and record stopped proof. Check the newest probe result before any next run.
Do not use the partial base for tenants or replay the installer over existing
accounts. The qualified template receipt is `.darkbloom-template.json`.

The first Lume provision failure was a concurrent Virtualization.framework stop
race. Pinned patch0008 coalesces native stop completion without weakening
terminal proof; physical base provisioning then succeeded.

Guest installation subsequently exposed macOS path aliases, trusted-parent
scheduler leaf ownership, and lazily recreated empty launchd user domains. Those
fixes are committed. Signed release5 now reaches the native scheduler setup but
has not completed installation. Direct root-SSH probes show `EPERM` both when
changing `/private/var/at` ownership and when creating cron/at allowfiles. The
installed signed helper reports `guest_bootstrap.scheduler_spool.policy_mismatch`.
Root is testing the actual system LaunchDaemon execution context before choosing
a supported installation design. No TCC database, host permissions or allowlist
protection has been bypassed. Precise diagnostic edits are uncommitted.

The installer also timed out instead of surfacing this failure. A generic
long-timeout wrapper with immediate exit78 passes in0.4s; guest_architecture is
tracing the actual installer failure path rather than replacing the transport
without evidence.

## Exact physical artifacts

- IPSW: `UniversalMac_26.6.2_25G83_Restore.ipsw`,19772231540 bytes, SHA256
  `885503b7f4b06609e9a512f2befd40f59730640a3f1233e3892d60affdd51c95`.
- Runtime: `runtime/lume-stop-fixed/lume`, SHA256
  `973d851b0776b7fa8ffad253031313764488149bb8a623de5916973eb6e1f252`.
- Signed package: `packages/release-5`, source `2ee8a4c87`, clean source at build.
  Guest executable SHA256:
  `2be6cb4adf97cbd208668a5923c38bba20cbdac7fd48dfdb144757e08fe41735`.
- Developer ID signing verified. No sandbox keychain provisioning profile or
  notarization proof; manifest correctly says `production_ready: false`.
- Older packages are obsolete. Guest changes require a fresh signed package.
  Host-only changes may reuse the exact four verified signed guest artifacts.

## Remaining acceptance gates

1. Fix and physically qualify complete signed guest installation and retirement
   of the temporary bootstrap account.
2. Finalize the current diagnostic and benchmark edits, review, test and push.
3. Install the machine authority and isolated service on an explicitly approved
   nonproduction Mac, then run single/two-VM API, isolation, quota, cancellation,
   timeout, crash/recovery, cleanup and actual lease-expiry campaigns.
4. Run paired host/VM CPU and actual Go CI workload measurements; publish raw
   measurements and limits, without inferring parity from synthetic tests.
5. Resolve signing/profile/notarization and external CI review gates before
   claiming release readiness. Merge/publication/adoption are separate facts.

The request for a nonproduction test Mac with administrator access and at least
300GiB free remains unanswered. This Mac has128GiB RAM, roughly159GiB free with
the current partial base, two existing providers, and no passwordless sudo.
Its normal home deny-delete ACL must remain intact. Use only the private lab
for these disposable probes. Progress on code and guest provisioning continues;
the test-host question is not permission to mutate production.

## Latest physical findings and host interruption

These findings supersede the earlier scheduler hypothesis above:

- The valid system LaunchDaemon probe3 exited78 with the same scheduler spool
  failure. Probe2 was invalid because its embedded plist label was not updated;
  do not use probe2 as evidence.
- Root `launchctl disable` reports both services disabled, and tenant attempts
  to enable/bootstrap them are denied. Root bootout of cron fails150 because
  SIP is engaged. After a clean shutdown/cold boot, atrun's override persists,
  but cron's override is absent from the actual disabled.plist and cron remains
  registered. Thus mandatory disabled-and-absent cron is not a workable control
  on this image. No SIP, TCC database or protected files were bypassed.
- Native failure-wrapper positive controls pass: staged debug0.757s, exact
  signed release5 artifact0.779s, shell0.400s, with a300-second command deadline.
  The apparent native-wrapper hang instead occurred before main while dyld
  loaded an executable from Documents. No transport defect has been established.
- A proposed alternative is a never-registered numeric UID/GID2001. Apple cron
  and at source rejects absent passwd identities before accepting work. This
  would remove account creation and protected scheduler-file manipulation,
  while retaining credential dropping, workspace ownership, domain/UID cleanup
  and the VM boundary. It remains a proposal until physical toolchain checks.
  It is not proof that all privileged macOS broker queues are empty; programs
  requiring passwd records, including some SSH/Node paths, may be incompatible.
- The first numeric probe tried deleting our known2001 records and received
  eDSPermissionError; it does not establish which record was removed. A second
  probe instead used never-registered UID/GID2002, finished exit0 and stopped
  the VM. Its results are in `numeric-tenant2-probe.log`, not yet readable.
- Local process launches then stalled for root and control_audit, including
  shell builtins, `/bin/cat`, `/bin/ps`, and alternate `/bin/sh` with a PTY.
  The app RPC still responds. New VM/test launches are paused and the user has
  been asked to restore the local command connection. Do not start duplicate
  probes until existing sessions and the VM stopped record are inspected.
- The Go CI benchmark now has8 passing Python tests, a passing stdlib runner
  race suite, two fresh-cache native samples with356 passing events each, and
  a relocated-bundle sample with identical compiled hashes. These are host-only
  results. control_audit is integrating the harness tests into existing gates.


## Resumed on September 13 with an authorized test Mac

Local execution recovered; the pending checkpoint write completed. The goal is
active again. The UID2002 physical probe is now inspected: numeric execution
returned exact UID/GID/groups2002, while crontab list/submission and atq/at
submission all rejected the absent account. The last owned local VM is stopped.

The user explicitly authorized SSH and sudo use on the nonproduction test Mac
`gaj@100.104.151.128`. Credentials remain only in the conversation and transient
SSH authentication; do not write them into files or logs. The authenticated
ControlMaster is `/private/tmp/darkbloom-sandbox-test-remote-20260913/control`.
An interactive SSH channel is held in session49221. Public artifacts are being
staged in remote `/private/tmp/darkbloom-sandbox-lab-20260913`.

Remote inventory: M3 Max,14 cores,36GiB RAM,macOS26.4,Xcode26.5,Swift6.3.2,
Go1.27.1,Python3.9.6. It initially had about257GiB free. FileVault is OFF even
though hardware Encryption=true. No alternate encrypted APFS volume was found.
The user was asked specifically to authorize whole-Mac FileVault enablement or
provide encrypted test storage; that answer is still pending. Do not infer it
from elapsed time. No host administrator mutation has occurred yet.

No active provider/VM process was found, but installed provider/watchdog
LaunchAgent files exist. GitHub Runner.Listener was active and untouched; check
for active jobs and account for restart paths before dedicating the host.
The scoped Go build cache is about27.8GiB and Hugging Face model cache about
152.6GiB. Neither has been deleted. Preserve model data without a concrete
operator decision. Disk policy still requires100GiB boot disks; do not reduce
it just to fit this machine.

The pinned Lume runtime was transferred with signing xattrs and its signature
and SHA256 verified on the remote Mac. The IPSW SCP is running in session48994;
inspect that handle before starting another writer. A16MiB Apple CDN range
probe returned206 at roughly5.9MB/s; it did not justify replacing the active
SCP. No remote VM has been started yet.

Current source work (uncommitted):

- guest_architecture implemented never-registered UID/GID2001, fail-closed
  reentrant identity lookups and removal of protected scheduler/account changes.
  It preserves credential drop, numeric workspace ownership and domain/UID
  cleanup. Compatibility limits for account-dependent APIs are explicit.
  Focused50 Swift tests passed with1opt-in skip; packaging24 and live-harness13
  offline tests passed. It now owns the service-startup disk-check fix below.
- The service inherited the doctor's fixed300GiB root-volume qualification
  check before recovery. Capacity admission already uses actual configured
  storage and preserves cleanup under pressure. Agent is separating startup
  advisory inspection from authoritative admission, retaining all disk limits.
- physical_inventory owns host-plan WSS path validation and regression tests;
  the doc incorrectly used `/v1/sandbox-hosts/ws` instead of `/ws/sandbox-host`.
- control_audit finished CI benchmark tooling/gates:12Python tests, Go runner
  race suite, native/relocated356-event runs and exact artifacts passed. It is
  adding a minimal optional coordinator bind-host setting and a private fixture
  plan using real cmd/coordinator, API authentication and disposable PostgreSQL.
  No coordinator service or fixture seed has been started.

The current runtime uses transient Secure Enclave checks, token-file host auth
and encrypted backing storage. Persistent keychain/artifact APIs are separate
and unused by Serve. Developer-ID development-entitlement packages can exercise
those runtime paths without claiming production keychain certification; the
production host-installation profile gate remains intact. Only the remote
provider profile was found, and it does not authorize the sandbox app.


Current integrated local gate: full Swift wave8 passed400tests with7explicit
physical opt-ins skipped and0failures in78.9seconds. Numeric identity, configured
volume inspection and low-space recovery fixes are included. Packaging URL
regressions pass26tests; CI benchmark tooling passes12Python tests and the Go
runner race suite. Coordinator bind/fixture work remains separate and unfinished.
