# Sandbox completion checkpoint

Status: active goal; implementation under review, physical qualification incomplete.
No production deployment. Keep PR #996 draft until the physical gates pass.

## Source and ownership

- Worktree: `.worktrees/sandbox-completion-20260913`.
- Branch: `codex/sandbox-completion-20260913`.
- Starting sandbox tip0950ac41e; master93337ef05 integrated in453b37667.
- Latest pushed commit:0e10a23854f355f9a45bc7e27ecdf48e0d4cd7c9.
- Local updates:738b594e1 receipt fix;5ec0cb78d merges mastere4df336bc;
  cbd5687cb adds explicit base-only Apple restore provenance.
- Earlier integration commits:1ad135ab7,cadaa7fdb,2ee8a4c87,41522b85b.
- Draft PR: https://github.com/Layr-Labs/d-inference/pull/996.
- Main checkout and unrelated providers/edits remain untouched.
- Evidence: `/private/tmp/darkbloom-sandbox-completion-evidence`.
- Disposable lab: `/private/tmp/darkbloom-sandbox-lab-20260913` on both Macs.
- Private primary fixture: `/private/tmp/darkbloom-physical-acceptance` mode0700.
- Root exclusively owns VM lifecycle and privileged test-host actions.

## Product implemented

The private alpha is an opt-in offline macOS CPU sandbox service. The real
coordinator owns account admission, durable leases/fences, idempotent lifecycle
and command records. A separate nonroot host daemon holds machine-wide exclusive
runtime ownership and authenticates a signed root guest supervisor over vsock.
Tenant commands irreversibly drop to never-registered UID/GID2001. File transfers
are bounded, resumable between acknowledged chunks, and version-bound on reads.
The Go consumer CLI covers create/list/inspect/execute/jobs/logs/cancel/files,
start/stop/renew/delete. Service enablement, account admission and drain differ.

Cleanup remains available after admission closes. Uncertain runtime failures
retain capacity until VM stopped proof. Durable deletion intent survives
crashes. Start rotates fencing while preserving lease expiry and resources.
Accepted command IDs replay without reexecution; lifetime journal admission is
bounded at256 commands and1GiB. Host and actual VM retain exclusive ownership;
inference must retain shared ownership for its lifetime. The authority inode is
`/Library/Application Support/Darkbloom/runtime/ownership.lock` and must survive
upgrades. Existing providers lacking this implementation require an explicit
controlled transition before sharing the host.

The offline profile has no IP NIC, audio, clipboard, host-directory share or GPU
claim. Tenant UID/GID2001 must remain absent from directory databases; lookup
errors fail closed. Native cleanup handles tenant processes and launchd domains.
Root never edits protected cron/at spools or disables SIP/TCC. Account-dependent
APIs such as Node os.userInfo, Python pwd and some SSH flows are not assumed
compatible. VM destruction remains the outer boundary for privileged OS queues.

Persistent raw VM disks require verified password-protected APFS encryption.
This is volume protection, not per-VM cryptographic erasure or confidentiality
from the running host administrator. Snapshot encryption code is a separate
library; integrated restore, billing and public access are not shipped here.

## Completed validation and its source boundaries

- Swift wave8:400tests,7 physical opt-in skips,0failures,78.9seconds.
- Coordinator:6005passing events (3527top-level,2478subtests),30packages,
  3opt-in skips,0failures. Focused race/vet and macOS/Linux builds pass.
- Packaging/tooling47tests; live harness30 offline tests; CPU harness3tests;
  real Go CI harness12Python tests and its Go runner race suite pass.
- Pinned Lume186tests plus6required checks; native stop9focused tests;
  fail-stop diagnostics3tests. Physical public-base create/boot/SSH/stop pass.
- Provider ownership14focused tests; benchmark CLI target built.
- Docs lint283files; actionlint pass.
- Go CI benchmark host-only baseline:356passing events per sample, two native
  samples plus relocated source, four compiled artifact hashes identical.
  No guest performance or compatibility claim yet.
- GitHub5c25: coordinator/sandbox/lint/docs/UI/release-integrity/CodeQL pass.
  Full CI and integration subsequently passed on5c25. Its benchmark environment
  still awaits human approval. Old Threat Model Review returned external API401;
  mastere4df336bc independently removed that workflow. No review result exists.
- Merge5ec0cb78d: docs288files, registry/API/protocol race tests, Rust cache
  parity and9focused Swift cache/protocol tests pass.
- Receipt writer738b594e1:13pass/1existingopt-in skip; actual zsh/plutil covered.
- Apple restorecbd5687cb:19pass/1existingopt-in skip; legacy and accountless
  source changes cannot be relabeled, raw tenant restore is rejected.
  The CLI still uses legacy preparation until accountless orchestration is wired.

The live-harness improvements add active-VM natural expiry, file
resume/abort/version controls, idempotency replay/conflict, and accurate
coverage exclusions. Their26offline tests, syntax/diff checks and docs283-file
check pass. Command timeout can race natural lease expiry. The next fixture/harness tranche
adds two distinct ordinary account keys and real own-resource controls plus
cross-account inspect/execute/files/cancel/delete denial, at most2VMs, separate
ownership/cleanup ledgers. It has30offline Python tests, focused Go fixture
race/vet and283-file docs validation passing. No reseed-on-populatedDB path.
Consumer-only fixtures can relocate to caller-owned0700 encrypted remote
storage without copying coordinator environment, DSN or host token. The running real fixture is now schema2 with two accounts and zero
allocations. Actual cross-account resource denial still awaits guest readiness.

## Authorized test Mac and storage

The user authorized SSH/sudo on nonproduction `gaj@100.104.151.128`.
Credentials remain in the conversation and transient authentication only.
ControlMaster: `/private/tmp/darkbloom-sandbox-test-remote-20260913/control`.
Authenticated master/reverse-tunnel session8472 replaced dropped session49221. Never write the SSH/sudo password into files or logs.

M3 Max,14cores,36GiB,macOS26.4,Xcode26.5,Swift6.3.2,Go1.27.1,Python3.9.6.
System Data UUID9325586E-9099-489B-9100-82CED3DFB185 remains FileVault=false.
Whole-Mac FileVault enablement is no longer needed for this test campaign.

A NEW dedicated encrypted APFS volume was created under the test authorization:
`/Volumes/DarkbloomSandboxTest-20260913`, disk3s7,
UUID EFEE3956-B6E1-47EA-A240-ACB4FE32975C, quota384000000000bytes,reserve0.
FileVault=true, owners enabled. Wrong passphrase denied and stayed locked;
correct generated passphrase unlocked/remounted. Existing six volumes remain.
Actual available bytes match Data/shared container; no virtual extra capacity.
The passphrase is ONLY in the primary FileVault-protected0700 fixture directory,
owner-only0600 `test-volume-passphrase.txt`; never copy it to remote disk/logs.
Do not delete that key while the volume is retained.

The reviewed root setup completed successfully after preflight. The new volume
root is root:wheel0755. Hidden nonlogin _darkbloom_sandbox UID/GID430 exists
with disabled authentication, shell /usr/bin/false, home /var/empty, no admin
or wheel membership. Runtime group431 contains only the broker explicitly.
Encrypted volume/host/{vms,capacity,credentials} are broker430:430 mode0700.
Independent root readback passed: authority directory root:431 mode0750,
empty single-link lock root:431 mode0660, device16777229 inode29088927, noACL.
Preserve that lock inode. No package/host service/credentials installed yet.
Private evidence authority-root-readonly.json records the completed setup. Review
found automatic macOS groups12(everyone),61(localaccounts),701(gaj Public
Folder sharepoint nesting everyone),100(Print Operator nesting localaccounts).
The installed-broker validator passes on the actual account. A root-launched
credential probe verified UID430/GID431 with ambient groups430,431,12,61,100,701.
Broker/runtime file controls passed; root/admin files denied; public-share and
print-operator files remained readable. InitGroups=false does not strip macOS
resolved ambient groups. Both probe labels are unloaded; evidence is retained.
This is a trusted nonadmin broker, not a tenant host-file isolation boundary.

The user suggested clearing 8-bit Gemma4. Only the exact verified
`~/.cache/huggingface/hub/models--gemma-4-26b` was deleted after fresh ownership,
no-symlink and no-use checks:26.064GiB reclaimed, free215.83GiB. QAT Gemma,
31B4bit Gemma, all other models and Go cache remain intact. No broad cache
permission is inferred. Obsolete owned VM images/restore download can be removed
only after their required probes/replacement qualification complete. Two-VM
capacity still needs sufficient actual free space for full reservations.

The actual CI runner is system/com.layr-labs.m3-max-org-runner, enabled/running,
with no Worker at last inspection. Its plist hash:
aff318a6a960fb840510eb52938ca9dba8b9d880497ee8df5f4592431da8fbdf.
It has a caffeinate/sudo/bash/Runner.Listener chain and ExitTimeOut1200. It has
NOT been paused. Before dedicating the host, recheck no Worker, disable/bootout
that exact service and prove process exit. Restore its unchanged original plist
and enabled state only after VM cleanup and runtime ownership release.
Existing GUI provider/watchdog/dev-provider and obsolete GUI runner overrides
are disabled. Preserve these states and the enabled fan service. The older
io.eigeninference.provider label also needs its exact restart state checked.

## Real isolated coordinator

Dedicated PostgreSQL container122749d06998e9033bfc7a5b2327864708f333b005466d35787bd72be2267f71
listens only127.0.0.1:60817. Its admin is sandbox_test. The earlier one-account database
darkbloom_sandbox_acceptance_02eeb9902f48 remains inactive. The active two-account
database is identified below. Ordinary24hour keys and a separate host credential
are used; no production/admin key.
DSN/coordinator environment remain private on the primary Mac. No fixture
credentials have yet been copied to the test Mac or broker.

Current real coordinator session95061, PID87260, listens ONLY127.0.0.1:18080.
SSH reverse tunnel exposes only test-Mac127.0.0.1:18080. Authenticated sandbox
lists for BOTH independently seeded accounts return empty; unauthenticated
list401. No registered host or allocations. Health explicitly reports source
54f1644cda51abc75afce39f9fee60183ed8cf1a. Prior owned coordinator95344/session76358
stopped with zero allocations; older34128/session77821 also stopped safely.

Current binaries came from a private git archive of committed source54f1644cd,
Go1.25.4, -buildvcs=false -trimpath -mod=readonly, explicit coordinator build
metadata. Manifest: private fixture/artifacts-54f1644cd/manifest.json.
NEW database darkbloom_sandbox_acceptance_42926a219074 has restricted owner
sandbox_acceptance_42926a219074 and two ordinary accounts/keys. Private DSN is
database-v2-url.txt; active fixture is fixture-v2. HostID
edf67ba1-2d71-4a19-86b7-391097652b69. Earlier database/fixture remains preserved
and inactive; no reseed or old credential reuse. New API/SSH-tunnel auth smoke
passed (control-plane-live-smoke-v2.json); VM/cross-account-resource proof false.
The earlier linked-worktree Go build used correct source but Go1.25.4 stamped
the outer checkout because .git is a file. Do not trust that old VCS stamp.
Old binaries are preserved under private fixture/pre-provenance-bin.

## Historical bootstrap-account investigation

Final old-probe state: v8 policy allowed password change, but real UID501 self
change failedOD4100 and the old credential remained valid. v9 created a partial
UID2003 control record whose initial authentication failed5100 and deletion
failed4001; no rotation ran. That record remains only in the quarantined probe
VM. v9 signed executableSHA5281955483ef2f53a59fb22abfbf91e8716d2585380c949ac2b6dfbb28732f33.
Driver45020 completed/stopped, and the inspection LaunchDaemon was removed.
The old release6base's SecureToken marker differs from the later probe; do not
conflate their identities. No further account-repair attempts are planned.
The following earlier observations are retained as investigation history.

Remote public base `darkbloom-sandbox-base-20260913` is stopped, partially
installed with signed release6, and UNQUALIFIED. No template receipt. The
installer failed deleting lume with eDSPermissionError -14120. Read-only disk
inspection confirmed lume501 is the last admin and SecureToken user. Apple
prevents deleting the last such user. Do not bypass SecureToken/SIP/TCC.

Proposed supported retirement: remove autologin, rotate public credentials to
in-process random material, verify new-positive/old-negative, set shellfalse,
disable account with strict authority/auth checks, remove exact known sudo rule,
demote admin last, discard replacement and cold-boot verify. Preserve the
required OS account record. This is NOT integrated or qualified yet.

Owned public probe VM: `darkbloom-retirement-probe-20260913`.
- v1 autologin disable succeeded but immediate kcpassword absence failed.
- v2 wrapper failed on zsh readonly variable status before password mutation.
- v3/v4 OpenDirectory changePassword failed OD4100 even with authenticated node.
- v5 private controlling PTY sysadminctl reset returned0, but replacement
  authentication failed OD5000 and public old password remained valid. The
  verifier rejected the image. Cleanly stopped; v5bootUUID
  60D788A1-FEEE-4F3E-B383-E8151FD08920.
- v5 signed probe SHA256bcba0cd1143e4a53b94d3471ca465d706fa12e2093495676634765967080faef.
  Seven private-PTY transport regressions pass; this does not prove password
  mutation. guest_architecture is adding bounded v6 diagnostic classifications.

v5 installed an OWN root inspection LaunchDaemon BEFORE the probe. It will run
about40seconds into the next cold boot and shut the VM down, whether inspection
passes or fails. Future SSH retry drivers must bootout/remove that exact job
before attempting a long new probe, then stage the new inspection job for the
next cold boot. Never start a second VM owner while a prior driver runs.
Latest completed probes:
- v6 session55768: reset-attempt/failure/keychain-not-updated flags only; no
  token/permission/parameter-specific diagnostic. Public password still valid.
- v7 session81286: bounded redacted transcript reveals the actual Apple CLI
  failure: SystemConfiguration commitChanges failed. Exit0 still did not
  change the password. BootC5C417FA-8CC7-4272-A7A2-BB98BC51B401.
  Signed v7SHAc2ff0e111ed6f024b82bd769703219edf016116602ffaa3359ad2be7d814b559.
- Metadata-only session59180 completed0 and stopped. Guest-native metadata
  ruled out wrong ownership/ACL: dslocal/lume/admin/staff/root/nobody/wheel
  records are root:wheel0600,singlelink,flags0,noACL on writable owners-enabled
  storage. SystemConfiguration preferences rootwheel0644/noACL. Source of
  original account is Lume's offline patcher, but no malformed owner is proven.
  BootD4683C5A-B239-4F9F-8812-26BDBF0793F0. Metadata executable SHA256
  30b065d24ffc4b4e2c357ae592ed03c0f72ec3dc0757549d32c8912ee9302f34.

IMPORTANT: metadata driver REMOVED the own inspection LaunchDaemon and did NOT
restage it. The probe VM is stopped; next driver must expect inspection absent.
Installed retirement executable remains v7. guest_architecture is preparing
read-only passwordChangeAllowed and a true UID501 own-password API probe, with
replacement only in process/privatepipe and unchanged verification gates.
Do not edit private account plists or SecureToken/TCC/SIP to force success.

Actual broker credential probe was executed once via a separate one-shot
LaunchDaemon. Bootstrap succeeded, but no output/terminal status arrived within
15seconds; root booted out ONLY its exact label successfully. Qualification is
false; no group/file-control case ran. Its artifacts are retained under the
encrypted volume/broker-credential-probe; label/plist is
io.darkbloom.sandbox.test-credentials-20260913. Root must diagnose launchd
start/output behavior before another probe. Runtime flock was never acquired.
Safe remote evidence: lab/evidence/broker-credential-probe-v1.json. Neither
original CI/provider jobs nor user model/cache state changed during the probe.

Signed release6: source41522b85b, clean source, Developer ID, no sandbox-specific
profile or notarization, production_ready=false. Guest SHA256
bc73640061c6a0a265f8e6886b623cdf9ea4e9e3d69384fe4769755f9a28f401.
Runtime runtime/lume-stop-fixed/lume SHA256
973d851b0776b7fa8ffad253031313764488149bb8a623de5916973eb6e1f252.
IPSW UniversalMac_26.6.2_25G83_Restore.ipsw,19772231540bytes, SHA256
885503b7f4b06609e9a512f2befd40f59730640a3f1233e3892d60affdd51c95.
All are transferred and verified on the test Mac. Guest changes require a fresh
signed package and complete base qualification; host-only changes may reuse
exact four signed guest files. Older release1–5 packages are obsolete.

## Current accountless installation evidence

The account-bearing Lume bases remain quarantined and stopped. Password and
account-retirement attempts did not establish a safe template. No protected
account database, Setup Assistant marker, SIP or TCC changes were made.

A cleaner Apple restore without --unattended now has physical positive proof:

- Probe1 (session21973 restore) reached the root job but stopped at a diagnostic
  JSON writer bug. Receipt was exactly{}. VM stopped; original image/evidence
  preserved. The actual product receipt writer had the same bug and is fixed.
- Probe2 restore68652 completed0 in166.540s; disk16777229:29299379,100GiB.
  Staging12150 passed. Boot9938/PID38615 naturally exited0 in23.582s, no watchdog.
  Read91550 verified root job, release6 signatures, validate-tenant-identity exit0,
  absent setup-completion marker before/after, complete receipt. Fully detached;
  unrelated Apple MetalToolchain image remained unchanged. This proved the
  startup mechanism only, not full installation or template readiness.
- Probe3 restore46562 completed0 in172.611s; disk16777229:29300414,100GiB.
  Stage74860 passed; DataUUID A3B3C469-3618-441B-B64B-79E80D5E5921.
  Boot15625/PID39032 naturally exited0 in24.864s, no watchdog, stopped verified.
  Read94743 verified exact signed release6 installer --install exit0, installed
  file hashes/signature/root ownership, synthetic workspace manifest and signed
  tenant-identity helper exit0. Human-account counts0 before/after; one macOS
  Setup Assistant system account before/after; completion marker absent.
  All helper attachments detached and the pre-existing Apple image unchanged.
  This is complete installation evidence; native_guest_qualified=false and
  template_ready=false remain accurate.

Probe3 name darkbloom-accountless-probe3-20260913; runUUID
70755ec9-b185-4a4f-afb0-047199903776; payload planSHA
 a05ca2190d2ce6fac8f820b5cb1b18ecf0fd1eb4711845bf1dad97f47be94d11.
Root-private evidence is under test-Mac
/private/tmp/darkbloom-accountless-operator3-20260913:
restore-proof.json,stage-proof.json,boot-v3/boot-result.json,receipt-read-v3.json.
Offline helper accountless-offline-v3.py SHA
06cad8c354c2b57692c5176d2d211d50595f7c3cba8ccfa47f212a92b6462fc3.
Payload17local tests; offlinehelper38remoteUID501tests; bootdriver11tests pass.

All operator VMs are stopped. Probe3 temporary installer staging/job have NOT
been removed yet. Prepared removal-only helper must preserve permanent guest
installation and record original receipt/log evidence outside the guest before
unlinking only this run's exact app directory and LaunchDaemon. A separate
owned clone with real DBCONTROL/DBWORK must qualify the normal HMAC/vsock channel,
workspace cold mount, tenant commands/files and teardown. The reusable original
must never receive instance credentials or tenant work. Current probe disks are
small empty public images with no instance.json or secrets.

The broker authority inode remains16777229:29088927. Root operator holds its
exclusive lease across each Lume child; child501:20 receives transient431 and
inheritedFD4. No persistent gaj group membership was added. CI is not paused;
last fresh inspection found no Runner.Worker. No host daemon is registered.

## Remaining gates

1. Remove exact temporary probe3 installer payload/job after durable evidence,
   then qualify a separate clone using real authenticated vsock/control/workspace,
   tenant commands/files and restart. Prove clone/material cleanup independently.
2. Integrate accountless preparation and schema2 installed/qualified receipts in
   the product. Preserve legacy provenance and normal template-ready gates; no
   arbitrary raw VM adoption, fake retirement boolean or public readiness bypass.
3. Build/sign fresh artifacts, prepare a product-owned qualified base, safely
   reserve the idle test machine and install/enroll the actual broker host daemon.
   Production profile/notarization remain explicit release gates.
4. Run the real two-account/two-VM API/files/isolation/quota/cancel/timeout/start,
   natural30minute expiry, idempotency and cleanup campaigns. Add actual broker
   crash/restart/reboot and launchd respawn tests; API state alone is not proof.
5. Run paired host/VM CPU and real offline Go CI build/test measurements under
   tenant UID2001, with contention and documented compatibility limits.
6. Final modular refactor/review, appropriate tests/docs/PR/CI refresh. Keep PR996
   draft until physical gates pass. Production merge/publication/deployment and
   provider adoption remain separate, specifically authorized operations.

Only the user-selected8bit Gemma cache was deleted. Go cache and other models
remain. Recover space from exact owned obsolete images/downloads after evidence;
never weaken full disk-capacity reservations or delete unrelated user material.
