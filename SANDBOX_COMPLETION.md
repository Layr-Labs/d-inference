# Sandbox completion checkpoint

Status: active goal; implementation under review, physical qualification incomplete.
No production deployment. Keep PR #996 draft until the physical gates pass.

## Current verified state

Goal remains active; PR996 is draft. No production deployment.
Doctor --storage implementation ed05d0b8497e9e312708906ef485d61091476e7a is committed;
its source is queued for push with physical checkpoint commits. Discard b891 CI
34862480863 now passes fully. Integration34862480870 reached released-coordinator
compatibility and remains running at last check; benchmark34862480928 waits.
Predecessor owner f43 passes CI/integration.

Signed release9-doctor is installed immutably on the test Mac:
/Library/Application Support/Darkbloom/qualification-release9-doctor.
It reuses all4exact guest artifacts from release8; release7/8 remain retained.
Host/guest/manifest/Lume signatures and16-file inventory pass independently on
both Macs. No sandbox provisioning profile or notarization; persistent-keychain
and fresh physical factory/qualification remain release gates. Runtime13 has
not booted a VM. Last actual guest evidence remains exercise14/coldboot15 on the
older diagnostic image: authenticated commands/files/isolation/cleanup and
cold-boot workspace persistence. That source is unqualified and must be kept.

The complete public qualify command is implemented: durable intent, exact capacity
reservation, native clone/isolation/cold-boot checks, deletion/release and guarded
ready publication/readback. Recovery cleans up and aborts or verifies an existing
exact publication; saved success flags cannot create readiness. Latest committed
suite:671tests/7skips/0failures. Root APFS collection crash/recovery passes a
synthetic nonbootable fixture; it is not a real installer/VM result.

Six obsolete task VM fixtures were safely removed on2026-09-14. Native deletion
returned0 for each and each directory is absent. This reclaimed124592623616bytes
(116.04GiB). Latest GUI diagnostic VM, IPSW, unrelated sibling entries, permanent
machine authority and Apple Metal attachment are unchanged. Root report exported
to /private/tmp/darkbloom-sandbox-completion-evidence/retirement-result.json,
SHAf1783266dbbaf75ddb58246f37e41a51efad6ac09d790f43f56cf5e5b1458efe.
Actual signed doctor --storage in gui/501 reports216892593701important bytes
(~202GiB), below the300GiB admission floor. Its ONLY failed check is disk_capacity;
actual Aqua identity, transient Secure Enclave, virtualization entitlement and
all hardware checks pass. The one-shot job is terminal78 and unloaded. This is
host preflight, not a fresh VM or persistent-keychain result. New approval question is pending for Go
cache68.2GiB plus qwen3.5-27b-claude-opus-8bit26.6GiB, gemma-4-31b-4bit17.2GiB
and gpt-oss-20b11.3GiB. Do not delete these without a reply. Old8bitGemma deletion
was already completed earlier; no other user cache was removed by VM retirement.

Committed source adds discard-base for an exact unqualified raw installation,
using selected-user identity, machineEX and existing durable stopped deletion.
It rejects ready/unknown/running sources and maintenance fences, and recovers only
an intent marked for that exact unqualified discard. No guest package, GUI or
free-space admission is required for cleanup. Focused initial22tests and full671tests/7skips/0failures passed (156.044s).
Three actual CLI checks and docs-check286files pass. Signed release8 now passes
11 public CLI/filesystem checks on the real test Mac, including actual native
delete failure and durable retry. All3nonbootable fixture directories are gone.
This is signed filesystem-command proof; it boots no VM and cannot qualify a base.

Next: obtain adequate test storage without reducing policy; fresh reserve/payload/stage/authorize/GUIboot/collect/qualify; actual GUI
service login/logout/recovery; full two-VM coordinator/consumer acceptance;
build-tool compatibility, performance/stress and final release validation.
Keep current diagnostic VM, restore IPSW, encrypted volume/passphrase, authority,
paused test CI and temporary selected-user membership until campaign cleanup.

## Source and ownership

- Worktree: `.worktrees/sandbox-completion-20260913`.
- Branch: `codex/sandbox-completion-20260913`; inspect git for the current tip.
- Draft PR: https://github.com/Layr-Labs/d-inference/pull/996.
- Main checkout and unrelated providers/edits remain untouched.
- Evidence: `/private/tmp/darkbloom-sandbox-completion-evidence`.
- Disposable lab: `/private/tmp/darkbloom-sandbox-lab-20260913` on both Macs.
- Private primary fixture: `/private/tmp/darkbloom-physical-acceptance`, mode0700.
- Root owns VM lifecycle and privileged test-host actions.
- Test CI stays paused and temporary runtime-group membership stays until the
  machine campaign finishes. Go-cache deletion approval remains unanswered.

## Product implemented

The private alpha is an opt-in offline macOS CPU sandbox service. The real
coordinator owns account admission, durable leases/fences, idempotent lifecycle
and command records. The current nonroot host service holds machine-wide exclusive
runtime ownership and authenticates a signed root guest supervisor over vsock.
Its prior system-daemon deployment is unsupported: UID430 VZ startup failed host
security/key generation. Controlled Aqua LaunchAgent execution, authenticated
guest work and cold-boot persistence now pass. The selected GUI-user plan and
Serve identity enforcement are implemented; actual persistent service lifecycle
remains an implementation gate.
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
or wheel membership. Runtime group431 originally contained only the broker.
Root temporarily added gaj501 for the controlled actual-GUI discriminator;
restore only with the independent quiescence proof described below.
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

The actual CI runner is system/com.layr-labs.m3-max-org-runner, now disabled and
unloaded after a fresh idle check and independently confirmed process exit.
Its original unchanged plist hash:
aff318a6a960fb840510eb52938ca9dba8b9d880497ee8df5f4592431da8fbdf.
Its effective launchd exit timeout was60seconds. Initial15second quiescence wait
expired, then two independent snapshots proved no Listener/Worker and service
absence. Preserve the original failed record and later confirmation amendment.
Restore its unchanged original plist and enabled state only after VM cleanup
and runtime ownership release, using ci-service-pause-v2.py --resume.
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

All operator VMs are stopped. Probe3 temporary installer staging/job were removed
successfully by cleanup-v2 session77678. Original proofs, raw receipt and both
bounded logs were fsynced under root-private operator3/cleanup-v3-evidence before
unlink. Gate cleanup-result.json SHA
e0e2c0383f2aaf242fcad14f5d9f820b87aabddc16771081b3abf904ae5c5e83.
Cleanup fully detached, reproved stopped/no-openers and preserved AppleToolchain.
The first cleanup attempt48693 refused before any writes because APP_PARENT
inherited root:admin0700, while the helper expectedroot:wheel. Read-only27784
proved exact directory ownership/inodes/noACL; corrected helper pins parent
0:80/0700/inode18502, run0:0/0700/inode18503, result0:0/0700/inode21704.
No guest permissions or account state were changed. Corrected helper SHA
2f69b1ac12cbe303291fb5f8b9b85935e31a661fbe37758719b8016f67e655a3.
Permanent installed guest/bootstrap/daemon/synthetic manifest remain. A separate
owned clone with real DBCONTROL/DBWORK must qualify the normal HMAC/vsock channel,
workspace cold mount, tenant commands/files and teardown. The reusable original
must never receive instance credentials or tenant work. Current probe disks are
small empty public images with no instance.json or secrets.

The broker authority inode remains16777229:29088927. Root operator holds its
exclusive lease across each Lume child; child501:20 receives transient431 and
inheritedFD4. Root subsequently added temporary gaj runtime-group membership for
the actual GUI discriminator; it remains active. CI was disabled/booted out by session72684 after fresh idle proof. The initial
15second wait expired; service later finished exiting. Read-only confirmation
session24418 proved two spaced snapshots: absent+disabled, no Listener/Worker,
unchanged original plist. Original failed pause record remains; confirmation is
root-private /private/tmp/darkbloom-ci-pause-20260913/pause-confirmation.json.
Use ci-service-pause-v2.py --resume only after all machine work/VM cleanup; it
accepts that hash-bound amendment and restores the original enabled service.
No host daemon is registered.

## Remaining gates

1. Qualify a separate clone from the cleaned installed candidate using real authenticated vsock/control/workspace,
   tenant commands/files and restart. Prove clone/material cleanup independently.
2. Integrate accountless preparation using the implemented schema2 receipts.
   Candidate persistence is implemented; root staging/boot orchestration remains. Raw-create must retain machine
   authority in the actual installer process before a new creating CLI is exposed. Preserve legacy provenance and normal template-ready gates; no
   arbitrary raw VM adoption, fake retirement boolean or public readiness bypass.
3. Finish the supported host launch/account policy after the GUI discriminator.
   Build/sign fresh artifacts, prepare a product-owned qualified base and
   install/enroll the actual host service on the already reserved test machine.
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

## Broker qualification staging

Root-protected exact release6 is now installed only as test artifacts at
/Library/Application Support/Darkbloom/qualification-release6 (no service).
Frozen test executables live under qualification-tools root:wheel0555:
qualify-guest-vsock SHA1d61d383d654d73af4fdc1eeafa7962d8c28b2e053e30d89c75b3e914ec069d3,
tenant-fixture SHA08ec9f90df0667ed75021c5261fb6a923002f0ad6b8192ec72821c988f327fa4.
Initial root-copy wrapper's umask made files0500 and broker exec deniedEACCES;
only those verified test binaries were corrected to intended0555. Finalize53520
then ran the product release/tool validator as actualUID/GID430 with transient
runtime431 and passed0; no materialization or guest execution occurred.
Evidence /private/tmp/darkbloom-vsock-operator-20260913/{release-copy,artifact-stage}.json.
New encrypted socket parent /Volumes/DarkbloomSandboxTest-20260913/host/qs
is430:430/0700. The original runtime authority inode remains unchanged.

Root85597 created qualification-import1 and qualification1 from cleaned probe3,
sparse-copying only paired config/disk/nvram then using native same-volume clone
to regenerate MAC/machineID. Actual UID430 materialization passed with encrypted
128MiB control and25GiB workspace. Setup gate SHA
de5fc70164c48cb6478bb788f8b2ae49e5f68449245814f06d769907c65a7dde.
Boot29554 owner exited70 in0.984s before guest commands. Root independently proved
stopped/no-openers/available guards and authority release. Boot gate SHA
3939c39d17f44097994a6be937ff9476ac96f046e3cdd49ead4ab8121a469591.
Scoped Apple logs show VZ helper SecKeyCreateRandomKey error-25308 and broker430
ctkd security error. No keychain/password/SIP/TCC workaround was attempted.

Apple DTS says Virtualization is not daemon-safe and recommends GUI-agent
deployment: https://developer.apple.com/forums/thread/841688 and
https://developer.apple.com/forums/thread/786363. Source host inspection now
checks actual security session and audit UID rather than console-user presence;
ten focused tests passed. Account policy/deployment integration remains pending.

Root76841 deleted only obsolete task-owned probe1 after retaining evidence and
stopped proof, reclaiming23263719424bytes. All other models/Go cache remain.
Do not weaken full product capacity reservations; the controlled COW GUI replica
uses a separate20GiB diagnostic headroom check, not product admission.

## Active GUI discriminator

Temporary membership root35430 added only gaj501 to runtime431. Baseline SHA
944441759c3a91204141bb66637709c4f3684bcaa3eb46aed8e61e80d5a179bb.
Root proof /private/tmp/darkbloom-gui-membership-operator-20260913.
The original authority inode remains unchanged. Restore helper
temporary-runtime-membership.py requires full root quiescence.json schema and
only removes that exact membership after owned job/VM/authority quiescence.

Root94606 staged test agent SandboxGUIQualificationAgent under protected
qualification-tools, root:wheel0555, inode29913650, SHA
35b11d9ed60b3a57de4fb53f9e40cb517ef0565a5448d066d9e51c982a452127.
Root90972 prepared a new encrypted GUI501 replica, preserving original430
config/machineID/MAC/disk/NVRAM/control/workspace/credentials byte-for-byte.
Only copied host paths change; original430 source is stopped/unchanged.
Replica gate3f3ff39ffd8b446aa6d63a5b3b49d0c61328f8b6323d556404738142c8a9492f.
Agent config78def11864991bec84212b6df00588723902aa414247a4abf32c92bb0190449e.
Actual GUI watchdog session74012 finished after121.36s: owner exit0 and clean
stop, but client exit1 authenticated_readiness_timeout. Actual context501:20,
audit501, parent1, security session100092/attributes8240, runtime431 present.
Root independently verified quiescence and unloaded the exact GUI job.
Root gate /private/tmp/darkbloom-vsock-operator-20260913/gui-watchdog1/watchdog-result.json
SHA f0d4cd5fc4720ee542e130a8b873058f144e2e321f84ad1a900ee78533e057b5.
Restoration attestation SHA64b9a6a9dc9b8fb2e2493017a9a4e610fc307e362f5986f06b213a0698069536.
This proves the selected VZ launch context resolves the immediate security
failure; it does not establish authenticated guest readiness. Read-only offline
guest bootstrap inspection is the next diagnostic. All VMs are stopped.
Temporary membership is retained for subsequent GUI tests. The separate
launch_gui_v2.py fixes complete restoration attestation and failed-test exit
status, with9Python tests passing locally and3newtests on remote Python3.9.
Its SHA223fcc9ee0a7555939d2dfd6e877b1246374c445fa9176b088ea8da47c269af8.
Do not restore group membership until independent root stopped proof exists.

## Follow-up guest inspection and current source work

Full CI34800803900 passed on9646f2b78, including macOS Sandbox Tests
job103842928274 (5m24s). The bounded race-fixture regression no longer hangs.
Integration34800804091 also passed; E2E benchmark34800803894
awaits its human environment gate. No benchmark approval was taken.

GUI deployment preparation3abe05f71 replaces the unsupported daemon generator
with explicit --gui-user-plan and exact existing local hostUser binding. It
generates only qualification artifacts, no activation or relogin startup.
Selected administrator is explicit trusted host owner; separate nonadmin GUI
account is recommended, not created. UID2001 rejected.65release-tool tests pass.
Actual readonly gaj501:20/GeneratedUID4835FFC8-BFB9-4D11-A185-C0BEB5389D5C/home
/Users/gaj validation passed, admin=true and runtime431 membership=true.
Protected identity-file binding at actual Serve startup is now being built;
continuous session-loss handling and login persistence remain subsequent work.
The accountless product first-boot payload/receipt producer is also in progress,
separate from diagnostic schema1 receipts and legacy SSH preparation.

Root92147 staged immutable qualification-inspection1 modules; root81384 read
the GUI replica Data volume read-only. Artifacts/daemon/synthetic manifest all
match release6 and root metadata. State/control directory exists; root
instance.json is absent. No credential/log content read. Inspection SHA
0cdb4ab5f16b7287b845db4200ea05d1bb74fde143a4a637671e7cea04d74e1d under
/private/tmp/darkbloom-vsock-operator-20260913/gui-offline1/inspection-result.json.
Fully detached, stopped, no openers; original Apple attachment and image
mtime/ctime unchanged. GUI boot disk inode529, NVRAM530, control533, workspace538
on encrypted device16777240. DataUUID A3B3C469-3618-441B-B64B-79E80D5E5921.

Root88143 staged immutable qualification-inspection2 and performed another
read-only pass, bounded to four public diskutil scratch plists. DBCONTROL is
disk3s1 backed by disk1s1, APFS and WritableMedia=false; DBWORK is disk6s1.
The current scratch physical.plist is empty. No missing/invalid physical-store
field was found. Same independent detach/unchanged/stopped proofs passed.
Result /private/tmp/darkbloom-vsock-operator-20260913/gui-offline2/inspection-result.json.

Next diagnostic changes only the disposable GUI replica's guest LaunchDaemon
to retain its existing stdout/stderr under root-private state. No bootstrap or
guest binary changes, no original-source change, no readiness claim. The
physical agent is preparing that exact guarded mutation; it is not executed yet.
Root30254 prepared new host control /Library/Application Support/Darkbloom/gui-discriminator2
and GUI501/evidence2, retaining the same exact label required by the frozen agent:
io.darkbloom.sandbox.gui-discriminator1. New agent config SHA
a42a96a52db613fce8e9d6f3b85a3e753d434dcdffdc87a2ca767d937fc3a696.
No VM started. Prepared watchdog launch_gui_diagnostic2.py differs from testedv2
only in new control and evidence paths. Its next root evidence directory is
/private/tmp/darkbloom-vsock-operator-20260913/gui-watchdog2. All VMs remain stopped.

## Latest continuation: native guest cleanup investigation

Committed host process identity binding5b52226af and accountless payload
generatorc9927c968. Full Swift488tests/7skips/0failures in106.7s; subsequent
guest cleanup diagnostic commitb8c63ade1 has14focused passing tests and a
successful release guest build. Agents then hit usage limits; root continues.
Latest pushed revision remains9646f2b78; these local changes are not pushed yet.

Root12576 installed only diagnostic stdout/stderr keys in the GUI clone's guest
LaunchDaemon, preserving original bytes; new plist inode23845, SHA
f49340dabd4c8addeefe64cddcc85c30d36b45555c6e8352e994efff3ac8f3bd.
Root45685 boot2 reproduced HMAC readiness timeout, owner0 and independent
quiescence. Rootwatchdog2 SHA
c78a988758fe1a1f985c6fed47944de09d9447fa5a5e61419f455a568cabc0bb.
Root10694 read512bytes of generic native startup errors, no configuration.
Read gate gui-diagnostics-read1/diagnostic-result.json SHA
3201230c70e86808a53cdd58f55cc6f69a0a2a13aff77dc25d0b815898ade00d.
Root24792 read only classification counts from actual guest sudoers:1709bytes,
no NOPASSWD text at all. The comment-parser hypothesis is ruled out; no policy
change made. Source raw-comment check remains a possible separate robustness
issue, and numeric #UID rules must never be stripped as comments.

Signed diagnostic guestb8c63ade1 SHA
241262632542257a82e6779f2592c5e6bd9bf997444ecbeedd756b3bcd953546,
2466704bytes, in both labs guest-cleanup-diagnostics-b8c63. Root62333 replaced
only the GUI clone's exact prior guest binary inode22454/bc7364..., preserving
it in root evidence. New guest inode24744; bootstrap/plist unchanged.
All host attaches detached with Apple attachment unchanged and native stop proof.

Boot3 session20481 failed BEFORE guest execution due stale fixed diagnostic
socket: owner1 Address already in use, client143. Guest logs/VM images unchanged.
Watchdog3 SHA0ec1838c20cfc32624a9affeb6d760aab8a2970cfc92013e6e851ae60c20875f.
The PRODUCT already allocates unique endpoint directories per start. Root fixed
the diagnostic harness to allocate run/attemptN/guest.sock and a matching new
harness configuration for each later attempt; no stale endpoint was unlinked.

Boot4 root14479 with freshendpoint run/attempt4 passed hoststart/owner0, failed
authenticated readiness. Watchdog4 SHA
bbe493015d226f70f345eb497b22f0786a7c2bf4ca0d9c1c2ea0aca6ba386b2b.
Read99842 observed eight new fixed diagnostic errors:
guest_bootstrap.tenant_domain_verification.policy_mismatch. This rules out
earlier context, identity, guest policy, removal, worker and process-count stages
for those invocations; no tenant jobs were admitted.

Root91463 installed ONE read-only diagnostic guest LaunchDaemon
io.darkbloom.sandbox.tenant-domain-probe, inode25633, SHA
66adfab0d9ebb8219b07ee0e037769ad7357fd15c2306295678b8868a77628ff.
It checks virtual root, sleeps30s, prints only gui/2001 and user/2001. New logs
tenant-domain-probe.stdout/stderr remain in root0700 state. Image is diagnostic,
never ready. Boot5 root63244, freshendpoint attempt5, owner0/native stopped/root
quiescence true; host config571905068e3ca15bea4c839b2b49df85535b28e4307309b47924cc37bd3a314e.
Watchdog5 SHA58510ec15e2ce0fa596a9d153aa19f4398b7284d191b89e8f7b0c6cafa305385.
Read36464 fully detached/stopped/noopeners. gui-domain-probe-read1 contains raw
bounded domain logs. GUI domain absent112; user domain is an empty Background
domain with services/unmanaged/endpoints all empty, creatorlaunchctl[818],
activecount3, externalactivation1, inprogressbootstrap1, propertiesempty and
ordinary bootstrap/access ports. This format appears to match the existing
parser; the failure may instead concern prior-removal evidence or the exact
immediate verification snapshot. Do not weaken empty-domain proof based on a
later sample. Next action: refine fixed diagnostic reasons or explicitly retire
domains again after the UID2001 cleanup worker before final verification.

Native endpoint cleanup WIP: patch0010 makes bridge.stop unlink its own socket
synchronously under descriptor-lifetime lock, preserving replacement inodes.
Tests cover immediate rebind/replacement preservation. A preexisting relay test
incorrectly assumed dup() reused its old FD despite concurrent tests; it now
uses F_DUPFD at the owned hole and bounded retry without replacing foreign FDs.
Patch currentSHA6abb6aa1cb582fe0157fc147159a0168160d1e79f39d3df8d40b96bbbade07ca;
lock/Swiftpin/contract test/required selectors updated but NOT committed.
Private work /private/tmp/darkbloom-managed-restore-native/work includes patch9
uncommitted relative to its baseline8; patch10 diff is only bridge and two tests.
Focused4 and combined11 tests pass. Initial full run diedSIGPIPE13; debugger
run found the descriptor-reuse fixture mismatch. After fixture correction,
full195tests and11mandatory selectors pass (native-bridge-full-tests-v2.log).
Initial SIGPIPE remains unattributed; retain its log and repeat/CI evidence.
Clean10patch replay, Swiftpin tests, final native artifact build and physical
validation remain. All VMs currently stopped; temporary GUI runtime membership
and CI pause remain active. Primary providers and production untouched.

## Current physical run and validated local tip

Local HEAD398a0c294 includes tenant cleanup sequencingf6fbae859 and native
endpoint patch10. Full sandbox494tests/7skips/0failures (104.99s), log
sandbox-domain-cleanup-full-tests.log. Native patch10 is now committed at
SHA6abb6aa1cb582fe0157fc147159a0168160d1e79f39d3df8d40b96bbbade07ca.
Clean replay of all10patches in /private/tmp/darkbloom-endpoint-patch-replay-b5makhme
matched edited source and passed full195tests plus11mandatory selectors.
The initial SIGPIPE was not reproduced in the corrected full run or clean
replay; its earlier log remains preserved. The independent descriptor-reuse
fixture mismatch was reproduced under LLDB and fixed with bounded F_DUPFD retry.

Signed runtime10 built successfully at primary lab/runtime/lume-endpoint-cleanup-10:
lume SHA c12b314eeb9374eafe898441a4a3383880d51592406dd0fbb619c084039a2752,
provenance SHA4632bdc88b4a6236502960e7e53239bc9e281ced1b0833711b00df06e0e76aa9.
Not yet transferred or physically tested. Diagnostic VM continues using exact
runtime8 so host runtime changes do not confound guest debugging.

Guestf6fbae859 adds domain removal after the numeric-UID cleanup worker exits,
then zero-process and domain verification; prior-removal requirements remain.
It also distinguishes fixed domain-verification failure reasons. Tests cover
worker-created domains, respawn during removal, persistent processes and failure.
Signed guest /private/tmp/darkbloom-sandbox-lab-20260913/guest-domain-retirement-f6fba:
2490592bytes, SHAfd293b45cee8aeea48bd434eec4e821a2a62d432f787892a4a2b3ed36aef1101.
Root98258 installed it only in diagnostic GUI clone, replacing prior guest
inode24744; new inode26517. Exact temporary domain-probe job inode25633 was
backed up and removed. Bootstrap/permanent diagnostic guest plist unchanged.
All attachments detached, Apple image unchanged, VM stopped/noopeners proven.

Boot6 root7264 with freshendpoint attempt6: hostowner0, HMAC readiness timeout,
rootquiescence true. Configd0cd2db5231b7c0d410a1720d281f523847935b63c86d786e9ffe2f70b042c10.
Watchdog6 SHAcf0c6e86429de3fcede55793243449b7d02c3b15a1c6682f7e403cd1fe3d2a3e.
Read29650 (gui-diagnostics-read4) shows newer failures at
guest_bootstrap.tenant_domain_removal.policy_mismatch; the extra removal did not
resolve readiness and may expose an already-in-progress domain teardown.
Do not infer successful cleanup or relax proof from the later empty-domain sample.

Root56002 installed a new ONE-SHOT diagnostic job in this disposable clone:
io.darkbloom.sandbox.tenant-domain-sequence1, inode27413,
SHAd9b8b2eba1ff459e871fefe9fd7ff843e3553777ab81591deb4d81760f1c9459.
Its fixed script checks virtual root, sleeps10s, unloads ONLY the owned guest
daemon to prevent competing cleanup, then captures exact print/bootout statuses
for gui/2001 and user/2001 before/after the fixed tenant-cleanup worker. It never
changes accounts or host services. Logs are tenant-domain-sequence1.stdout/stderr
inside the guest's root-private state. Remove this exact job after evidence.

CURRENT root session66008 is running GUI attempt7, freshendpoint attempt7.
Root control /Library/Application Support/Darkbloom/gui-discriminator7;
GUI evidence /Volumes/DarkbloomSandboxTest-20260913/gui501/evidence7;
config820f141b9993337310736a4bbd2e0b8abd8b25301e09b9886bc23d03323a90bc.
Root watchdog output is /private/tmp/darkbloom-vsock-operator-20260913/gui-watchdog7.
Expect readiness to fail deliberately while its diagnostic job unloads the guest
daemon. Wait for actual terminal/quiescence, then collect only the fixed domain
sequence logs with a read-only helper bound to watchdog7. This should distinguish
launchctl errors/in-progress teardown from an output parser mismatch. No native
tenant workload qualification or ready-template publication has occurred.

## Guest launchd diagnosis after attempt 9

HEAD cd1449e5e adds bounded domain-state stabilization (19 focused tests pass).
Attempt 7 completed with host owner exit 0 and independently proven quiescence;
its exact shell sequence saw a transient pending-request block after bootout.
Attempt 8 with cd1449e5e still failed readiness at the fixed diagnostic
`tenant_domain_removal.domain_inspection_unproven`; stabilization is not a
physically proven fix. Its watchdog digest is
36fd23cd48ae266dcaf9e9f5d440bb783d7afd922a3b0e3c02eeaba05edbf57a.
Current diagnostic guest hash is
2776af1e7e137db88df629174264a01b741b1430945f5b7b0f9fb4d987b36b4c,
installed only in the GUI clone (inode 28294).

Attempt 9 used a separate signed native probe with the actual SandboxProcessRunner.
It proved exit 0 and 112 preservation, no ignored SIGCHLD disposition, and exact
stderr capture. `launchctl print gui/2001` returned 125 (domain does not support
specified action), while user/2001 held 39 default Apple services, including a
running distnoted. A successful user-domain bootout was followed by a newly
created empty Background domain; the numeric UID cleanup worker recreated the
populated user domain. This is not evidence to accept arbitrary exit 125, ignore
services, or bypass cleanup. Product output limits were not implicated: only the
probe's 4 KiB capture truncated the populated domain listing.

Attempt 9 watchdog SHA:
161a97ffd0ee8c40ad4af3b43a34f9677986358300a4b9580e6f67d72d7230aa.
Root log: /private/tmp/darkbloom-vsock-operator-20260913/gui-native-runner-read1/
native-domain-runner1.stdout, SHA
f8b2448a8e06191640261515918e837aaf54bd5f7012831db826a00f38430102.
All attachments detached, owned VM stopped, original Apple image unchanged.
The latest pushed commit 4aa723e7e passed CI 34805686214 and integration
34805686104. No physical readiness or release claim follows from those checks.

A focused attempt 10 is now running the fixed guest-domain order probe, testing
GUI inspection immediately after retiring user/2001. It uses a fresh endpoint
attempt10 and root control gui-discriminator10, config SHA
71017d30f2b612d3015cccf15a3bdbc5f63a437fd29a58711f77973e27c5bb81.
Root watchdog session 77123; output gui-watchdog10. The diagnostic guest job
io.darkbloom.sandbox.domain-order1 (inode 29930, SHA
42c9bd28b3c611177c4a44781c1b8670a8e03beb30af53a9c1ad881d4f05a5be)
replaces the exact native-runner job inode 29117. The native probe executable
inode 29116 remains, unused. The first staging helper stopped on an overbroad
stat comparison after reading changed atime; a separate recovery verified both
exact job digests and stable identity fields, then removed only old inode 29117.
Original failure and recovery proofs are retained. Remove the order-probe job
before a normal readiness run. No account, keychain, or original base changed.

Still required: proven guest cleanup/readiness; completed accountless staging,
qualification clone and readiness publication; actual host service lifecycle;
two-VM authenticated coordinator lifecycle, expiry/recovery, isolation and
performance evidence; final modularity/review and release gates. Runtime10 is
built and tested locally but not yet physically substituted for runtime8.

Full sandbox suite at cd1449e5e subsequently passed: 498 tests, 7 explicit skips,
0 failures, 132.605 seconds. Evidence:
/private/tmp/darkbloom-sandbox-completion-evidence/sandbox-domain-stabilization-full-tests.log.

## Proven cleanup-order defect and current fix

Attempt 10 completed, owner stopped and quiescence independently verified.
Watchdog SHA de0c2e195b016813133d669925bf6dc1ea2925c8496b9f791a9973939cf62ddf.
Root read gui-domain-order-read1 captured 7,686 bytes without truncation;
domain-order1.stdout SHA55642784059fe0fc1d25abf903461aafa705b3120a26127775a5bd5d2286bb84.
The sequence establishes that user-domain bootout succeeds and then GUI print
returns exact absence 112 both immediately and after 200 ms. Printing user/2001
recreates an initially empty domain and subsequent GUI inspection returns 125.
The cleanup worker also recreates the domain; another bootout restores 112.
Thus printing an empty user-domain structure is not a safe final verification:
it recreates the domain and schedules services after that empty snapshot.

Commit b4f6bbaf5 removes the empty-domain parser and its false verification path.
Cleanup retires the user domain before GUI inspection, removes the user domain
again if GUI removal occurred, and never queries user/2001 after final removal.
Successful bootout (or exact identified absence), exact GUI absence and a final
zero-live-tenant-process snapshot are required. Exit125 still fails closed.
The post-worker removal remains required. A process appearing during final
verification causes another cleanup attempt. Twelve focused cleanup tests pass.
The new signed guest and a normal physical readiness run remain to be performed;
latest all-tests evidence is still the 498-test cd1449e5e run, not b4f6bbaf5.
All test VMs stopped and attachments detached. Temporary domain-order job
inode29930 must be removed when installing the new guest. Native probe executable
inode29116 remains unused in this diagnostic clone.

Signed b4f6bbaf5 guest: 2,602,672 bytes, SHA
932f14c6e5757261c5c9edd7b807784e8a502ff04d7c585796b5aeecfdd0ee1c,
Developer ID identifier io.darkbloom.sandbox.guest. Root63948 installed it only
in the GUI diagnostic clone, new inode30744, replacing exact inode28294 and
removing only the temporary domain-order plist inode29930. Independent stopped,
attachment and untouched-image checks pass. A first host preparation attempt
stopped before mutation on an image-opener observation; a later root lsof check
showed none and the same guarded preparation then succeeded.

Current normal attempt11: rootwatchdog92975, gui-discriminator11, freshendpoint
attempt11, evidence11; config SHA
d0c60d17a2e7a1dab4365becc12a9aa74c75cef11b1880c8b14bb325c5c0c8de.
Wait for terminal/quiescence before any disk inspection. Prepared readonly log
reader is primary/remotelab read-gui-diagnostics-run11.py (output gui-diagnostics-read6),
requiring the actual watchdog11 digest. Full b4f6bbaf5 suite session11126 is also
running, log sandbox-no-recreate-full-tests.log. No new readiness claim yet.

## First authenticated physical guest acceptance PASS

Attempt11 completed successfully. Client exit0, VM owner exit0, native stopped
state and root quiescence verified. Rootwatchdog SHA
62abfbdd15d3f22cba4b8613badd05beed0ac670615abca3d456affa3fb58567.
Evidence11/client.stdout records authenticated readiness, invalid-credential and
invalid-instance rejection with positive controls, numeric UID/group/account
absence plus root-file/raw-disk/network isolation, native CPU work, file chunk
resume/commit/replay/version/path controls, both output bounds, descendant
cleanup, actual timeout cleanup, and disconnect cancellation cleanup. These are
selected physical guest checks; they do not qualify the template or host service.
The same run staged a workspace marker and first-boot UUID for the next cold-boot
run. Build tools are explicitly absent: xcode-select presence=false and
build_tools_qualified=false. Do not rerun the exercise in the same workspace and
overwrite the first-boot marker before testing cold boot.

Full b4f6bbaf5 sandbox suite passed497tests,7skips,0failures in134.200seconds;
log sandbox-no-recreate-full-tests.log. The count decreased because the invalid
empty-domain parser and its tests were removed; new tests cover no recreation,
error125 rejection, domain retirement order and process respawn during final
verification. This is the first successful authenticated guest campaign.

NEXT: preserve evidence11, implement a selected --cold-boot mode in a new version
of the GUI test supervisor (frozen current supervisor always invokes --exercise),
then prove different guest boot UUID and retained workspace marker. No guest
probe jobs remain. The unused native diagnostic probe binary inode29116 can be
removed in a later exact guarded cleanup. Full base factory, actual host service,
2VM coordinator campaign, build tools and performance/release gates remain.

## Restart qualification failure and master integration

Attempt12 used a new fixed cold-boot GUI supervisor, exact binary
cfc873e4344c86bdc674aaf6dfee05667cf33c1dbf1686d60e83ecbcc17c2515,
root-staged inode30326756. Readiness and authentication controls passed after
restart, but the cold-boot workspace test failed. VM owner0, root quiescence true;
watchdog12 SHA66732e49f3fbac0a33a01231133ab8a5ddbed3c14f6d30c6c6a19d05697ff011.
No claim of workspace persistence. A metadata-only diagnostic then ran as
attempt13 with the same instance/runID and unchanged guest/runtime.

Attempt13 also passed readiness/authentication and clean tenant execution.
The fixed stat probe reports ENOENT for the ENTIRE original qualification
workspace directory, marker, first-boot UUID and fixture. Download rejects with
invalid_workspace_path. This is not an ownership-only mismatch; cause remains
unproven. Native stop currently calls VZVirtualMachine.stop (immediate power-off),
and guest file publication fsyncs its source and parent but has no explicit
pre-stop filesystem flush. These are hypotheses to test, not a proven cause.
The current raw workspace image must remain preserved for diagnosis.

Attempt13 rootwatchdog SHA
8f3a8ab124b558579f239df14178ff628f0401e6a40eeb4f05901793a05b10b5.
Control gui-discriminator13, config SHA
da04d7d678f2366173a832940fd2e5380f179eb7d75854efa50f04d82a1c06c0.
Client/owner exits1/0; root quiescence true, all test VMs now stopped.
New exact protected diagnostic tools:
SandboxGUIColdBootDiagnosticAgent inode30340320,
SHA4a3f09a762cfc8b6c48b053fbc054a890ff0d517dc4cb09e34209fa4f47f8ef2;
qualify-guest-vsock-diagnostic inode30340322,
SHA98b6408d75c613008d2c9a3c376ba6f3449b6a15c702125c7b0d7ebcfd0ca5b8.
Sources: primary evidence/gui-vsock-coldboot-diagnostic-v3 and
vsock-coldboot-diagnostic-v2;4GUI and9qualification unit tests pass.
No source/production template was modified or marked ready.

Master advanced to5dcb43e69 (PR909 coordinator refactor and997/998/999 source/test
organization), preventing PR CI. Integration preserves its refactored config
validation table AND this branch's ServerConfig.Check immediately after Store.
Seven docs freshness conflicts and one additive build-doc section were resolved
without discarding either feature. Full coordinator suite passes30testedpackages
(API194.821s); DATABASE_URL and EIGENINFERENCE_DATABASE_URL were unset, so this
run is not a fresh live-Postgres validation. Docs lint passes286files. Logs:
master-5dcb-coordinator-full-tests.log and master-5dcb-docs-check.log.

The first merge commit attempt stopped in the pre-commit hook because this
worktree had no console-ui/node_modules (ESLint package resolution failed;
not a diagnosed lint violation). npm ci completed from the lockfile. Re-running
UI lint before retrying the merge commit; no hook bypass is used.

## Persistence barriers under physical validation

Merge25db5f754 now integrates master5dcb43e69. UI dependencies were installed;
lint passes with0errors/81warnings, full coordinator suite and Linux build pass.
Commit244009eca adds GuestWorkspaceDurability: fsync followed by F_FULLFSYNC,
required for API-created directory inode AND parent (including retries), upload
source before clone, and publication parent before success. Eleven focused
workspace tests pass. This strengthens durability but is not yet a proven fix
for the restart failure. Native storage remains .fsync and normal VM stop is
still an immediate VZ power-off; graceful guest shutdown remains a product gap.

Signed244009eca guest: 2,603,248bytes,
SHA8dd96a80d7c96d15cf49e143416c8bf665c9a47464885ee1733d06b8544a3369.
Root78068 replaced only diagnostic GUI guest inode30744 with inode32638;
readonly preinspection was gui-diagnostics-read6, watcher13 bound. Permanent
bootstrap/plist unchanged; no guest probe jobs. VM/image attachments stopped,
detached, noopeners and original Apple image unchanged. Fresh exercise attempt14
and coldboot15 helpers are prepared; do not claim either has passed before its
actual watchdog and client evidence. Source/library release hash mismatch remains
explicit in this diagnostic clone; no template readiness has been published.

Current full Swift suite session53115, log guest-workspace-durability-full-tests.log.
Push session63655 runs the mandatory pre-push Go checks before publishing244009eca.

244009eca is now pushed; mergeability is MERGEABLE. Fresh CI34809434499 queued,
integration34809434503 running, benchmark34809434497 waiting for its separate
environment approval. Mandatory pre-push Go checks, UI lint and Next.js build
passed. No environment approval or production mutation was taken.
Full Swift suite at244009eca passes497tests,7skips,0failures (134.888s).

Physical attempt14 on244009eca repeats every selected guest exercise successfully,
including strong-barrier mkdir/uploads, then client0/owner0 and root quiescence.
It stages a NEW first-boot UUID/marker after the prior directory was proven absent.
Current attempt15 is the cold-boot followup, rootwatchdog87427, control
/Library/Application Support/Darkbloom/gui-discriminator15, freshendpointattempt15,
evidence15. ConfigSHA1b2664bb5068e2f298f9471cea90e0442332847926bd165d12dccf5a5d4d055d.
Wait for that actual terminal result before claiming persistence or mounting disks.

## Strong-barrier restart PASS

Attempt14 watchdogSHA94bb5e183fbdc40bb1b13c9909e288cc99e36addc18679b78fb9af4e22437ea3.
Attempt15 watchdogSHA6c4152c06d784d0fb9283fca5d3843c72b9c984690c735a5cc125debe8cf8336.
Both client/owner exit0 and root quiescence verified. Coldboot15 passes exact
workspace marker, changed kern.bootsessionuuid, repeated authentication controls,
numeric identity isolation and native compute. This controlled pair passes after
the full-sync change, whereas12/13 before that change lost the entire directory.
This is selected physical restart evidence, not a fleet/crash-power-loss guarantee.
All test VMs now stopped; guest32638 remains in the diagnostic clone only.

Next product work remains: root accountless installation orchestration and
installed checkpoint writer, qualification capability clone consumer and genuine
readiness publication; actual selected-user host service signals/session recovery;
full two-VM ordinary-consumer coordinator campaign, build tools and paired workload
measurements. Runtime10 is still not physically substituted for8. Keep CI paused
and temporary gaj431 membership while the authorized machine campaign continues.


## Qualification consumer, clone resources and installed publisher

b48455139 implements package-only createQualificationClone. A capability is
single-use, bound to the issuing runtime, source snapshot and exact active lease.
Creation holds destination operation/lease locks and the retained source lock,
checks source/lease before and after native cloning, then writes fresh ordinary
lease ownership. Cancellation, expiry, changed source, native failure and bad
resource observations clean only destination artifacts; source and lease remain.
The shared creation executor is a separate focused module. 19 targeted tests
and full504tests/7skips pass (qualification-clone-full-tests.log).

32be94642 fixes ordinary clones retaining the base CPU/memory. A stopped clone
with the correct boot disk is configured through native lume set when necessary,
then observed again before ownership publication. The exact lease is revalidated
before settings changes and before publication. Native failure or ignored settings
cannot report the requested resources. The test runtime is now LumeCloneTestRuntime.
Ten targeted tests and full507tests/7skips pass (clone-resource-full-tests.log).
This is source/unit validation, not a physical different-size VM result yet.

6cf8f3381 implements publishInstalledCandidate in the exclusive, unfenced base
runtime. It validates bounded, duplicate-free complete installation and cleanup
JSON, immutable reservation binding, actual stopped source/ownership/resources,
current disk metadata and signed guest compatibility. It preflights all existing
files, publishes only matching-or-absent immutable evidence, writes the checkpoint
last and revalidates. Matching partial prefixes replay; conflicting, shared,
linked, special or unsafe names fail without overwrite. Reads use O_NONBLOCK to
reject FIFOs rather than block. The writer never mounts, installs or marks ready.
Six targeted publication tests and full513tests/7skips/0failures pass in149.389s
(installed-candidate-publisher-full-tests.log). Installation and cleanup inputs
remain caller-collected observations; root capture orchestration is not built.

No new physical VM runs occurred during these changes. Physical proof remains
exercise14/coldboot15 on guest244009eca and native runtime8. The test machine stays
quiescent with CI paused and temporary431 membership intact. No real host enroll,
two-VM campaign, guest build-tool installation or production mutation has occurred.

NEXT implementation order:
1. Add termination-signal cancellation around the GUI service and installation
   job, route cancellation through VM cleanup, monitor the actual graphical/audit
   session (not console user), and give launchd an adequate ExitTimeOut. Existing
   Serve cleanup begins only around its final client loop; include reconciliation
   and earlier post-runtime work. Use a subprocess test fixture for actual signals
   so XCTest's own signal state is never changed.
2. Implement the privileged base operator using the existing tested offline
   staging/reading helpers as the behavioral reference. It must generate its
   root payload from the verified package, take machine/source/native locks,
   prove stopped/no-openers, attach only the owned raw source, select only its
   Data volume, preserve preexisting Apple attachments, and persist root intents
   for partial-stage recovery. Root must not impersonate GUI VZ context.
3. Use a real selected-user GUI job for managed installer boot and actual native
   qualification. Collect installation/cleanup observations and call the new
   publisher, then issue/consume the new clone capability. Qualification still
   needs a durable attempt journal, actual guest checks and cold boot, clone stop/
   deletion proof, and source revalidation before ready-template publication.
   Existing consumed-capability revalidation requires an ACTIVE lease: the final
   source check after clone deletion must instead bind the durable released-lease
   cleanup proof while retaining source identity/lock. Do not bypass that by
   fabricating readiness or silently dropping source namespace identity.
4. Finish selected-user recurring service lifecycle, build tools, real coordinator
   two-VM/expiry/crash/ownership tests, workload measurements and final release gates.

## Cooperative service termination and GUI-session monitoring

Current local lifecycle changes:
- SandboxSignalCancellation owns SIGINT/SIGTERM handling only within the process
  entrypoint scope, cancels the operation and awaits it, then restores prior
  dispositions. Nested scopes are rejected without releasing the outer owner's
  claim. Actual signals are tested only in an owned subprocess fixture.
- Serve wraps all work after runtime construction in SandboxServiceShutdown,
  including startup reconciliation and token/client setup. Cleanup runs in an
  awaited detached task so cancellation cannot interrupt stop proof. Cleanup
  failure remains an error with its primary cause and does not release capacity.
- SandboxGUISessionMonitor captures the process's own Security/audit context,
  rejects an unusable initial session, and checks once per second during startup
  and service operation. Session ID, actual UID and audit UID must remain bound;
  graphical access must remain valid. It never relies on the current console UID.
- The CLI serve entrypoint handles clean cooperative cancellation as success;
  cleanup failures still exit nonzero. The generated qualification job allows
  600 seconds via ExitTimeOut. KeepAlive=false and no recurring login startup
  remain intentional until the physical lifecycle and activation gates pass.
- The shutdown, signal and monitor concerns are separate focused modules. The
  main Serve entrypoint stays thin. The public legacy prepare-base path has not
  been migrated or wrapped; integrate the signal scope when the new managed
  installation orchestration is built.

Targeted Swift validation passes18tests (service-shutdown-targeted-tests.log),
including prior process ownership tests. Python GUI plan/identity validation
passes18tests (service-shutdown-plan-tests.log). Full suite passes524tests,
7explicit skips,0failures in126.512s (service-shutdown-full-tests.log).
No remote VM, service, group or disk action occurred.
No actual logout/relogin or latest-native-runtime physical result is implied.
CI34811478625 and integration34811478687 at6cf8 remain in progress; the former's
coordinator, UI, docs, release-integrity and provider Swift test steps passed,
with nested provider tests still pending/running. Do not report whole CI success.

Resume next with privileged base preparation orchestration and a protected
selected-GUI-user installer job. Preserve all accountless receipts, source/lease
binding, machine/source/native locks and root attachment cleanup described above.
Physical evidence remains exercise14/coldboot15 on guest244009eca/runtime8.

## Recoverable offline accountless payload staging

AccountlessInstallationStagingJournal now persists the exact candidate/plan
intent under a stable exclusive lock before guest-file changes. Matching intent
reopens; conflicting/orphaned staged evidence, FIFO/shared/hardlinked records,
changed lock/directory identities and any boot/result/cleanup marker fail closed.
The immutable staged receipt hashes the intent and makes no installation,
attachment, stopped-state or qualification claim.

AccountlessOfflineOverlay copies exactly the ten generated/signed payload files
into an ALREADY-AUTHORIZED Data directory. It performs descriptor-relative,
no-follow, same-filesystem checks, preflights existing content, retains matching
file inodes, copies signature xattrs to unlinked temporary files, then uses
no-overwrite APFS publication. The copied release is signature-validated before
the temporary LaunchDaemon is published LAST. Partial staging can resume only
before a boot intent. Once staged.json exists, missing files are a conflict,
not permission to reconstruct the payload. Replaced Data-directory paths cannot
publish the boot job or success. Existing macOS parents and unrelated files are
preserved. AccountlessInstallationPayloadPlan validates the fixed paths, complete
inventory, candidate/payload binding and maximum boot duration; the producer also
calls that validator before publishing its plan.

The production authority/mount wrapper is STILL REQUIRED: these focused helpers
are internal and do not acquire machine/native locks, authorize a source, attach
or select a Data volume, start a VM, or publish installed/qualified readiness.
They must only receive the protected root-generated payload/journal and a Data
mount already bound to the exact owned raw source. Do not expose a CLI accepting
an arbitrary mounted path as installation authority.

Tests: initial19 focused tests pass (offline-staging-targeted-tests.log). The
first full run538tests/7skips passed (offline-staging-full-tests.log). Review then
added the completed-stage missing-file rejection and its regression; FINAL full
suite539tests/7skips/0failures passes130.665s in
/private/tmp/darkbloom-sandbox-completion-evidence/offline-staging-final-full-tests.log.
These are real filesystem/signature/cancellation fixtures, not physical staging
or a new root/GUI installation run. Signature tests relax Developer ID to their
real ad-hoc identities through a test-only dependency; production stays strict.

Fresh read-only test-Mac storage evidence:
- df available59215896KiB, about56.47GiB, on encrypted volume and Data pool.
- Go cache /Users/gaj/Library/Caches/go-build is68.24GiB (grown from27.8).
- HuggingFace cache126.53GiB; selected original8bitGemma remains removed.
- Own lab VM directories total91.24GiB reported by du: legacybase24.17,
  retirementprobe23.78, accountlessprobe3 21.65, accountlessprobe2 21.64.
  APFS sharing means du totals do not prove bytes reclaimed. Root quiescence,
  exact owned-image checks and retained evidence must precede any cleanup.
- Read-only inventory logs: test-mac-storage-inventory.log and
  test-mac-build-cache-inventory.log. Permission-denied hidden/encrypted430 paths
  were not inspected; this is not a complete disk inventory. Existing source,
  model and build caches were not deleted.

PENDING USER QUESTION: approval to clear ONLY the test Mac's68.2GiB Go build cache.
The earlier selection authorized the specific8bitGemma cache, not this cache.
Do not treat elapsed time or a goal continuation as approval. Continue independent
code work. Cleanup of our own obsolete VM fixtures is already within test scope,
but requires fresh root stop/native-lock/no-openers proof before deletion. Preserve
probe3/diagnostic evidence until the product replacement has passed relevant gates.
No mount, root mutation, service/group change, VM run or cache deletion occurred.

NEXT: implement the privileged source/native authority and Data attach/mount/
detach wrapper, connect this staging operation, then the selected-GUI installer
boot job and receipt collection/removal. Root must not run VZ by changing UID.
Root-to-GUI phases need durable intents and a clean ownership handoff: a launchd
job cannot inherit the root orchestrator's EX file descriptor, so the GUI phase
must acquire its own machine authority after the root offline phase is proven
quiescent. Preserve source identity and journals across that boundary. Then wire
installed checkpoint -> qualification clone -> checks/cold boot -> teardown ->
source revalidation and genuine ready-template publication. The final source
check must bind the durable released-lease cleanup proof, not the existing
active-lease-only capability revalidator.

Source3ac8a7fb6f431f75973cb6a4259128e90395479d is pushed. Mandatory pre-push
checks passed (offline-staging-push.log). PR996 body now includes the journaled
staging and service shutdown changes, before/after diagrams and remaining gates.
CI34811478625 and integration34811478687 both passed preceding6cf8f3381.
FreshCI34813684236 and integration34813684227 are in progress at3ac8a7fb6.
Benchmark34813684136 awaits its separate environment approval; no approval was
granted. Current pending Go-cache cleanup question has not been answered.

## Root source authority and process-lock proof

Current source implements LumeRootBaseImageGuard. Real/effective UID and effective
GID must be zero before accessing system authority. It acquires the permanent
machine EX inode itself; no configurable alternate authority or nonroot bypass
is exposed. Its explicit source owner must be nonroot. The private source reader
walks trusted root/selected-owner ancestors, retains the existing private source
namespace, verifies owner/GID/modes/ACLs/link counts and bounds record reads.
Ordinary runtime filesystem ownership rules are unchanged.

LumeBaseImageSourceLocks validates exact immutable reservation bytes, raw Apple
source ownership and resource commitments, and the supplied disk snapshot. It
holds base-preparation -> broker operation -> native resize -> config flock ->
POSIX run-owner locks, then retains a descriptor for disk.img. Missing native
resize/run-owner guards can be created exclusively with the selected owner's
UID/GID (raw creation can relocate a VM out of its scratch storage, leaving the
parent resize guard behind); existing guard inodes are never replaced. Native
config files may be0644 under the private source; mutable files must retain owner
read/write. Staging/prepared artifacts and provisioning/resize remnants reject.

Strict unchanged-snapshot validation is separate from collecting a new snapshot
after authorized offline IO. Both rebind source paths and records; the latter
still requires original device/inode/size. Neither hashes the disk or proves
native stopped state/zero foreign image openers. Root scope closure explicitly
closes source/image locks before releasing machine EX. The run-owner POSIX lock
is never reopened during validation: closing any second fd for the same inode
would release the process's lock. Two subprocess tests prove held/revalidated/
released behavior and denial while a different live process owns the native lock.

Ownership parsing was split into LumeVirtualMachineOwnershipRecord.swift and
LumeRawBaseOwnership.swift. The privileged decoder uses the same schema and
rejects duplicate keys, legacy restore sources and mixed ownership. The ordinary
ownership API behavior remains covered by the full suite.

Validation:9 focused source/process-lock tests passed in0.459s
(root-source-lock-targeted-tests.log); earlier raw restore/contract tests12 with
3explicit opt-in skips passed. A trivial compile failure from naming the explicit
scope cleanup method close shadowed Darwin.close; renamed closeForScopeEnd.
Full548tests/7skips passed after that correction (root-source-guard-full-tests-v2.log).
A final namespace recheck after record/image reads was added; FINAL full548tests,
7skips,0failures passed132.522s in root-source-guard-final-tests.log. These tests
use private nonroot fixtures, real descriptor/flock/POSIX operations and a real
child; they do NOT prove successful root constructor execution, disk attachment,
physical stopped-state or mount cleanup. No remote actions occurred this turn.

IMPORTANT NEXT SAFETY GATE BEFORE ANY ATTACH IMPLEMENTATION/USE:
A root process crash releases EX/native locks while a disk image attachment can
remain in the kernel. Add durable pending-maintenance admission to host-runtime
so new inference SH and ordinary sandbox EX cannot start until root recovery
proves cleanup. Recovery must be a root-only, exact-intent-bound path, not a
public ignore-maintenance switch. Couple it with a per-source offline-operation
marker enforced by the broker and pinned native runtime to prevent direct Lume
run/clone/delete/settings mutation after a crash. Root must persist intent/fences
BEFORE attach and remove them only AFTER exact detach/no-openers/source proof.
The new root process-lifetime guard alone does NOT provide this crash guarantee.

Do NOT reuse .provisioning as that durable fence. Current native source
LumeController.getVMDetailsLightweight automatically clears a provisioning marker
whenever disk.img and nvram.bin exist. That would erase offline recovery state.
Relevant native mutation entry points: VMDirectory.tryAcquireResizeGuard,
VMDirectory.saveConfig/delete; LumeController.clone, loadVM/get, updateSettings,
runVM, delete and create/setup. Trace every mutation and readonly inspection;
protect destination overwrite paths as well as source use, and preserve actual
stopped-state inspection needed by root recovery. The native worktree has NOT
been edited this turn and patch11 does NOT exist yet. Runtime pin remains10patches.

Native editable tree: /private/tmp/darkbloom-managed-restore-native/work/libs/lume.
It contains earlier uncommitted9/10 changes over its baseline; do not reset it or
accidentally include those again in patch11. Repo pin:
sandbox-macos/ThirdParty/lume.lock.json; patches under ThirdParty/lume-patches;
build-pinned-lume.sh carries mandatory selector gates. Prepare a clean base10
snapshot/diff for any new patch and verify a clean replay through the whole list.
The latest signed native artifact remains runtime10, physically untested; last
physical guest exercise14/coldboot15 used runtime8 and guest244009eca.

After durable fencing: finish the root attach/mount/detach wrapper and use the
staging overlay, then selected-user GUI installer boot, receipt collection and
temporary payload cleanup. Native status may interpret the root-held POSIX
run-owner lock as a live owner: define pre/post inspection ordering deliberately,
with machine/fence ownership retained, and keep image opener positive controls.
The retained root image fd is expected; exclude only that exact own fd, not all
root processes. Preserve the preexisting Apple Metal toolchain image attachment.
No base-template readiness, host enrollment, two-VM acceptance or build-tool gate
is complete. Go-cache cleanup approval remains pending and unacted upon.

Source3c34dbbdd5fd1d2a1fa0493861a84698224db0e9 is pushed; mandatory pre-push
checks passed (root-source-guard-push.log). PR996 body includes the root guard,
explicit maintenance-fence gap, before/after diagrams and548-test validation.
FreshCI34815356747 and integration34815356765 are running at3c34dbbdd;
benchmark34815356936 waits for separate environment approval, not granted.
Go-cache question remains pending. Native source/pin were not edited; preserve
existing9/10 work and prepare any new fence as a distinct patch11 after a clean
base10 snapshot. Next required work is durable global maintenance admission plus
per-source broker/native fencing BEFORE adding/using the root attach controller.

## Durable global maintenance and native CI relay investigation

host-runtime now has a root-only maintenance protocol, separate from the
permanent ownership.lock inode. HostRuntimeLease.beginRootMaintenance publishes
maintenance.json with schema1, operation UUID and protected-journal SHA256 under
an existing EX lease. Ordinary SH/EX acquisition checks absence both before and
after flock. Any present record, even malformed/special/linked, blocks new work.
Scope destruction/crash never clears the record. Root recovery requires exact
intent bytes; a live scope pins the record descriptor and rejects replacement,
changed metadata or namespaces. Shared leases cannot begin maintenance. The
package test policy can act only for its own Unix identity, not impersonate root.
finishAfterVerifiedCleanup requires root, exact scope and valid EX; the OPERATOR
must first observe cleanup and persist its evidence. The SDK does not infer
physical detach from JSON. EX remains held until all lease references end.

HostRuntimeAuthority, HostRuntimeLease, errors, intent, store and scope are split
by responsibility. Test fixtures/probes were also extracted. The abrupt-exit
probe holds EX through _exit(86); a direct kernel-lock positive control observes
EX held before exit and free afterward, while ordinary SDK admission remains
fenced. Exact recovery then works. Existing shared/exclusive/inherited-lock
behavior remains covered. All participating runtime binaries need this library;
old binaries do not gain maintenance admission from merely seeing a new file.

Validation: host-runtime18tests/0failures in0.745s
(maintenance-authority-crash-control-tests.log). Sandbox integration initially
failed because SwiftPM's cached local-dependency source list omitted newly split
files; touching Package.swift was insufficient. swift package clean on ONLY this
worktree's sandbox build artifacts refreshed the graph. Clean548tests/7skips pass
(maintenance-sandbox-clean-tests.log). After pin11, FINAL548tests/7skips/0failures
pass128.289s in maintenance-sandbox-pin11-tests.log. Provider CLI target build
passes19.57s (maintenance-provider-build.log). No test-Mac cache was cleared.

CI34815356747 at3c34dbbdd failed ONLY the macOS Sandbox Tests step "Test and build
the exact pinned Lume patch set". Native flushesLargeLastFrameBeforeFINAndKeepsReverseDirectionAlive
threw generic EIO after5.946s. The helper discarded the actual errno and swallowed
writer errors. Integration34815356765 and all other CI jobs passed. Full failed
log: /private/tmp/darkbloom-sandbox-completion-evidence/ci-34815356747-failed.log.
The CI failure has NOT been reproduced or diagnosed as a production relay defect.

Investigation root: /private/tmp/darkbloom-native-relay-investigation-20260914.
Baseline0 plus10repetitions all passed195native tests (full-baseline-0..10.log).
The original runtime relay source SHA remains
0b7f3a6aaea57d9decdf6f32b9af3f280b2557cbe32244dc551de6f9e1fd13ee.
A base10 snapshot retains original relay source/test files. Native runtime code
is unchanged. The new fixture executes the COMPLETE timed peer exchange on
dedicated test threads, avoiding blocking the cooperative test executor or
spending reverse-direction timeout on rescheduling its async continuation. It
retains the5s socket/relay deadlines, exact512KiB/FIN/reverse-ACK checks, cancellation
and descriptor-reuse tests. It retries EINTR, reports actual errno/byte counts,
propagates writer failures, stops/joins workers on failure, and adds a real EPIPE
writer-error control. Socket initialization transfers descriptor ownership only
after checked options succeed, avoiding double-close on a throwing initializer.

This is separate test-only patch11:
ThirdParty/lume-patches/0011-await-relay-fixture-io-without-blocking-test-executors.patch
SHA45f6324e1eac2adcc09e7462d14bf37d3ef216c74c109e369fc1c8b3c9fd009b.
Pin JSON, Swift pin mirror and contract expectations include it. The native test
script now requires13selectors, including the large-frame exchange and writer
error control. Native editable files are tests/DarkbloomGuestRelayTests.swift and
new tests/DarkbloomGuestRelayTestSupport.swift; earlier9/10 edits remain present.
Do not reset the native worktree or include earlier patches again in a new diff.

Clean replay was made from the actual pinned upstream object in this worktree's
.external/cua-lume-737dc2a06952 (verified origin); the synthetic native editing
repo does NOT contain upstream737dc2a... and cannot be used for git archive.
Fresh replay root: /private/tmp/darkbloom-relay-patch-replay-jz0o4goc/libs/lume.
All11patches apply with fuzz0; resulting relay/test files match the editable tree.
run-pinned-lume-tests.sh passes196tests plus13exact selectors there, log
/private/tmp/darkbloom-native-relay-investigation-20260914/clean-replay-tests.log.
Full native196pass7.232s. This is fresh source/test proof, NOT a signed runtime11
artifact or physical result. Latest signed artifact remains runtime10; last
physical work remains guest244009eca/runtime8, exercise14/coldboot15.

Also corrected stale RELEASE_VALIDATION.md text: final tenant-domain verification
never prints user/2001 and has no empty-user-domain acceptance path; current code
requires exact gui/2001 absence and zero live tenant processes after removal.

NEXT: the per-image broker/native offline-operation fence is still NOT built;
it is now patch12, since11 is the relay fixture. Then connect the global SDK
maintenance APIs to the root base operator with typed begin/recover ownership.
LumeRootBaseImageGuard currently acquires its own ordinary EX; avoid acquiring EX
twice when recovering an existing maintenance scope. Bind the protected journal
to the exact candidate/source, and distinguish original-snapshot checking from
same-inode recovery after authorized partial offline writes. Never weaken normal
source validation with a public bypass flag. Implement attach/mount/detach only
after durable global AND per-image fencing are enforced. Then installer GUI boot,
receipt capture/removal, installed checkpoint, clone qualification/cold boot,
teardown and actual ready-template publication. No root marker, mount, VM run,
service/group mutation, model/cache deletion or production action occurred here.
Go-cache approval remains pending; elapsed time/goal continuation is not approval.

Maintenance SDK committedf12f72810; native test-only patch11/pin and evidence
committedd8fa61dc58a33f3275be1acb4de141dd74461970. Both pushed; mandatory
pre-push checks passed (maintenance-relay-push.log). PR996 body now states the
maintenance protocol, native harness correction, actual verification boundaries
and remaining per-image/root-operator work. FreshCI34819884262 and integration
34819884263 are runningd8fa61dc5; benchmark34819884349 waits for separate
approval, not granted. Go-cache approval remains pending. No remote mutations.
Next is per-image broker/native offline fencing as patch12, then typed root
maintenance begin/recovery integration and the guarded mount/bootstrap pipeline.

## Per-image broker/native fence and signed runtime12

Current source adds LumeOfflineOperationFence with fixed .darkbloom-offline.json.
Any entry, including empty/malformed/directory/FIFO/dangling link, blocks ordinary
broker create/start/delete, clone-source readiness and direct durable-deletion
replay. Ordinary code never interprets, removes or repairs the fence. Four focused
broker tests pass; earlier83runtime/restore tests passed with1existing opt-in skip.

Native patch12 adds DarkbloomOfflineOperation and checks before/after native
resize-guard acquisition. Native run/get-for-operation/clone/delete/settings/
forced-pull paths refuse fenced images; settings mutation groups share the image
guard, and forced pull retains its destination guard through publication.
Read-only getDetails still works and leaves the fence intact. Storage overrides,
auxiliary virtio-blk, USB, mount paths and aliases are checked before VM startup.
The native CLI tests use deliberately non-bootable temporary Linux fixtures and
private per-child environments. They prove run/set/clone/delete/forced-pull denial,
readonly inspection, destination protection and unfenced settings as a positive
control. No actual VM is started by those tests. Native command fixture output is
file-backed/bounded and child execution has a deadline. A test used pull --name,
which upstream does not support; fixed to its positional name. The older Testing
macro also required capturing the throwing optional before #require; corrected.

Patch12 final path:
ThirdParty/lume-patches/0012-fence-images-during-offline-maintenance.patch
SHA4dfd68d6c6c739ca412c3e62e24b5611ca20e1b4618891d794406bb6fb831369.
Swift pin mirror, contract test and JSON pin match. Required native selectors now
number16, including fence commands, every entry kind and storage aliases. The
editable native tree adds src/FileSystem/DarkbloomOfflineOperation.swift and
tests/DarkbloomOfflineOperationTests.swift, modifies VMDirectory/Home/controller/VM,
and retains earlier9/10/11 changes. Base11 snapshots for this diff are under
/private/tmp/darkbloom-offline-fence-20260914/base11. Do NOT reset or fold earlier
patches into a later patch. Initial manual clean replay of12patches matched the
editable files at /private/tmp/darkbloom-offline-fence-replay-jzaueu49/libs/lume;
that snapshot predates the final auxiliary-storage addition. The official final
builder performed a fresh full archive/patch application for the final digest.

Signed FINAL runtime12 was built by build-pinned-lume.sh with RUN_TESTS=1 and the
existing Developer ID identity. Log:
/private/tmp/darkbloom-offline-fence-20260914/signed-runtime-final-build.log.
It passes200native tests (7.225s) and16required exact selectors, builds release,
checks signatures and seals the artifact. Final executable:
/private/tmp/darkbloom-sandbox-lab-20260913/runtime/lume-offline-fence-12-final/lume
SHA3afc5eb6e291718920a83e881c97e90f4c78866bc49ca66cc011e7f35d86bfad.
Provenance same directory/lume.provenance.json SHA
 aa973a866ae5e89e6f02caa448d142ee98c7039b16f6ba2b7a5a81649361b4ba.
Both signatures were independently rechecked with the exact identifier/team
requirements. It has NOT been copied to the test Mac or used physically.
An earlier signed candidate at runtime/lume-offline-fence-12 used old patchSHA
4b2c9cc14f011fc6479eed24eb955fb0e4f075f24feafcaf7e9ed14fa2210a5c and
runtimeSHA54de1f3376a05fae26c5695fb38164e7912f4a57111bd63b0b554f5bb08bfcee;
it is superseded and must NOT be used with the final pin.

Sandbox validation: initial552tests/7skips passed132.265s
(offline-fence-full-tests.log). During the final native release compilation,
a second run failed two older SSH-wrapper tests: testEnvelopeSeparatesStreamsAndPreservesExitCode
hit the5s outer zsh timeout, and testGuestLocalDeadlineStopsJobBeforeDelayedSideEffect
observed its sleep2/touch marker after a1s guest deadline. This does NOT prove a
fence regression or a production isolated-guest defect, but remains a recorded
load-sensitivity concern. All14LumeGuestCommandEncoderTests pass without the
competing build (33.379s, offline-fence-encoder-idle-tests.log). A full idle rerun
passes552tests/7skips/0failures in127.380s in offline-fence-idle-full-tests.log.
Do not call the under-load failure fixed. The legacy launchd watchdog performs
several status-file commands before bootout and can be delayed; production
isolated guest supervision is a separate path. Follow up before final readiness,
without merely loosening a deadline test or claiming absence of side effects.

CI34819884262 and integration34819884263 passed precedingd8fa61dc5. No remote
root, VM, service, model, cache or production mutation occurred. Go-cache approval
remains pending. Last physical proof remains exercise14/coldboot15 on runtime8
and guest244009eca. Final signed runtime12 is local only.

NEXT: integrate global maintenance scopes and per-image fence publication into
the typed root base operator. It must bind the journal to the exact reserved
source, publish global then image fences before any attach, and remove image then
global fences only after observed cleanup. Existing RootBaseImageGuard acquires
its own EX; recovery needs a root-only path reusing the already-recovered EX
scope, not a second acquisition. Distinguish initial unchanged-disk snapshots
from same-inode recovery after authorized partial writes. No public bypass flag.
Then finish guarded attach/Data selection/detach, GUI installer boot, receipt
collection/removal, installed checkpoint, clone qualification/cold boot/teardown,
and actual ready-template publication. These workflow/writer steps remain unbuilt.

Source2812390a561adbc3c1f8e110bac616f6ce7e8b97 is committed and pushed;
mandatory pre-push checks passed (offline-fence-push.log). PR996 now includes the
per-image checks, final signed runtime12,552-test idle result and unresolved
legacy-wrapper load-sensitivity observation. FreshCI34822858087 and integration
34822857983 run2812390a5; benchmark34822858029 awaits separate approval, not
granted. Worktree checkpoint may be one commit ahead; source/pin are pushed.
Next work is typed root maintenance/fence publication and recovery, then the
actual guarded mount/bootstrap workflow. Go-cache question remains pending.


## Typed root maintenance and real-root crash recovery (2026-09-14)

LumeRootBaseImageGuard now begins maintenance only after validating the full
candidate/reservation binding and absent image fence, then publishes the global
fence followed by the immutable root-owned per-image fence. Recovery uses the
existing recovered system EX lease, never acquiring it twice. The new
HostRuntimeLease.validateSystemExclusive rejects alternate/test authorities.
LumeImageMaintenanceRecord binds exact intent, reservation digest, source,
original directory device/inode and disk snapshot. LumeImageMaintenanceStore uses
the retained directory descriptor, bounded nofollow IO, root600/single-link/no-ACL
records, unlinked temporary publication and a pinned marker fd. Same-byte live
replacement is rejected. Normal readers never interpret/clear the marker.

Source recovery permits changed timestamps only with the original matching
per-image fence and unchanged reservation/device/inode/size. If a crash left only
the global fence, image-fence publication requires the original disk snapshot
unchanged. LumeImageMaintenanceCleanup binds the fence digest and final image
snapshot. IO closes before persistence starts (including uncertain callback
failure). The operator must independently verify cleanup, persist the checkpoint,
then remove the image fence before the global fence. Recovered completion never
reopens image IO, and can finish when the image fence is already absent.
Neither deinit nor a thrown error clears fences.

AccountlessStagingMaintenance composes the protected journal and root image
operation. The journal issues the exact maintenance intent, rejects missing live
intent, and persists staging-detached.json only after matching staged.json.
Detached completion permanently closes staging but permits exact completion
recovery. Orphaned/malformed/duplicate-key completion cannot recreate missing
intent or staged receipts. The actual mounted-image/installer orchestration is
still unbuilt; these APIs deliberately do not claim detached or stopped proof.

Validation (no native patch or signed runtime changes in this step):
- image-maintenance-focused-tests.log:28 tests pass (new image9 + journal4,
  existing journal6 + overlay9). Initial test compile had a local variable
  redeclaration; fixed before this passing run.
- image-maintenance-full-tests.log:565 tests,7skips,0failures,128.135s.
- image-maintenance-host-tests.log:19 tests,0failures.
- Initial source-lock compile run:7 existing tests pass.
All logs under /private/tmp/darkbloom-sandbox-completion-evidence.
The previous legacy SSH-wrapper under-load timing failures remain unresolved;
this idle pass does not claim they are fixed. CI34822858087 and integration
34822857983 now pass the preceding pushed2812390a5.

Real-root experiment on authorized test Mac100.104.151.128:
- External test-only RootImageMaintenanceProbe.swift is linked against the exact
  current debug objects with package-name sandbox_macos. It is not shipped and
  does not create a bootable/qualified image. SourceSHA
  11d4ac2c3c2abd981f6d09b02aaa94b18ba2996a8b88ca79ebfad80696d114b0;
  executableSHA f282ffe7d775a51bede32f08d7558ee4ec30173e04d7d48911af5d81710e552e.
- Bounded root operator run-root-image-maintenance-probe.py SHA
  868dc6d4824c583d1f9b149e5f483f82c7ae8bf74eb1dc8a3ae86fa3cf8631e7.
- Protected remote fixture /private/tmp/darkbloom-root-maintenance-20260914-0854,
  with root700 journal, root500 verified probe copy, selected501:20 source tree.
  The source is a deliberately invalid {} config plus100GiB sparse nonbootable
  image; its fake restore/payload metadata is fixture data, NOT installation proof.
- begin-crash performs bounded fixture IO after both fences then _exit(86).
  Ordinary EX admission rejects pending maintenance. recover-completion-crash
  resumes exact ownership, persists completion then _exit(86). Admission still
  rejects. recover-finish refuses further image IO, removes image then global
  marker, and exits0. A new process proves ordinary EX and SH acquisition works.
- Root hdiutil/lsof/process inventories before/after every phase show no image
  attachment, no foreign image openers, no authority holders after process exit,
  and no running lume/sandboxd. Permanent inode stays dev16777229/inode29088927,
  root:431/660/single-link/zero bytes. Temporary global inode30658507 and image
  inode30658509 persisted unchanged through both crashes and are now absent.
- Root evidence remote journal sibling operator-evidence.json; captured primary
  root-image-maintenance-physical.json SHA
  6198abfa329120bfe3ad260721aac726406e1e86d0664b744aa10d5f2777e23b
  (primary serialization includes a trailing newline). All primary probe/evidence
  files are in the evidence directory above. Remote incoming copies are at
  /private/tmp/darkbloom-root-maintenance-incoming-20260914.
- First fixture -0850 was correctly rejected before fence publication: macOS
  inherited wheel GID0 from /private/tmp while the selected-user binding required
  GID20. Fixed the test preparer to set each directory's UID/GID before creating
  children, with no production weakening. The old root-protected -0850 evidence
  and tiny sparse fixture remain; no fence was ever created there.
- Both disposable fixtures remain stopped/nonbootable, no mounts or root process
  remain. No CI/group/service/model/cache/production mutation occurred; only this
  authorized test fixture and transient maintenance markers were created.
- Latest disk inventory had54931396KiB free on the test volume (~52.4GiB).
  Go-cache deletion approval is still unanswered; do not infer approval.

NEXT: build the actual guarded attach/Data-volume selection/mount/detach operator
using this typed transaction. It needs durable attachment and cleanup observations,
bounded async cancellation, recovery of an attached image, exact no-openers and
native-stopped checks, and no arbitrary pre-mounted path supplied through the CLI.
The current withOfflineImage callback is synchronous; extend it deliberately for
bounded async process IO with an in-use guard before the mount orchestration.
Then selected GUI installer boot, its separate phase journal, receipt collection
and temporary-payload removal, installed checkpoint, qualification clone/coldboot/
teardown and ready-template publication. A completed staging journal cannot be
reused for post-boot collection; bind that separate maintenance phase explicitly.
Also handle a crash after both fences are removed using the protected completion
snapshot under a freshly acquired ordinary EX; do not reopen staging or fabricate
cleanup. The final ready publication must validate RELEASED lease cleanup after
clone teardown rather than calling the ACTIVE qualification capability validator.
Physical two-VM/system tests, build tools, performance, actual GUI login/logout
service recovery, signed runtime12 physical validation and release gates remain.


Typed root maintenance source and its tests/documentation committed and pushed
b1743dd53fb89204badfad238fa61c0148ac4ad3. Pre-push checks pass; docs-check passes
286files. PR996 remains draft and its Before/After body includes this implementation
and real-root proof. CI34825232114 and integration34825232144 are in progress
atb1743dd53; benchmark34825232097 awaits separate environment approval, not granted.
The next checkpoint commit is local-only; source is already pushed. No live root
probe, new VM, image attachment or transient maintenance fence remains. The old
CI-service pause and temporary runtime-group membership remain as documented;
Go-cache approval remains pending. Continue with actual guarded Data mounting,
then phase-specific GUI installer boot/collection and final qualification.


## Async root use, inherited children and APFS bindings (2026-09-14)

Root scope refactored into LumeRootImageMaintenance.swift. Its synchronous and
async withOfflineImage operations share LumeMaintenanceUseGate; completion and
overlapping/reentrant work reject while an image callback is active. The gate
also limits startOwnedProcess to an active IO callback. The child inherits the
same machine EX open-file description synchronously at spawn through the existing
HostRuntimeLease.withInheritedDescriptor/ProcessRunner start API. Source/native
locks and both fences stay retained across async work. Completion stays closed
after it starts. LumeImageMaintenanceCleanup is now Sendable. The staging facade
mirrors async access and owned child start; callers must await child termination
and independently observe cleanup before finishing.

New focused daemon files: AccountlessDiskIdentifier (bounded parsed BSD names),
AccountlessDiskPlist (bounded plist/typed bool/UUID extraction),
AccountlessAPFSVolumeBinding (exact GUID whole/main partition/sole physical store/
container/Data role graph and mounted readback), AccountlessDiskTools (bounded
read-only diskutil query chain, optional owned-child executor inside staging).
The client is serial and intentionally not Sendable when it captures an operation.
It neither attaches nor mounts and does not confer image-to-whole-disk authority.
That missing association belongs to the guarded hdiutil inventory workflow.
Mounted checks require exact DeviceNode/DeviceIdentifier/APFSContainerReference/
VolumeUUID/FilesystemType/MountPoint/GlobalPermissionsEnabled/Writable. A live
read-only diskutil info of the existing encrypted test volume confirmed all
fields and bool/string types (disk3s7/container disk3, existing volume UUID).
That read is schema evidence, not a successful guest Data-volume selection.

Validation in /private/tmp/darkbloom-sandbox-completion-evidence:
- disk-binding-tool-tests.log and disk-binding-owned-tool-tests.log:20 tests pass
  (APFS7, disk-tool3, use-gate1, existing image-maintenance9).
- disk-binding-full-tests.log:576tests/7skips/0failures,121.617s after refactor.
- An initial use-gate XCTest closure inferred throws inside DispatchQueue.async;
  replaced its assertion autoclosure with explicit do/catch before passing runs.
- Native pin and signed artifacts remain unchanged; final runtime12 still needs
  actual VM/installation physical validation. Earlier legacy SSH-wrapper stress
  concern remains unresolved; the idle pass does not close that issue.

A new external test-only root probe compiled against current RuntimeLume debug
objects. It does not link or physically validate the daemon disk-tool client.
Primary directory: evidence/root-image-maintenance-v2.
- RootImageMaintenanceProbe.swift SHA
  e405b452b5e12d68f5829cdfb0070038948ab170180c452df0ec6956d5a86a96.
- RootImageMaintenanceProbeV2 executable SHA
  6468846f46558b9663672885745eb691955967c07786e71555c5b995e5527e52.
- run-root-image-maintenance-probe.py SHA
  2db0cb0f97996c7c40e6b0d3e52691a1a607b6ac473c88eb6df795487b011fd8.
- Captured physical-evidence.json SHA
  3eb0bfddb035b2879d3fdac052d9a65aad6b10ca96eb9a51e054924ebfe53ccf.
- Remote protected fixture /private/tmp/darkbloom-root-maintenance-20260914-0920
  retains its request/completion and operator-evidence.json. Remote incoming
  binary RootImageMaintenanceProbeV2 and helper run-root-image-maintenance-probe-v2.py
  are under /private/tmp/darkbloom-root-maintenance-incoming-20260914. Previous
  primary v1 probe/evidence files remain unchanged. A compile-only probe error
  about definite initialization after a Never-returning async callback was fixed
  by an explicit unreachable-error branch; no production code weakening.

The live probe enters an async image callback, spawns /bin/sleep5 through the
owned-process API, proves reentrant completion rejects, and _exit(86)s. Root lsof
then observes only childPID86429 (csleep, fd4) on the permanent authority; exact
root recovery rejects with occupied while that child lives. The bounded operator
waits for this known holder to exit, then ordinary admission still rejects the
durable maintenance marker. A second root process persists completion and exits86;
exact recovery refuses new IO and releases both fences. Fresh ordinary EX and SH
acquisition pass. Permanent dev16777229/inode29088927 stays root:431/660, one link,
zero bytes. Transient machine inode30658877 and image inode30658879 are now absent.
No image attachment, VM, sandboxd, foreign image opener or authority holder
remains; this was a tiny sparse nonbootable fixture, not a guest installation.
No service/group/model/cache/production change occurred. Go-cache approval is
still unanswered. b1743dd53 CI34825232114 now passes; integration34825232144 was
still running at the last read. Benchmark approval remains separate and absent.

NEXT: wire the real attach/mount/detach controller, not more unrelated scaffolding.
Reuse the inspected older physical helpers as evidence only:
/private/tmp/darkbloom-physical-acceptance/gui-offline-inspection-v1/offline_mount_support.py
and accountless-offline-v3.py. Attach -nomount/-nobrowse/-noautoopen/-owners on,
select Data through the new typed graph, mount only the root-private empty
mountpoint with owners/nosuid/nodev/noexec, verify diskutil+fstatfs readback, stage,
close all Data descriptors, detach exact whole disk, and reobserve absence/openers.
Preserve preexisting Apple Metal attachment and bind device nodes to this exact
image every time; never guess disk IDs or detach based only on a saved /dev name.
Persist attach intent/baseline before spawn, support interruption before attach
output is recorded, and retain fences whenever pending helper IO/cleanup cannot
be proven complete. Do not equate killing hdiutil with no pending DiskImages IO;
owned child lifetime is now protected, but its terminal state alone is not detach
proof. The native status reader reports unknown while root owns the config/POSIX
locks: LumeController.getDetails uses RunLockProbe; do not accept unknown as
stopped or remove locks casually. A strict stopped observation before source
locking plus retained native exclusion and exact no-foreign-openers checks must
be deliberately integrated; final qualification still needs fresh native stopped
proof. Lsof exclusion must be only our exact PID+retained image fd, not all root
processes or all fds in the current process. The completed staging phase, post-boot
collection phase and final released-lease qualification need distinct journals.


Async ownership/APFS source653074530af527b11f4c3637b83ad016b3beb0a3 is committed
and pushed; all pre-push checks pass (disk-binding-push.log). PR996 remains draft
and documents both the new owned-child proof and the still-unbuilt attachment
workflow. CI34825232114 and integration34825232144 both passedb1743dd53.
FreshCI34827518025 is queued, integration34827517978 is running653074530;
benchmark34827518043 waits for separate approval, not granted. This checkpoint
update is local-only. No live root probe, sleep child, new VM or image attachment
remains; maintenance markers were removed only by exact recovery. Continue with
actual attach/mount/detach and its durable intent/recovery path. The existing
Go-cache approval question remains unanswered; no cache deletion occurred.


## Guarded offline staging and real APFS recovery (2026-09-14)

AccountlessStagingMaintenance.begin/recover now require LumeRootNativeInspector.
It verifies the production runtime pin/signatures, binds the same namespace and
UID/GID, rejects provisioning/resize markers before native inspection, runs
--version and get --format json as the selected owner via root sudo -n/env -i,
and accepts only exact stopped macOS metadata/resources. It runs BEFORE source
config/POSIX locks, because native status becomes unknown while root owns them.
The underlying native status path is read-only for this guarded marker-free
source (no VM object instantiation). It is not guest boot proof.

stagePayload now connects source ownership to the actual filesystem workflow:
- AccountlessAttachmentInventory parses bounded hdiutil records with exact image
  path/system-alias matching, owner/write policy, unique devices and mountpoints.
- AccountlessAttachmentSnapshot preserves metadata identities of preexisting
  images, devices and mounts. Added unrelated attachments are permitted, but
  original identities cannot be replaced or reused.
- AccountlessImageOpeners exempts only the exact current PID + retained image fd.
  Empty/inconclusive lsof, other root processes, another fd or mappings fail.
- AccountlessMountAttempts/Attempt maintain a bounded16-attempt closed prefix,
  intent before attach, attached and selected records before mount, and completion
  only after detach/no-openers. Both intent and completion carry attemptName, so
  equal image/plan state cannot replay a prior completion into a later attempt.
  An interrupted directory-creation prefix can close without authorizing IO.
  Only a managed UUID-named empty600/no-xattr temporary publication inode can be
  scavenged; nonempty/linked/shared/special entries remain unmodified and fail.
- AccountlessMountSystemTools launches fixed system-tool paths through a trusted
  owner, attaches -nomount, selects the exact whole/physical/container/Data graph,
  mounts only the journal's root-private Data path with owners/nosuid/nodev/noexec/
  nobrowse, and detaches only devices resolved from the current exact image.
- AccountlessMountedDataVolume checks root ownership, no ACL, APFS/from-device/
  mountpoint and all mount flags through fstatfs around synchronous payload IO.
- AccountlessOfflineStager replays incomplete cleanup first, records attach intent
  before any attach, checks attach output against current inventory, stages the
  signed overlay, closes Data descriptors, detaches and independently verifies
  absence/openers/source identity. Pending system clients prevent cleanup overlap.
  Staging failure may leave the maintenance intent pending even after detach;
  retry resumes under ownership. The parent staging journal will not finalize
  with an unfinished mount attempt.

Important process-lifetime integration: ordinary ProcessExecution reaps and kills
remaining descendants after foreground exit. That remains the default for
sandbox work. The narrow root-only SandboxProcessRunner.startSystemTool whitelist
uses terminateDescendantsOnExit=false for disk utilities. The same-binary
__owned-system-command worker retainsRootMaintenanceDescriptor against the exact
system intent, validates the system lease, closes inheritedfd4, and holds only a
CLOEXEC duplicate through its vendor child's natural exit. Thus platform helpers
may survive without accidentally retaining machine EX. The worker code is the
current immutable root-owned executable, never argv[0] or a mutable checkout.
AccountlessSystemCommandWait observes independently of caller cancellation and
retains a timed-out managed wrapper until natural exit; it never kills a mutating
client just to report cleanup. RootImageMaintenance now tracks owned children and
rejects new image scopes, overlapping children or completion while one is live.
Existing generic process-group cleanup and provider coordination stay intact.

Physical testing found two production defects and fixed them with regressions:
1. PayloadFiles.relativePath rejected a valid /private/tmp spelling after the
   first signed file because Foundation standardization shortens that alias.
   It now validates relative components under the already-bound root and still
   refuses traversal. The new test initially expected the unstripped data-overlay
   prefix, contrary to inventory's contract; that test expectation was corrected.
2. hdiutil attach maps Apple_APFS to a readable label while info returns the GUID.
   Parsing now prefers unmapped-content-hint when present, preserving strict
   comparisons rather than rejecting equivalent entities. Trace logs prove the
   exact difference. Invalid canonical hint types still fail closed.

Validation logs in /private/tmp/darkbloom-sandbox-completion-evidence:
- mount-final-full-tests.log:602tests/7skips/0failures,127.058s.
- mount-inherited-host-tests.log:21tests/0failures.
- mount-provider-build.log:darkbloom target builds,19.97s.
- mount-components-tests.log:17new component tests pass (inventory5 before new
  hint test, mount journal6 before new replay test, natural wait2, native status2,
  trusted process policy2). The policy test uses a FIFO barrier to prove the
  default kills a background child and the system policy preserves it.
- mount-controller-tests.log:5 tests pass, including durable intent before attach,
  failed attach cleanup, no cleanup while a client remains pending, recovery of
  that closed attempt before new attach, and exact whole-device resolution.
- mount-payload-alias-tests.log:16 tests pass; mount-hint-normalization-tests.log
  includes the real mapped-hint regression. Earlier full598 run also passed.
- CI34827518025 and integration34827517978 passed preceding653074530. New source
  needs its own CI. Legacy SSH-wrapper stress timing concerns remain open.

Native runtime12 was transferred with ditto ZIP preserving signing xattrs and
installed root-owned/immutable at:
 /Library/Application Support/Darkbloom/qualification-runtime12
ExecutableSHA3afc5eb6e291718920a83e881c97e90f4c78866bc49ca66cc011e7f35d86bfad;
provenanceSHAaa973a866ae5e89e6f02caa448d142ee98c7039b16f6ba2b7a5a81649361b4ba.
Exact Developer ID signatures were rechecked. ZIP primary evidence path
lume-runtime12-mount-test.zip SHA238281344251f0e3c4482a3c5ec625cbe4a9fcac0076605237d59e7536474655.
This is its first physical native status/staging use, NOT a VM-lifecycle test.
The guest fixture reuses signed qualification-release6 guest files, deliberately
without claiming the diagnostic244009eca guest or final guest qualification.

FINAL component campaign:
- Primary directory evidence/mount-root-probe/final.
- Remote fixture /private/tmp/darkbloom-apfs-stage-20260914-v2, root-owned755
  parent; vms/base stays501:20/700; operation/ is root-private700; mount-probe
  executable is root:0/500. Native status runs as501 and needs traversable parents.
- 1GiB flat UDTO APFS image created fresh; only its sole volume got Data role and
  empty root-owned Library parents. This emulates filesystem ownership at1GiB,
  BELOW the normal100GiB VM policy. Fake macOS config and nonbootable NVRAM have
  no hardware identity. Marker/candidate are fixture metadata, never a real
  Apple restore, tenant allocation, installation receipt or readiness claim.
- Seed/operator path /private/tmp/darkbloom-apfs-seed-operator-20260914-v2.
- DataUUID1DEF796A-C0D8-48D9-A6E1-924F25E9A255; transient whole disk6,
  physical disk6s1, container disk7, Data disk7s1. Never reuse these IDs without
  resolving a current owned attachment.
- ProbeSHA ccb281de303a96416020493806780a74790452215470442f3006f62e2e8a41ab.
  SourceSHA3a5a9f8197082e875e1bbcbf0e23196b68c42632f28f08833154577e2500da03.
  Probe links actual debug objects from RuntimeLume AND daemon modules. Its
  nonisolated run function matches CLI execution; the first inline-main version
  correctly failed Swift's actor-transfer checks, so no Sendable bypass was used.
- Final seed scriptSHAa88fbd3eac13f3ecca8c81cd28e13c240e157cbc58d0765c5e578b25623ee2de;
  run-final-campaign.py SHAb06e3ea4481c17b71ea66674539d2650a3f51a9b04290d2eb46f7a9a8d3f1f60;
  verify-final.py SHA96d54f92c12d0de5a67d391503956b462a4a0892c8ed429aa1069d3f7b3dc559.
- Probe confirms parent+worker own EX, vendor lsof does NOT inherit it. A deliberate
  _exit(86) occurs AFTER successful attach but BEFORE attached.json publication.
  The image remains attached, both fences persist and ordinary admission fails.
  A new root process recovers the same intent, resolves/detaches the image,
  closes0001, performs full Data mount/signed overlay/detach in0002, and clears
  both fences. Native stopped metadata and ordinary EX/SH admission then pass.
- Independent root verification proves zero fixture attachments/openers/authority
  holders, exact completion-to-intent/attempt binding and final image snapshot,
  original Apple Metal attachment and permanent dev16777229/inode29088927 unchanged.
  Final staging-detachedSHA ecdc0a28908db9feccbdf17671efbc27302daa363101524a45c1ebd262a8037c.
- Primary final/campaign.json SHA70d693fe1f5a86c6278a484666c20d31b3475818777fe331a92c2ad2dbcaf50a;
  final/verified.json SHA9c5ffebb5a34b52e65662d5b22a99c2a39aaad50075f4ef6f95381935559f29c.
  Remote staging-campaign.json and staging-verified.json retain full results.

Earlier first fixture /private/tmp/darkbloom-apfs-stage-20260914 is also fully
detached/unfenced. It exposed the payload-parent fixture mistake, then the two
production bugs above. Its four attempts finished and verify passed, using the
older pre-attemptName journal format; preserve it as historical evidence and do
not load it with the final journal decoder. Primary v1 verified evidence is
mount-root-probe/staging-verified-v1.json. DataUUID3EEF31D2-99A5-4758-8481-95031792BE85;
probeSHA29b37baace4c00e7d627fbf0e93a4e0e82e38a33ba2f79c78340de8dae97c5c6.
Its operation/payload-before-path-fix and old probe binaries are retained. All
fixture payloads are public signed code, not customer data or host credentials.
An accidental copy of two probe artifacts into the old incoming-20260913 folder
was removed only after exact hashes/ownership/link checks; other contents stayed.

No VM was booted, no CI/group/model/cache setting changed, and no production action
occurred. Go-cache approval remains pending. Existing CI pause and temporary
runtime-group membership remain until the larger physical campaign completes.
The original exercise14/coldboot15 remains the last actual guest VM proof.

NEXT: expose the accountless workflow through a clear operator command and wire
selected-GUI installer boot with its own durable phase journal, then receipt
collection/removal, installed checkpoint and qualification/coldboot/teardown/
ready-template publication. The old prepare-base command still uses unattended
SSH; no public accountless CLI is wired yet. Stage payloads need a root-private
parent while selected-owner source storage needs traversable root ancestors.
Handle finalization after BOTH fences were already removed using the protected
completion snapshot and a fresh ordinary EX, never reopening staging. Define an
explicit abort/discard path for a failed but detached stage rather than silently
clearing a partially staged candidate. Post-boot collection must not reuse the
staging journal (it closes on boot intent). Final ready publication after clone
teardown must verify durable RELEASED-lease cleanup, not the ACTIVE capability.
Then full real-host enrollment/two-VM consumer campaign, build tools/performance,
actual GUI logout/login service lifecycle, final signed bundle and release gates.


## Accountless operator phases and completed staging replay (2026-09-14)

Pushed ce33b36ea0db927881be82acc9475c9cc8fb6a4c completes the guarded Data
attach/stage/detach implementation described above. All pre-push checks passed;
PR996 is updated with the actual mounted-image result and still remains draft.

The new public prepare-accountless-base command now has reserve, payload and
stage phases. All require --storage, --name, --host-id and --host-identity-file.
- reserve additionally takes --lume, --ipsw, --guest-release and optional CPU/
  memory. It enforces the selected real/effective user, actual GUI/audit session,
  eligible host, encrypted APFS and machine EX; it monitors session loss through
  managed raw Apple restoration. No unattended login account preset is used.
  Output is awaitingRootInstallation, with installed/qualified both false.
- payload runs as root, validates the selected identity and existing immutable
  source reservation, and materializes the verified release into --output NEW_DIR.
  It does no disk attachment. Partial materialization remains for inspection;
  a new output directory is required for another materialization attempt.
- stage runs as root with --lume, --payload and --journal-dir. It validates the
  trusted installed worker before publishing maintenance, encrypted storage,
  exact protected plan and journal. A matching unfinished maintenance intent is
  recovered automatically; foreign intent, changed source or unsafe files fail.
  The signed current overlay and detached source are required before payloadStaged.
  No command exposes a development signature bypass or claims installed/qualified.

A completed journal is now handled after BOTH fences have disappeared.
LumeRootBaseImageGuard.verifyCompletedMaintenance acquires fresh ordinary system
EX, takes the same native/source locks under the original reservation identity,
requires no image fence, and validates LumeCompletedImageMaintenance against the
original directory/intent hash and exact final disk snapshot before/after caller
observations. AccountlessStagingMaintenance.verifyCompleted additionally checks
native stopped state, no target attachment and only its exact retained image fd.
It grants no IO and publishes no fence. If global removal was interrupted, the
command recovers the original completion then independently verifies this path.
This closes the prior unsafe gap where an idempotent caller might try to begin
staging again after successful cleanup.

New validation:
- accountless-operator-tests.log:102 existing affected tests passed.
- accountless-operator-new-tests.log:8 new tests passed, covering raw-only source,
  fixed boot-disk policy, phase/privilege option boundaries, unsafe paths, root
  refusal before path reads, false readiness fields, exact completion intent,
  rejection while fenced and rejection of post-completion disk changes.
- accountless-operator-full-tests.log:610tests,7skips,0failures,124.624s.
- accountless-operator-final-tests.log:610tests,7skips,0failures,128.390s after
  worker-install preflight before maintenance. All processes exited successfully.
- accountless-operator-cli-smoke.json:3 real executable checks pass: help route,
  nonroot rejection before input paths, and denied development bypass flag.
- accountless-operator-docs.log:docs-check286files passed.

Real-root completed proof also PASSED on the test Mac against the existing final
nonbootable1GiB fixture, without mounting or changing it. It runs the actual new
reservation reader, protected plan reader and verifyCompleted twice, then checks
ordinary EX and SH admission. A separate Python owner compares image metadata,
all journal file metadata and digests, authority identity and hdiutil attachments
before/after; all match. Both fences are absent, no image opener or authority
holder remains, and inode29088927 is unchanged. No VM boot or template readiness
is claimed; this does not exercise the full CLI's encrypted-volume/GUI creation.

Primary evidence directory:
 /private/tmp/darkbloom-sandbox-completion-evidence/accountless-completed-proof
- CompletedRootProbe.swift SHA3b08f59d01bc10183d8c07d1efa12ba0b52570283ce5df913bc88731c9a081f3
- CompletedRootProbe SHA477f4bcca2c748eb34a17935acbc3335206795f2cc917a634ae89a0a5edef991
- run.py SHA5f146b57b08217baf6986bb7fc7bf49255ca47dc3d8b2184175a4589c1446f40
- verified.json SHAbe364647c13d90c32513b8c1c652cc5134508f3b37df200ccde1950ac87e5e91
- build.py links current debug objects; the later CLI-only worker preflight is
  not part of that probe binary and does not change the exercised proof methods.
Remote incoming directory:
 /private/tmp/darkbloom-completed-proof-incoming-20260914
Remote root-private installed probe/logs/verified.json:
 /private/tmp/darkbloom-completed-proof-root-20260914
All probe processes exited. The original final staging fixture and proof remain
unchanged. Latest remote disk free observation is50GiB; no cache/model/service/
group/production mutation was made. Go-cache approval is still unanswered.

Next implementation must build the distinct one-use boot journal and selected
GUI installer lifecycle, then root post-boot receipt collection/removal and
installed checkpoint publication. Generic runtime.start currently waits for
legacy SSH readiness when no isolated guest material exists; do NOT use it for
first-boot installation, and do NOT enable legacy shared folders/network as a
shortcut. Use a bounded native offline run that retains machine EX in the actual
VM owner, records boot intent before spawn, waits for guest shutdown and proves
stop on cancellation/session loss. A replay must observe/collect that one attempt,
never silently boot the installer again. Then qualification clone, released-lease
cleanup proof and readiness publication; full real two-VM acceptance and release.


Operator sourcebb58af5ecb106c5f1cfa845788001fc2d87c4398 is committed and pushed.
All pre-push checks pass (accountless-operator-push.log); PR996 remains draft and
its Before/After description includes the operator phases and completed replay.
CI34838853984 and integration34838853908 are now running; benchmark34838853878
awaits separate environment approval. No local shell/test/probe session is live.
This checkpoint-only commit follows the pushed code.

Next boot-path audit found a concrete native prerequisite. Current pinned
DarkbloomDevicePolicy.isolated-v1 REQUIRES both .darkbloom-guest/control.cdr and
workspace.cdr. Source installation/collection guards deliberately forbid
.darkbloom-guest material on a raw candidate, so the tenant profile cannot simply
be reused or faked for installer boot. The ordinary base start also waits for
legacy SSH and does not inherit machine EX. Implement a narrow managed offline
installer device profile (boot disk only, no IP/peripherals/shares/guest bridge)
with the same actual-owner machine EX and broker lifecycle requirements. Update
Run validation, device application and DarkbloomRuntimeAuthority retention while
preserving existing isolated-v1 behavior. Keep bridge creation tenant-only.
Native reference files are in the editable tree:
 /private/tmp/darkbloom-managed-restore-native/work/libs/lume/src/Virtualization/DarkbloomDevicePolicy.swift
 /private/tmp/darkbloom-managed-restore-native/work/libs/lume/src/Commands/Run.swift
 /private/tmp/darkbloom-managed-restore-native/work/libs/lume/src/VM/DarkbloomRuntimeAuthority.swift
Existing patches1..12 and their pins are unchanged. A new profile must become a
new pinned patch and signed native build with its own tests; no unknown-profile
fallback or legacy networking shortcut. Then implement the GUI one-use boot
permit/journal, lifecycle and separate root collection transaction described above.


## Managed offline installer profile (2026-09-14)

Native prerequisite is implemented in patch13:
 ThirdParty/lume-patches/0013-add-managed-offline-installer-profile.patch
 SHA25d839d4c6b94e9c3e22a3526d65acada10939a4822dedc2fd04287004a27ee8.
The JSON lock, Swift constants, contract test and required native selectors move
together. Existing patches1..12 are byte-unchanged. Delta generation uses the
already-patched12 files in an isolated small git repository at
/private/tmp/darkbloom-installer-profile-20260914/patch-source, so prior native
uncommitted patches9..12 were not reset, re-synthesized or accidentally folded in.
The normal production builder replays all13 patches from upstream737dc2a069528abadee67526d138a907e1c52061.

DarkbloomDevicePolicy now selects known isolated-v1 or installer-v1 profiles;
unknown profiles still fail. Both require broker lifecycle, foreground ownership,
no display/VNC, no clipboard/recovery/shared directories/USB/network override.
Installer mode permits no control/workspace disk and rejects disk/NVRAM overrides
in both Run and LumeController. Storage must be the owned private0600 single-link
regular disk.img under a private source directory, with positive512-aligned size.
Only macOS is accepted. Device application verifies the one writable block
attachment and removes IP network, audio, console, serial, directory shares,
keyboards, pointing devices, USB controllers and Virtio sockets. Existing tenant
mode retains exactly three disks and its guest bridge. Serial-log path creation
is disabled for both managed profiles. VM.run now retains machine EX for either
managed profile; actual-owner lifetime retention/BLC shutdown are unchanged.

Focused native20tests pass. Fresh normal signed builder passes205tests plus19
mandatory selectors, including three new installer selectors. Five new native
tests cover exact devices,12 invocation violations and valid invocation controls,
read-only/missing/extra block devices, unsafe modes/hardlinks/extra media, macOS,
profile/authority selection, no guest bridge and legacy/tenant preservation.
No physical VM boot, root-job result or qualification is inferred from these tests.

Final artifacts:
- Primary work/evidence:/private/tmp/darkbloom-installer-profile-20260914
- Signed runtime:/private/tmp/darkbloom-sandbox-lab-20260913/runtime/lume-installer-profile-13
- executableSHA53ec2a7073c67c5f0bc712ba1a3d59e0205edfd5c91fb8e156208c430e0389e4
- provenanceSHA7a67269640df0daa6643e016584ccad721556b319ddfcfab3d29192165958f03
- runtime13.zip SHA84c32d06212c82482f7ad8b54e686bc799e3788a9b91c105aa02d40b5f8c5441
- install-runtime13.py SHA532bcfc72dc8b3be7729e580610702987fb89eabb2292686bd0c1a5a486e3300
- native-focused-tests.log:20pass
- signed-runtime-build.log:205pass,19required; normal release compile69.30s;
  exact Developer ID executable and provenance verified independently afterward.
- sandbox-full-tests.log:610tests/7skips/0failures,128.057s. Ran after native build
  completed to avoid the earlier concurrent-compilation timing interference.
- real-binary-contract.log:2pass against this exact signed binary, empty-storage
  capabilities/list plus clean JSON under legacy-inconclusive session.
- docs-check.log:286files pass.

Runtime13 was transferred via ditto ZIP preserving signature xattrs, installed
with RENAME_EXCL beneath the existing root-owned application directory, and
rechecked against the signed full file/directory inventory. Root owns all entries;
folders/executable0555 and data0444. Developer ID executable/provenance requirements
and version0.5.3 pass independently on the test Mac.
Installed:/Library/Application Support/Darkbloom/qualification-runtime13
Root proof/archive:/private/tmp/darkbloom-runtime13-root-20260914/installed.json
Incoming:/private/tmp/darkbloom-runtime13-incoming-20260914
Primary captured result:runtime13-installed.json in the profile evidence directory.
No prior runtime was removed, no service/config/group/cache change occurred, and
no VM was started. Last actual guest execution remains exercise14/coldboot15 with
runtime8; native status/APFS staging/completion proof used runtime12. Runtime13
physical installer-profile boot is still a required gate.

CI34837780288 and integration34837780295 now passce33b36ea. Operator-source
CI34838853984/integration34838853908 are still running at the last observation.
The new profile needs its own commit/push/CI. PR996 remains draft.

NEXT: implement the one-use boot permit/journal and GUI owner against installer-v1,
then a distinct root post-boot collection/removal transaction. Do not route through
legacy runtime.start (it waits for SSH) or attach tenant control/workspace disks.
Guest first-boot.zsh already uses exclusive result-directory creation to refuse
installer reruns and shuts down after a complete receipt. A guest-side refusal
alone is not a host boot-intent journal: persist the attempt before VM spawn and
never silently rerun it after uncertain startup. Root-private staging intent
must close before the GUI owner can run; recovery after that boundary must read
its own boot journal rather than reopen AccountlessInstallationStagingJournal.
The selected GUI process must verify the root-owned permit and exact staged
snapshot under machine EX, bind real/effective/audit/session identity, preserve
native/BLC stop cleanup, and retain capacity on uncertain outcomes. Final root
collection must validate exact guest receipts before installed-checkpoint output;
qualification still requires released-lease cleanup before ready publication.


Profile sourcee518872e7954030e3e17d36de55dde4c11aefc6a is pushed; all pre-push
checks passed (profile evidence/push.log). PR996 remains draft and now includes
installer-v1 in its After diagram and explicit physical/one-use orchestration
limits. New CI34839970219 is queued, integration34839970313 is running, and
benchmark34839970265 awaits separate environment approval. Operator-source
CI34838853984/integration34838853908 were still running at the last observation.
No local build/test/SSH session remains live. This checkpoint-only commit follows
the pushed code. Continue implementation of the boot journal/GUI owner; do not
restart native builds or the completed staging campaigns without a new reason.


## One-use installer handoff and GUI owner (2026-09-14)

Code in058cb5557 implements:
- AccountlessPrivateJournal extracts the existing staging lock/read/immutable
  publication IO. AccountlessInstallationStagingJournal retains its strict
  boot-marker refusal. A separate AccountlessStagingTransition shares staging.lock
  but exposes only completed snapshot reads and irreversible handoff publication;
  it cannot grant or reopen image IO. AccountlessStagingSnapshot binds canonical
  original intent/staged receipt, plan/candidate, maintenance and detached snapshot.
- AccountlessBootJournal persists separate root-private intent. AccountlessBootPermit
  binds selected host/user/identity file, raw reservation bytes, storage/native
  paths, exact native binary digest, final staged disk, snapshot digest and300s.
  Root publishes private boot intent, closes staging with the permit hash, then
  publishes the GUI-readable root-owned0444 permit. Matching interruptions can
  finish; conflicting records cannot overwrite. Existing permits replay without
  falsely rechecking the original pre-boot disk as though it were still current.
- AccountlessAuthorizeBootCommand is exposed as prepare-accountless-base
  authorize-boot with existing common identity/storage/name flags plus --lume,
  --payload, --journal-dir, --boot-journal-dir and --permit-file. Boot journal must
  differ from staging; the public permit's parent must already be root-protected
  and traversable. Native production pin/signature and source cleanup are checked
  before first public permission. Publishing data never claims a VM boot.
- AccountlessBootCommand is the selected-GUI boot phase with --permit-file and
  the same common identity/storage/name flags. It binds real/effective identity,
  actual GUI/audit context, encrypted storage, eligibility, system EX and the
  production native artifact named by the root permit.
- LumeVirtualMachineRuntime.runInstaller uses dedicated base runtime ownership,
  exact native SHA, template-then-broker locks, raw ownership/resources/reservation,
  and final staged snapshot before spawn. It publishes the immutable
  .darkbloom-installer-boot.json claim first, then launches installer-v1 with BLC
  and inherited EX, without SSH readiness or tenant/control/workspace media.
  Native exit is bounded by300s. Cancellation/failure waits for stop cleanup in a
  detached task; final source stopped proof is required. A fresh runtime replay
  can only stop/observe the matching claim, including a claim left before spawn.
  No error clears it. Different permits cannot reuse it.
- AccountlessBaseCandidateStore rejects any boot claim; ordinary base start
  (scope=nil) rejects it; pre-boot LumeBaseImageSourceLocks reject it. Do NOT add
  this refusal indiscriminately to LumeBaseCandidateOperationGuard: installed
  publication and qualification also use that guard and need the consumed source.
- AccountlessGUISession now drains both operation and monitor results, preserving
  an operation/cleanup error even when session loss arrived first. A simple
  throwing task group could hide that later cleanup error. Both reserve and boot
  use the shared supervisor. No unchecked Sendable shortcut was added; the native
  observation closure captures the immutable name instead of the source lock object.

Phase reports remain unqualified/unpublished. installerBootStopped proves native
exit0 and source stopped; installerAttemptRecovered proves stop for a previous
claim and has no original exit code. Neither proves guest installation success.
Root post-boot collection/removal is still required for installed publication.
No new Native patch:13 remains exact and unchanged.

Validation/evidence in /private/tmp/darkbloom-sandbox-completion-evidence:
- boot-journal-refactor-final-tests.log:21 affected tests pass after the actual
  refactor. An earlier Python edit used the wrong relative cwd and did not edit
  the file; boot-journal-refactor-tests.log predates the real refactor and is not
  its evidence. The correct edit used an absolute path.
- installer-boot-tests.log:5 subprocess lifecycle tests pass. They prove the
  claim exists before child execution, exact installer-v1/fd4/fd3/no-extra-media
  invocation, normal exit and fresh-runtime replay with one spawn, no SSH,
  pre-spawn consumed claim, cancellation stop, native failure, changed permit,
  changed disk/runtime denial, and legacy start/new staging refusal.
- installer-handoff-final-tests.log:44 affected tests pass, including transition
  closure, replay/conflict, interrupted private boot intent, incomplete/corrupt
  staging, bounded/canonical permit fields and ordinary-user denial. Initial
  test-only missing try annotations were fixed before this passing run.
- installer-handoff-full-tests.log:622tests/7skips/0failures,123.304s, before the
  real-root publication path fixes below.
- installer-handoff-final-full-tests.log:623tests/7skips/0failures,132.467s, after
  new-path validation. The publication-helper rebuild was queued behind this
  running SwiftPM session; this run does not cover the later helper change.
- installer-handoff-release-tests.log:623tests/7skips/0failures,129.802s after both
  publication fixes. installer-gui-session-final-tests.log:15pass including three
  new session/cleanup/error-ordering controls. The first helper compilation used
  a throwing body with nonthrowing withTaskGroup; it now returns Result and throws
  only after draining both tasks.
- installer-permit-path-final-test.log:the new-destination regression passes.
  The first regression compared /var and /private/var URLs literally; the corrected
  test compares actual parent device/inode and checks traversal/symlink denial.
- installer-handoff-final-validation.log:626tests/7skips/0failures,128.707s after
  GUI-session supervisor; all local test/build processes completed successfully.
- installer-handoff-cli-smoke.json:3 actual executable checks pass: five-phase
  help, nonroot authorization refusal and denial of a boot runtime override.
- installer-handoff-docs.log and installer-handoff-final-docs.log:286files pass.

Actual root filesystem proof found TWO real publication defects and fixed them:
1. canonicalPath(destination) uses realpath and requires existence. A new public
   permit therefore failed unsafeDestination before creating a file. creationPath
   now validates lexical components and canonicalizes the existing parent.
2. The general createUnlinkedPrivateFile helper requires a0700 parent. Public
   permits need a root-controlled, GUI-traversable directory. The publisher now
   creates an empty0600 O_EXCL/O_NOFOLLOW temp in that protected directory, checks
   it, unlinks it BEFORE writing bytes, then atomically publishes a0444 clone.
   The general journal helper and its private-parent invariant remain unchanged.
   Interrupted empty temp files are retained rather than treated as a permit.

The final root probe uses synthetic source/image metadata (device1/inode2, no
real source or host identity). It exercises publication/reader permissions only;
its permit cannot boot a real VM and is not production authorization/evidence.
It verifies root publication, exact0444/one-link metadata, matching replay's inode,
conflicting-data denial, hardlink denial and wrong-mode denial, with independent
Python root metadata/hash readback. NO VM boot or template qualification occurred.

Primary artifact directory:boot-permit-root-proof in the evidence root.
- BootPermitRootProbe.swift SHA9e385fc22ca57170caf90f04b5a8a3f4dad9a8f7a410b750cbe12157ded783ae
- Final probe SHA d445a46018955c44c89011f76b79d092cf3e700155e648bfdc6262d5e213c96b
- run-v3.py SHA c86090d3ffcb065659cf27696b7247144090054563565ab0624cd62082be4c9e
- verified.json SHA cc8fb6d70621b01385af6f0b1018810058267bee1f26f0cd09ce2bf031d2e13f
- permit data SHA06d6a0ed3874bbaebda49a2aed33c813c17b4cdb0082a064a55b0157cb47e7fd
- Initial probeSHA00739b7249034bbdb71941c7555861992dc6999a48f226b3b50251bbc5ca9285
  retained as BootPermitRootProbe.initial; parent-only probeSHA330370eb54edc4a900f73fbf16bbba160799d876a8024f9978ea209bbb558b17
  retained as BootPermitRootProbe.parent-only. All failed logs/artifacts retained.
- Final probe links actual debug objects for publication. The subsequent
  GUI-session supervisor change is not in that probe and does not change the
  exercised publication methods. Physical GUI/boot behavior is unverified.
Remote incoming:/private/tmp/darkbloom-boot-permit-incoming-20260914
Remote original/v2/v3 operator folders:/private/tmp/darkbloom-boot-permit-root-20260914[-v2|-v3]
Final root verified.json is in the -v3 folder. Public synthetic fixture:
 /Library/Application Support/Darkbloom/qualification-boot-permit-io1
It contains permit.json and intentionally wrong-mode.json; its temporary hardlink
was removed by the probe. Existing VM/APFS fixtures were untouched. No VM, cache,
model, service, group or production change occurred. Go-cache approval remains
unanswered; available test-Mac storage was last50GiB.

Current preceding e518872e7 has CI34839970219 and integration34839970313 PASS.
After final verification, commit/push this handoff implementation, update PR996
with the real-root limits and keep draft. Then implement separate post-boot root
collection/removal and connect installed checkpoint/qualification/released-lease
cleanup/readiness. The source lock for pre-boot staging now deliberately refuses
boot claims, so collection needs its own exact-claim scope and distinct durable
maintenance intent, not a bypass that reopens old staging. Full real Apple restore,
GUI boot, first-boot receipt, two-VM consumer acceptance, build tools, performance,
actual logout/login and final release qualification still remain.


Handoff source058cb555776ef9bad2565b9ae536eca1c8bf67f4 is committed and pushed.
All pre-push checks pass (installer-handoff-push.log). PR996 remains draft and
its After diagram now includes root authorization, GUI permit validation,
pre-spawn permanent claim, native installer and stop-only replay; collection is
still explicitly pending. CI34844573163 and integration34844573303 are running
this source; benchmark34844573610 awaits separate environment approval. No local
build/test/SSH process remains live. This checkpoint-only commit follows the
pushed implementation. Next is the separate post-boot root receipt-collection
and temporary guest-payload removal transaction, not another staging/boot replay.


## 2026-09-14 — Root installation collection and installed handoff

Implemented collect, abort-collection and publish-installed after one-use boot.
The root scope validates the exact consumed claim, captures the post-boot disk
under the existing locks and publishes a separate durable maintenance intent.
The shared AccountlessOfflineImageTransaction now serves staging and collection;
RootRecordFile serves both bounded root public handoffs. Entry points stay thin.

Collection verifies installed signed guest bytes/bootstrap/job/synthetic workspace
entry before accepting a complete bound result. It saves the result and logs to
the private journal before recording the exact removal plan. Receipts are16KiB
maximum; logs64KiB and may be empty. It removes the temporary boot job first and
never touches unlisted paths. Missing entries are accepted only after a removal
plan is durable; changed entries and unexpected files stop recovery. Host receipt
copies allow replay even after the guest receipt itself has been removed.

Review found an attachment-recovery issue: mounted st_dev is not a persistent
volume identity. The plan now binds the verified APFS Data UUID, while current
same-device descriptor IO stays enforced; persisted inode/size/timestamps/hash/
mode and directory ownership remain strict across device renumbering. Synthetic
regression models the prior attachment number and proves completion, with wrong
UUID and changed/replaced/linked-entry rejection controls.

Removal, attachment completion and detached image cleanup are separate records.
Abort settles owned attachments without mounting for Data IO and cannot create
installation evidence. Root final verification reacquires ordinary EX and binds
final snapshot/stopped/no-openers before public collection publication. GUI
publication rechecks production runtime SHA and exact permanent boot claim,
identity/session, storage, installed source evidence and guest release. Result
installedAwaitingQualification is installed:true,qualified:false. Qualification
must still verify a released lease before ready-template publication.

Validation (primary /private/tmp/darkbloom-sandbox-completion-evidence):
- collection-affected-tests.log:25pass before the final claim guard and remount fix.
- collection-publication-tests.log:13pass including runtime/claim denial before
  publication and a matching positive publication control.
- collection-recovery-tests.log:27pass including remount/wrong-volume controls.
- collection-full-tests.log:639tests,7skips,0failures,131.717s; actual process exited0.
- collection-cli-smoke.json:4pass actual binary help, both root-only commands
  denied before IO for nonroot, and runtime override refusal for publication.
- collection-docs-check.log:286filespass; git diff --check clean.

No new native patch/build, VM boot, root collection proof, model/cache deletion,
service/group/authority mutation or production change occurred in this segment.
Prior root public-file IO was physically tested before its behavior-preserving
extraction; physical collection with this new scope/receipt/removal path remains
unverified. Full pipeline and two-VM acceptance remain required.

Live SSH df confirmed50GiB available on the test Mac and encrypted test volume.
The reservation command uses SandboxHostInspector's default300GiB proof floor;
inspect actual volumeAvailableCapacityForImportantUsage before assuming cleanup
of old fixtures is sufficient. Do not lower safety/admission policy simply to fit
a test. Task-owned old VMs report91GiB allocated (possible clone double-count),
with metadata and stopped-state inventory from the preceding segment; no opener/
root authority/deletion proof exists yet. Keep the GUI diagnostic VM, encrypted
volume, permanent authority inode and restore IPSW. Go-cache deletion is still
unapproved. The already pushed handoff058cb5557 passes CI34844573163 and
integration34844573303. Keep PR996 draft and acquire fresh CI after this push.


## 2026-09-14 — Physical collection crash recovery and independent Data verification

Previous goal turn classification: progress (c58df40b6 implements/pushes collection).
This turn also makes progress: real root/native/APFS component evidence changes
collection from local-only to physically verified disk operations. Full fresh-VM
installation/qualification remains incomplete; keep goal active and PR996 draft.

No product source code changed in this physical campaign. The probe links the
actual c58df40b6 debug objects and uses signed root-installed runtime13 for native
metadata. It copies real Developer ID release6 guest files into a synthetic
filesystem fixture; it does not execute the guest installer or start a VM.
The dummy ownership/config/reservation and complete receipt are fixture data.
The protected public directory includes a NONBOOTABLE README and points to an
absent NOT_A_HOST_IDENTITY.json. No template/readiness receipt is created.

Initial fixture /private/tmp/darkbloom-apfs-collection-20260914 (public io1):
-1GiB flat APFS, prepared and signed overlay staged/detached successfully.
-authorize-fixture refused the normal disk/workspace policy before boot claim or
 collection. Both fences absent and no image attachment remained at failure.
-Preserved as failed fixture evidence; never modify product policy to accept it.
-The first probe build referenced a staging-only convenience method; corrected
 to use the actual owned system worker. A later local v2 build script initially
 pointed to the prior output directory; corrected before any v2 execution.

Successful fixture /private/tmp/darkbloom-apfs-collection-20260914-v2:
-public /Library/Application Support/Darkbloom/qualification-collection-io2.
-root parent/probe protected; vms/base owned501:20/700, disk600/one link.
-100GiB raw sparse image created with ftruncate, then its independently bound
 virtual disk partitioned as GPT/APFS. All device IDs resolved from the exact
 newly attached image, excluding baseline devices. No preexisting disk modified.
-Data UUID24E3AB8B-817E-4B2F-9746-62362BCA8E38; boot impossible (no OS/hardware,
 fake NVRAM). Allocated12,845,056bytes after campaign; test-Mac df49GiB free.
-seed operator /private/tmp/darkbloom-apfs-collection-seed-20260914-v2.
-probe prepared raw fixture records as501, staged asroot, closed staging and
 published synthetic root boot permit, then501published a synthetic consumed
 claim. These fixture steps prove contracts, not actual GUI/boot behavior.
-root claimed source scope captured the disk, persisted collection intent and
 both maintenance fences, attached/mounted exact Data, copied signed installed
 fixtures and wrote a synthetic complete receipt. Actual collector verified
 signature/files/result, saved logs/plan and unlinked temporary boot job.
-_exit(86) ran immediately after that unlink. The APFS image remained attached;
 global/image fences persisted. An ordinary admission probe failed as expected.
-new process AccountlessCollectionMaintenance.open recovered the exact intent;
 cleanup detached attempt0001, remounted in0002, used the saved result/removal
 plan, removed remaining temporary payload and verified installed bytes.
-final stopped/snapshot/no-openers checks passed, both fences cleared, bounded
 root public collection record written0444/one link. Two verify-completed
 replays left every operation file/digest/inode/timestamp and disk unchanged.
-Independent Python verifier held original machineEX, resolved the exact image
 and DataUUID, mounted read-only owners/noexec/nosuid/nodev/nobrowse, verified
 signed guest and three installed hashes, workspace synthetic entry, all13
 temporary files and four temporary directories absent, and unrelated sentinel
 preserved. It detached and confirmed unchanged image/journals, no image openers,
 no authority holders and identical preexisting Apple Metal attachment.
-Permanent authority dev16777229/inode29088927/root:431/mode660 remains unchanged.
-No cache/model/obsolete VM deletion, inference/service/group/fan/production
 mutation occurred. Go-cache approval remains unanswered. All probe processes
 completed; the fixture is detached and unfenced. Preserve diagnostics/keys.

Primary artifacts: /private/tmp/darkbloom-sandbox-completion-evidence/collection-root-proof/v2
-CollectionRootProbe SHA788db52f5dd3a78d40c08e58ec929ce6b0fbe7c29f6b6a7ac824060c1ff154aa
-CollectionRootProbe.swift SHAff4483c1f4234f40a21c64f94fe166ff7ad9f92ed543574eeb22104e7eda65bb
-run.py SHA9dc42e4269686fe1a93ec53a0dc5489bf02c6f33862a10cdb21d01e9e6711794
-seed.py SHA2c7d30a8a6b0f603c5e09155bbbab8cdca7d9fece466e02895323d7ab68c93d0
-verify-content.py SHA657d091582207ccb06ecb05898d741e415446271a2f9091f726647e70ebb1608
-evidence.json SHAe893daa05c89d2791bcd920d29dba3764f8240803affc53b4f703020007d1073
Collection public record SHA4cf4f769ec4eb93bfa39a8462ab6b53f202e77030d3b68e4a0eb3577c305152f.
Remote v2 fixture contains campaign.json,verified.json,independent-verified.json.
Export copied from /private/tmp/darkbloom-collection-incoming-20260914-v2/evidence.json
and parsed locally:10phase outcomes[0,0,0,0,86,1,0,0,0,0], both verifiers pass,
guestInstallerExecuted/vmBooted/templateQualified are all explicitlyfalse.

Sourcec58df40b6 CI34848597007: sandbox,coordinator,docs,lint,UI,release-integrity
jobs pass; Provider Tests still in_progress. Integration34848597005 in_progress.
Benchmark34848598921 waits on separate environment approval. Do not mark the
whole source CI passed until fresh final conclusions are observed.

Next implementation gate: connect installed checkpoint to durable native
qualification attempt, real clone lifecycle/checks/restart and final cleanup.
LumeQualificationCloneCapability currently retains source locks but its source
validation also authorizes an ACTIVE create lease. That validator cannot simply
be reused after deleteAndRelease: readiness must instead bind the exact released
deletion scope durably, clone installation/material identity captured before
removal, missing clone/material state, unchanged stopped source and passed native
checks. HostCapacityArbiter.deletionConfirmed and releasedDeletionScope provide
existing release receipts. Add no caller-supplied success bypass. Physical fresh
Apple restore/GUI boot/collection, actual logout/login, full two-VM coordinator
acceptance, build tools/performance and final packaging remain required.


## 2026-09-14 — Qualification identity and released-lease cleanup verifier

Previous goal turn: progress (physical APFS collection/crash/recovery evidence).
This turn: progress (new tested SDK cleanup-verification gate). The full image
factory/native qualification/consumer campaign is still incomplete; goal active.

Implemented:
-LumeVirtualMachineCreationExecutor records the actual fresh clone installation
 UUID after native creation and ownership publication. The consumed capability
 cannot create a second destination and retains its original source guard.
-LumeQualificationSourceValidation factors stopped source/evidence/resource/
 signed-release checks away from active lease authorization. Existing clone
 admission retains the same active lease check after source verification.
-LumeQualificationCleanup.observeQualificationClone requires the issuing runtime,
 consumed successfully created capability, active lease, running native clone,
 matching current ownership and private material instance. It returns an opaque,
 non-Codable/non-caller-constructible LumeQualificationCloneObservation carrying
 only clone/material IDs and retaining the original capability. No secret or
 native-check success claim is exposed. Material signatures/control-file hashes
 and private metadata use the existing loader.
-verifyQualificationCleanup is read-only. It requires the matching durable
 released deletion scope (same sandbox generation and name, released token at
 least the original), deletionConfirmed's durable recheck, no native VM, strict
 absence of the clone directory (including unexpected file/symlink), no pending
 deletion intent, and unchanged stopped source/evidence/release before and after
 async observations. It returns complete matching cleanup flags only after all
 proofs. It never writes template readiness or changes capacity.
-The lease-fenced wrapper exposes the two package-only operations. Capability
 internals are module-visible for the separated helpers, but mutable state is
 still accessed only after issuing-actor identity checks. No new unchecked
 Sendable conformance or public bypass was added.

Validation in /private/tmp/darkbloom-sandbox-completion-evidence:
-qualification-source-refactor-tests.log:16existing source/capability/clone tests
 pass, including concurrent consume, cancellation, changed source and expiry.
-qualification-cleanup-tests.log:initial test-fixture Sendable compilation error;
 no runtime tests in that attempt. Fixture has only immutable Sendable fields,
 so ordinary Sendable conformance fixes it; no unchecked shortcut.
-qualification-cleanup-v2-tests.log:4tests/0failures,11.920s. They use real source
 locks, capacity/deletion records and private sparse control/workspace files,
 with a bounded native subprocess fixture. They do not boot a VM.
-Positive: native create, observed running clone and exact material identity,
 actual delete/release, durable deletion proof, repeat cleanup verification,
 source lock retained and no readiness receipt.
-Negative: unconsumed/no-create capability, missing/wrong-instance/changed-control
 materials, stopped clone, active lease, missing VM alone, generic capacity
 removal without deletion proof, reappeared file/symlink, changed/running base,
 or another runtime. Rejections do not release outstanding capacity.
-qualification-cleanup-full-tests.log:643tests,7skips,0failures,151.503s; process0.
-qualification-cleanup-docs.log:286filespass. git diff --check clean.
-No native patch, guest binary/protocol, release package, test-host disk, group,
 service, cache/model or production mutation occurred in this SDK segment.

Read-only test-Mac Foundation observation on encrypted test volume:
 volumeAvailableCapacityForImportantUsage=92,469,192,229bytes;
 volumeAvailableCapacity=52,805,296,128bytes. The default host proof floor is
300GiB (322,122,547,200bytes), so plain df is not its actual denominator and even
important capacity remains below the floor. Do not lower it simply to fit the
machine. Go-cache approval remains pending; no cache or old fixture was deleted.

Next integration work:
1. Add the selected-GUI qualification command and private durable attempt journal
   using the already-installed checkpoint, exact permit/runtime and existing
   capacity store. Hold machineEX and source guard through clone/checks/cleanup.
2. Native checks must come from actual authenticated runtime operations, not
   caller-supplied booleans. Existing root guest paths are
   /private/var/db/darkbloom-sandbox/instance.json and control/instance.json;
   the bootstrap script lives in sandbox-macos/Resources/darkbloom-sandbox-bootstrap.sh.
   The proven public tenant fixture in the earlier physical campaign is
   /private/tmp/darkbloom-sandbox-completion-evidence/vsock-qualification-v1/tenant_fixture.c:
   it checks virtualized UID/GID2001, only2001supplementary groups, absent user/
   group records, inability to restore UID0, explicit EACCES/EPERM on root config,
   raw disks and guest-executable writes, at least6disk/rdisk nodes, and no
   non-loopback IP interface. Missing paths are NOT permission-denial proof.
   Consider moving its small read-only identity probe into the signed guest CLI,
   so qualification needs no external unsigned fixture or guest compiler.
3. Host workspace upload/download must compare bytes/hash/version, then stop/start
   the clone and require a DIFFERENT kern.bootsessionuuid plus the exact persisted
   marker. Use distinct durable command IDs before/after reboot, otherwise the
   host command journal could replay an old boot-ID response. Earlier tested
   session/parser code is in evidence/vsock-coldboot-diagnostic-v2/Sources/QualificationCore/.
4. Observe clone/material identity while it exists; run normal release; call
   verifyQualificationCleanup only after exact deletion. Publish ready evidence
   while the retained source lock and machine authority remain valid. Do not reuse
   active create-lease authorization after release.
5. The observation cannot be decoded/reissued after process loss. Durable recovery
   should settle and abort an incomplete attempt rather than manufacture a proof
   from saved booleans; then start a fresh separately identified attempt. A journal
   must distinguish attempt intent, reservation, clone identity, checks, cleanup,
   and final source publication. Resolve the exact existing reservation/clone on
   recovery; never adopt an unrelated same-name directory.
6. Final source read after ready publication needs its matching-ready validator:
   LumeInstalledCandidateStore deliberately rejects a ready-template receipt, so
   do not call the installed-only reader after successfully publishing readiness.
Physical fresh restore/GUIboot/real receipt collection, login/logout recovery,
build tools/performance, two-VM coordinator acceptance and packaging remain open.


## 2026-09-14 — Native guest checks, cold-boot sequence and guarded publication

Previous goal turn was progress (released-lease cleanup SDK). This turn is
progress (native check/receipt implementation with automated evidence). The
full goal is not complete: durable owner/CLI integration and physical gates remain.

Implemented:
-GuestQualificationProtocol pins the ordinary command executable/argument and
 exact versioned output. No guest RPC operation or wire version was added.
-GuestTenantQualification in the signed guest binary runs only as virtualized
 real/effective UID/GID2001 with only2001supplementary groups (or no groups).
 It checks absent numeric identities and legacy darkbloomtenant name, inability
 to regain UID0, explicit EACCES/EPERM for root instance/control configuration,
 guest executable write access and all observed disk/rdisk nodes (6...256), and
 no non-loopback IPv4/IPv6 address. It opens but never reads protected data;
 writable opens are closed without writing. It returns only a fixed success
 marker. It uses ordinary authenticated command execution, no privileged RPC.
-LumeNativeQualificationDriver verifies exact clean probe output, captures a
 kernel boot UUID, uploads/downloads a marker binding qualification and clone
 IDs, stops/starts, requires a DIFFERENT boot UUID, rechecks probe and marker.
 Upload acknowledgment ID/state/offset/size/hash and download bytes/hash/size/
 revision are validated. Revisions may change after remount; contents may not.
 Command IDs hash attempt+clone+step and differ before/after boot, so the durable
 host command journal cannot replay the old boot-ID response as a new boot.
-LumeVirtualMachineRuntime.runNativeQualification requires the issuing runtime,
 real managed process still running, private endpoint and matching cached
 material instance in addition to the existing clone observation. A capability
 gets one sequence; its flag is set before guest work. Driver closures in tests
 do NOT construct the opaque package result. Actual production operations use
 the normal fenced execute/file/stop/start methods and authenticate every reply.
-LumeNativeQualificationResult has no caller constructor or Codable conformance.
 It retains its observation/capability/source lock and records boot IDs/hash.
-withVerifiedQualificationReceipt checks durable cleanup, constructs the schema2
 record, invokes the callback under explicit withExtendedLifetime(result), then
 reads back the exact published receipt through private/named descriptors and
 the normal clone-readiness validator. Source ownership, stopped resources,
 unchanged disk and deleted-clone/release proof are rechecked. No unguarded ready
 receipt escapes for later publication after source authority is dropped.
-The publication verifier is factored for focused file/readback tests. Those
 fixtures explicitly synthesize native-check booleans; they test readback only
 and cannot instantiate the real native result or confer actual qualification.

Validation /private/tmp/darkbloom-sandbox-completion-evidence:
-qualification-tenant-probe-tests.log:2tests pass for credential/virtualization
 boundaries, raw-device names and denial-vs-missing/other errno classification.
-native-qualification-build.log:first build used the wrong template initializer;
 fixed to init(accountless:) with evidence.ready validation. Build-v2 passes.
-native-qualification-driver-tests.log:6tests pass. Positive complete sequence,
 deterministic but distinct pre/post command IDs, changing revision accepted;
 wrong output/exit/stderr/truncation/timeout/boot IDs/response IDs, cleanup-required
 replies, mismatched transfers/offset/hash/revision, lost marker and cancelled
 restart rejected. Fake running metadata/materials cannot grant managed authority.
-native-qualification-full-tests.log:649tests/7skips/0failures,143.121s before the
 lock-retaining callback and publication verifier changes.
-native-qualification-publication-tests.log:10affected tests pass after callback.
-native-qualification-readback-tests.log:8pass; missing/changed/linked receipt,
 changed disk and reappeared clone fail; exact existing receipt replays unchanged
 while source guard remains held.
-native-qualification-final-tests.log:651tests/7skips/0failures,156.059s; process0.
-native-qualification-cli-smoke.json:actual guest executable rejects host execution
 with exit78 and empty stdout. This is NOT a positive guest/VM test.
-native-qualification-docs.log:286filespass; git diff --check clean.
No native Lume patch changed. No guest package was built/signed/installed on the
test Mac and no physical VM/profile was exercised with the new Swift probe.
The earlier physical C fixture inspired the checks but is not evidence for this
new binary. Old guest packages do not implement qualify-tenant; their hash/command
must not be treated as compatible evidence for the new qualifier.

Next concrete work is the durable selected-GUI qualification command, not another
native-check helper. Use existing machineEX, protected permit/collection binding,
current signed guest release and openExisting capacity state. Intent must precede
reservation; reserve a fresh sandboxID/generation1/name/expiry and persist exact
lease. Native create/start -> observe IDs -> native checks -> normal owned
 deleteAndRelease -> withVerifiedQualificationReceipt callback. The callback
 must durably save the exact ready record before BaseGuestTemplateStore publishes
 it; SDK readback must finish before reporting qualified. Keep source/capability
 retained across publication; the new callback API enforces this part.

Recovery design constraints:
-Use an actor owner so its private journal descriptors stay confined while
 cancellation cleanup calls the runtime through detached work.
-A prior incomplete attempt must settle its exact existing reservation/clone and
 abort, then require a separately identified fresh attempt. Do not decode saved
 booleans into the opaque observation/native result or rerun a consumed sequence.
-Crash after reserve but before lease-journal publication: resolve only one
 matching capacity row by original sandboxID/generation/name/resources/expiry;
 never adopt another same-name VM. Use the normal owned deleteAndRelease path
 for factory reservations, including a failed create with no surviving VM.
-Fresh work uses host/disk admission. Recovery must retain cleanup availability
 when disk space falls; do not expose a general ignore-disk switch.
-Already-published replay may READ and verify the exact ready record against the
 journal, original root collection disk/source and current signed guest files.
 It must not publish a new ready record from saved booleans. The installed-only
 store deliberately rejects ready files, so use its diskIdentity accessor plus
 the ordinary ready-file validator for this readback, under a fresh source guard.
-If publication failed after writing, preserve the file and treat the outcome as
 uncertain until exact readback. Never overwrite a mismatched existing receipt.
-Successful native checks plus cleanup are not enough without final publication;
 command reports must keep installed/qualified/aborted states separate.

Prior source4863f1e9a complete CI34851620108 and integration34851620200 now PASS.
This new source needs its own CI after push. Keep PR996 draft. Remaining physical
fresh restore/GUIboot/real collection, new signed-guest qualification, two-VM
coordinator acceptance, login/logout recovery, build tools/performance and final
packaging remain unchanged. Storage approval remains pending; no cache/model,
fixture, service/group or production mutation occurred in this code segment.


## 2026-09-14 — Public durable qualification owner and recovery

Previous goal turn: progress (native engine and guarded publication). This turn:
progress (qualify CLI, durable owner, recovery and integration tests). Goal remains
active; complete real factory, two-VM acceptance and release gates remain open.

Implemented public ninth phase prepare-accountless-base qualify with existing
common host/name/storage flags plus --permit-file,--collection-file,--guest-release,
--capacity-dir,--qualification-dir. It requires the actual selected GUI/audit
session, protected root inputs, encrypted storage, machineEX, production runtime
identity and an existing capacity store. The private attempt directory is separate
from VM/capacity/release namespaces, and its parent must exist. It never starts
serve or widens the host's capacity policy.

AccountlessQualificationOwner confines the journal to an actor and wires the
actual SDK: verify/complete installed checkpoint, reserve, create qualification
capability/clone, start, observe identities, run native checks/cold boot, delete
and release, then withVerifiedQualificationReceipt. Its callback saves the exact
ready record before BaseGuestTemplateStore publication; the published marker and
qualified report follow SDK readback. Cancellation/failure awaits detached cleanup.
The configured lease limit is used (default300seconds), not an invented30minutes.
The integration test caught the initial1800second/default300 mismatch and fixed
it without widening policy.

Journal records intent before allocation, then lease, clone identity, boot/marker
checks, ready record and publication. Terminal markers are canonical JSON bound
to the intent and ready digest. Checks bind the exact shared marker payload for
the qualification/clone IDs. Existing attempts never allocate or run checks again.
Recovery first resolves/releases only the original resource identity; a crash
between reserve and lease journaling can backfill from exactly one matching
capacity row. Name/ID/generation/resources/expiry changes and ambiguous rows fail.
Expiry fencing may advance the token while retaining issuedAt. Unknown same-name
files/directories are preserved and capacity stays reserved.

Guest release hashing/signature validation is deferred for existing journals so
cleanup does not require a missing old guest package; fresh work/publication still
validate it. Runtime SHA must match the permit before any fresh/recovery action.
Low disk space does not block recovery with fresh-work host admission. An existing
matching ready source may be reverified with verifyPublishedQualification under
fresh source/machine guards, exact root installation/disk/boot claim/runtime and
normal guest-ready validation. Missing ready files are never recreated from saved
flags. Other recovered attempts report qualificationAborted and exit75; installed
status is omitted/unverified instead of falsely reporting the base uninstalled.
Use a new private attempt directory for another native sequence.

Validation /private/tmp/darkbloom-sandbox-completion-evidence:
-qualification-owner-build.log:first compile missed qualify in the root-phase
 exhaustive switch; fixed. qualification-owner-build-v2.log builds.
-qualification-owner-tests.log:11pass (journal/options/source replay).
-qualification-owner-integration-tests.log:3fixture failures from noncanonical
 installation receipt hash in synthetic root collection; fixture normalized to
 the actual root journal encoding. No production validator was relaxed.
-qualification-owner-integration-v2-tests.log:2failures exposed default capacity
 lease limit300 vs proposed1800; owner/journal now use current policy/default300.
-qualification-owner-integration-v3-tests.log:14pass.
-qualification-owner-completed-replay-tests.log:19pass, including actual owner
 recovery with real capacity/ownership files and a bounded native subprocess.
 Allocation before lease journaling is recovered without a guest package; unknown
 directory data and allocation remain. Synthetic saved checks/ready record do not
 publish a missing template; an exact preexisting ready file is read back without
 changing it. These synthetic historical records are NOT native/VM evidence.
-qualification-owner-full-tests.log:660tests/7skips/0failures,148.349s; process0.
-qualification-owner-cli-smoke.json:actual debug help lists qualify; missing
 capacity and runtime override return64 before operation IO. No real VM.
-qualification-owner-docs.log:286filespass; git diff --check clean. Build/test/
 acceptance docs stamped and operator/release references updated.
SDK tests now have a test-only daemon dependency to share native/capacity fixtures
for owner integration. No production module dependency cycle or fixture shipping.

Current worktree next action: commit/push this clean tested implementation, build
new signed host+guest package with runtime13 and NO guest reuse (new probe needed),
verify signatures/entitlements/inventory and stage for authorized test Mac. The
packaging-notarization skill was read; distribution goal is a signed physical-test
package. Eigen Labs Developer ID identity is available locally. No sandbox-specific
provisioning profile was found in task artifacts; omit profile for this test
package and retain persistent-keychain/notarization as explicit release gates.
Local runtime13 exact hashes rechecked: lume53ec2a7073c67c5f0bc712ba1a3d59e0205edfd5c91fb8e156208c430e0389e4;
provenance7a67269640df0daa6643e016584ccad721556b319ddfcfab3d29192165958f03.

Physical fresh restore/stage/boot/collect/qualify, failed-base discard workflow,
actual GUI service logout/login, full two-VM coordinator acceptance, build tools,
performance/stress timeout resolution and final release validation remain required.
Test-Mac storage is still below the300GiB proof floor; Go-cache approval is pending.
No cache/model/old-VM deletion, service/group/authority or production mutation
occurred in this code segment. Native profile13 remains unbooted; current physical
guest evidence is still the older exercise14/coldboot15 diagnostic image.


## 2026-09-14 — Signed owner/guest package and root test-Mac staging

Built with package-sandbox-release.py --sign --lume-runtime pointing to the
unchanged runtime13 tree, --jobs4, and NO --guest-release reuse. Primary package:
/private/tmp/darkbloom-sandbox-lab-20260913/packages/release-7-owner.
Sourcef43af65d83df35a277a89cdc9fca2bc63f2fa48c, source_dirty:false, Developer ID
Eigen Labs SLDQ2GJ6TL. Build completed28.52s. No sandbox-specific provisioning
profile was found among task artifacts; host carries virtualization entitlement
only. production_ready:false, notarization/persistent-keychain/physical tests
remain unperformed. This is a signed physical-test package, not a production
release or deployment. The packaging-notarization skill was applied/read.

Independent primary verification:
-host app, guest, detached release manifest, Lume and detached provenance all
 pass strict Developer ID requirements with exact expected identifiers.
-all16manifest-listed files hash-match; bundle identifier/executable are correct.
-host virtualization entitlement true; no keychain-access-groups entitlement.
-signed host help lists qualify/qualification-dir; signed guest probe rejects host
 execution with78 and empty stdout.
HostSHA76125bd122ab741fba66fc2fb3b2409f41f860b4fdec0f374ce016b2409bb305
GuestSHA7387658b327dd8ba6a667b9805b91a38c23bd33a07425151d94cd4be6a52e363
ManifestSHA76880da45d697ce32195ce9c3f0fa2375cbbe6ee4f656298b836c393cb4be8c3
Ditto ZIP (preserves signing xattrs) SHA20b00e5cb13edc541aac1932b8d55484674820c4bb85a95426cb161e54d29905
ZIP primary /private/tmp/darkbloom-sandbox-completion-evidence/release7-owner.zip.
Primary verification /private/tmp/darkbloom-sandbox-completion-evidence/release7-owner-verification.json.
Build log same evidence root/package-release7-owner.log.

Root installer script same evidence root/install-release7-owner.py
SHA2bac18d8fdf9e19524223409405dc5fc3e7e1fd712bcf20a5c02fdb071dc9379.
It checked archive owner/link/stable identity and exact hash, rejected unsafe ZIP
paths, unpacked to a new root-private directory, verified complete file inventory
and signatures, made every entry root:0/read-only (directories/executables555,
data444), moved to a new immutable target and reverified. It did not replace any
existing package, start a job/VM, mutate authority or touch production.
Remote target /Library/Application Support/Darkbloom/qualification-release7-owner.
Remote incoming /private/tmp/darkbloom-release7-incoming-20260914.
Remote operator /private/tmp/darkbloom-release7-root-20260914.
Root verified host help as UID501/GID20. Permanent authority remains
16777229:29088927 root:431/660/size0/link1. All operations completed.
Export copied to primary evidence/release7-owner-installed-evidence.json
SHAbe6c1edf47a6c6429e66753dbbeec7aa7c512f8506d041be343f87be11963f1d.
It confirms matching source/hash/signatures/immutable ownership, no service/VM
start and no production readiness claim.

READ-ONLY storage planning (du allocation may double-count APFS clones):
-/private/tmp/darkbloom-sandbox-lab-20260913:117,869,203,456bytes, including old
 disposable VM fixtures and the19,772,231,540byte restore IPSW (keep for fresh restore).
-/Volumes/DarkbloomSandboxTest-20260913/host:73,194,065,920bytes; ROOT access was
 needed. This is newly measured, not proof that every file is disposable. Inspect
 its exact old VM identities, lease/material state and process/image openers.
-/Volumes/DarkbloomSandboxTest-20260913/gui501:23,610,413,056bytes; KEEP latest
 diagnostic VM/evidence. It remains the only actual exercise14/coldboot15 image.
-old nonbootable APFS fixtures:initial collection1,085,980,672bytes; staging
 initial1,121,677,312bytes; staging-v2 1,084,731,392bytes. Preserve evidence and
 verify authority/detach before any future cleanup. No deletion occurred.

Remaining model caches, queried as user (not deletion authorization):
-EigenLabs/NVIDIA-Nemotron-3.5-Lightning-30B-A3B-MLX-4bit-mtp:18,544,263,168bytes
-EigenLabs/Qwen3.8-27B-4bit-mtp:16,320,466,944bytes
-gemma-4-26b-qat-4bit:23,583,088,640bytes
-gpt-oss-20b:12,104,245,248bytes
-mlx-community/gemma-4-31b-4bit:18,444,447,744bytes
-qwen3-vl-30b-a3b-instruct:18,268,209,152bytes
-qwen3.5-27b-claude-opus-8bit:28,599,943,168bytes
All live under /Users/gaj/.cache/huggingface/hub/models--<name encoding>.
The approved older models--gemma-4-26b8bit deletion is already complete. Go build
cache remains unapproved (last68.2GiB). Do NOT delete these other models/caches
merely because inventoried. First reclaim only verified obsolete OWN artifacts
under existing task authorization, then remeasure actual important/free capacity
before requesting any additional exact cache cleanup. Never assume du totals are
reclaimable bytes; preserve source repos, latest GUI diagnostic VM, encrypted
volume/passphrase and permanent runtime authority. No new permissions requested.

Ownerf43 source: CI34858536670 and integration34858537007 are running;
benchmark34858536943 waits for separate environment approval. PR996 remains draft.
Physical fresh complete factory, explicit failed-base discard operation, actual
GUI service recovery, full two-VM consumer campaign, build tools/performance and
final release validation remain required. Keep goal active.

## 2026-09-14 — Verified obsolete task VM retirement

Read-only inventory fixed six stopped task identities. Signed runtime13 cleanup
operator /private/tmp/darkbloom-sandbox-completion-evidence/retire-task-vms.py
SHA999450955e28cdd1895c2cdf795588609901763a2bf50232326a15f4a0c5d8f7.
Preflight and apply both completed0. Root evidence is retained on encrypted volume
/Volumes/DarkbloomSandboxTest-20260913/retired-task-vms-20260914/{preflight,apply}.
It contains bounded configs/ownership and metadata, never raw guest credentials.
Deleted only old lab probe2/probe3/retirement-probe/sandbox-base and the old UID430
qualification-import1/qualification1. Latest GUI501 diagnostic VM is preserved.
Each fixed directory/disk/config/ownership identity was checked; no media openers
or attachments; machineEX, configEX and run-owner POSIX lock retained during
native delete. Every deletion independently checks absence and preserves latest
GUI tree, IPSW, existing unrelated siblings and Apple attachment device identities.
Authority dev16777229 inode29088927 root:431/660/size0/link1 unchanged.
Free increased52729552896 ->177322176512bytes, delta124592623616bytes. Import1
freed almost no bytes alone because its boot disk shared APFS extents; totals
were measured after actual deletion, not inferred from du allocation.
Primary result SHA f1783266dbbaf75ddb58246f37e41a51efad6ac09d790f43f56cf5e5b1458efe.
Follow-up Foundation important capacity216986375717bytes still below322122547200.
Asked permission for four exact user caches; no reply yet, no cache deletion.
No new VM/service was started and no production action occurred.

## 2026-09-14 — Exact failed-base discard command

Added discard-base with protected selected-user identity, explicit installation
UUID, permanent machineEX and production runtime configuration. Cleanup needs no
GUI session, guest package or free-space admission; it creates/boots no VM.
LumeUnqualifiedBaseDeletion checks exact raw Apple source under the ordinary
operation lock and rejects ready receipt entries, guest materials, unknown or
legacy ownership and running state. Root maintenance fences block fresh/recovery.
The existing stopped deletion intent now optionally records unqualifiedBase:true;
ordinary serialized intents omit this field. A discard retry requires that purpose
and exact installation ID, then removes only the saved stopped directory inode.
It can recover after config/ownership/native inventory disappearance, preserves
replacements and recreated names, and clears the intent only after durable removal.
Successful CLI output reports absent:true, including already-absent replay; it does
not claim a new deletion or source qualification. Root evidence is retained.

Implementation is split into options, command, SDK eligibility and existing durable
removal. No new coordinator/provider wire field or capacity policy is introduced.
Refactor pass kept the public entrypoint thin and corrected stale completion docs.
Validation: discard-base-focused-tests.log22pass; discard-base-full-tests.log671
with7explicit skips/0failures,156.044s; discard-base-cli-smoke.json3pass;
discard-base-docs.log286filespass. Full suite contains an additional fresh/recovery
root-fence case beyond the initial focused run. Test native processes are synthetic;
the newly signed discard command still needs physical validation. No further user
cache deletion, VM start, service mutation or production action occurred.

## 2026-09-14 — Release8 signed package ready for physical testing

Commitb8917eda1e75efc7c0695cc477306600d07da4e5 pushed to PR996; predecessor local
checkpoint4485bbbf1 included. Clean source was packaged with unchanged runtime13,
--sign --jobs4 and NO guest reuse. Package build16.98s, completed0:
/private/tmp/darkbloom-sandbox-lab-20260913/packages/release-8-discard.
All16manifest files match, all Developer ID signatures verify, bundle metadata
and virtualization entitlement correct, no keychain-access-groups, host help
contains discard-base and qualify, guest qualify-tenant rejects host78/emptyout.
HostSHA7bb2589b90d9c7036d2488f1fbc4065b22cdd114b3081b418562d03008ac400d
GuestSHA6a7f3a9d800666936ae8c63b740560511d4c275fae00a1f27ed76ee74ea8fc00
ManifestSHA46ddc2baa7999c0204497abf4f25d6cc673098e26100ef884e708b01f712ea54
ZIPSHA3841eafea37fa271174f05cc97e3caa74a6a645f29426dfe1aaeb917e65a7344
InstallerSHAe4c44481cd6044de62d5695bf153003cf208b6936a34594c90c495f49dcdcbce
Root installer read/hash-binds the ZIP, checks path inventory, signatures and
ownership, and stages root:0 immutable555/444 without replacing old packages.
Remote /Library/Application Support/Darkbloom/qualification-release8-discard.
Remote incoming /private/tmp/darkbloom-release8-incoming-20260914; root operator
/private/tmp/darkbloom-release8-root-20260914. Host help passes as UID501/GID20;
permanent authority inode unchanged. No service or VM started. No provisioning
profile, notarization or persistent-keychain qualification; production_readyfalse.
Primary verification and installed export:
/private/tmp/darkbloom-sandbox-completion-evidence/release8-discard-verification.json
/private/tmp/darkbloom-sandbox-completion-evidence/release8-discard-installed-evidence.json
Installed evidenceSHA7cde016a4aa13c1deb257e7fecd18eaa3dc8f030411f6f04b3625971231b7b68.
PR description updated with exact discard flow, validation and remaining gates.
Current-head CI34862480863/integration34862480870 stillrunning; benchmark34862480928
waiting approval. Source full suite671/7skips/0failure is local evidence.

Pending user answer still required for four exact caches listed near the top.
Do not infer cache permission from continued goal execution. Until space is
available, independent next work can verify signed discard on an explicitly
nonbootable owned filesystem fixture using real native inventory and exact host
identity. This must not be represented as new VM/isolation/factory proof. Then
continue full fresh factory and two-VM acceptance without lowering admission.

## 2026-09-14 — Signed discard CLI real-Mac filesystem acceptance

Unchanged release8/sourceb8917eda1 passed11checks through its actual public
command, as selected UID501/GID20 with root-protected host identity and normal
machine authority. Tests used zero-allocated sparse100GiB files plus synthetic
native config/NVRAM with NO hardware model or machine identifier. These fixtures
are deliberately nonbootable; no VM was started, no isolation/template evidence
was created and none may be promoted to a base.

Checks: wrong installation preserved with exact refusal; even malformed ready
receipt preserved; root maintenance fence preserved; normal signed native delete;
absence replay; recreated same-name installation preserved; new installation
own delete; native FileManager deletion failure from an inaccessible root-created
child retains the actual SDK's durable unqualified-discard intent; wrong recovery
ID preserves that intent; after removing only the exact test obstacle a fresh
public command recovers; subsequent absence replay succeeds. Target and intent
are absent, permanent authority metadata, latest GUI diagnostic tree and Apple
attachments remain unchanged. No source change or validator weakening needed.

v1failed BEFORE runtime with root identity0400 from operator umask077, so its
negative-result labels prove no intended gate. v2corrected444 but failed BEFORE
runtime because Darwin child group provisioning with extra_groups=[431] did not
provide effective lock access despite getgroups reporting the directory group.
Read-only paired subprocess controls prove [431] openRW->EACCES versus [20,431]
openRW->success on the same untouched authority. v3includes primary group slot20
and431 and verifies each negative error reason; positive deletion/recovery pass.
These are harness setup defects; no production group/identity rule was relaxed.

Final operator primary:
/private/tmp/darkbloom-sandbox-completion-evidence/discard-cli-physical-v3.py
SHA81d006aa317c16b9c88b678d25c907ba6b08b73a191cd82bd4b71163dcfae386.
Remote root report /private/tmp/darkbloom-discard-cli3-20260914/result.json.
Protected public binding /Library/Application Support/Darkbloom/qualification-discard-cli3/host-identity.json,
hostID0c12dc48-ce5b-47af-83cf-dc77585b0cfc.
Fixture storage /Volumes/DarkbloomSandboxTest-20260913/discard-cli3-20260914/vms.
Test VM name darkbloom-discard-cli-probe1 is absent. No services started.

Exact cleanup/export operator:
/private/tmp/darkbloom-sandbox-completion-evidence/discard-cli-export.py
SHA7ead85805b84bde4f7d0f513a4cfea29e1dcdb17f20e5c077fadc2add482806e.
It verified the two earlier fixtures were exact synthetic config/NVRAM, zero-
allocated sparse disks and expected private entries, fixed ONLY its own root
binding mode for v1, and deleted both via the signed public CLI with their own IDs.
All three fixture VM directories absent. Original failed reports remain preserved.
Small storage/runtime support directories and protected bindings remain as evidence.
Primary combined export /private/tmp/darkbloom-sandbox-completion-evidence/discard-cli-evidence.json
SHA1f79961bd556b975ce09f92d8af4efdeb2ba291da957ccf320874ca33cc122c1.

Go/model cache permission remains pending. No new user cache or model removed.
Full fresh restore/installer/qualification, actual GUI service recovery, two-VM
consumer acceptance, workload/stress performance and final release gates remain.
CI34862480863 and integration34862480870 were still in progress at last check.

## 2026-09-14 — Doctor follows the selected VM-storage volume

Found a CLI diagnostic gap: doctor always inspected root while raw reservation
and qualification inspect the selected storage directory. Added doctor --storage
DIR with root default retained, strict bounded absolute argument parsing and no
admission bypass. Missing capacity still reports -1/failure. The actual GUI
doctor invocation is the next physical prerequisite check; it creates no VM.
Read-only build/validation: existing SandboxHostDiskInspectionTests2pass;
doctor-storage-cli-smoke.json6checks verify root has measured capacity, selected
missing path yields -1 and exit78 without falling back to root, and malformed/
duplicate/missing options exit64 before inspection. No missing path was created.
Source graph rebuilt by swift test. Resource release guide and changelog updated.
No full671suite rerun for this isolated diagnostic CLI change; it does not alter
runtime/admission policy. Prior full671/7skip/0failure evidence remains b891.
CIb891 sandbox/coordinator/UI/release/docs/sidecar pass; provider and integration
remain running at last poll. No cache permission reply.

## 2026-09-14 — Signed storage doctor in the actual GUI session

Clean sourceed05d0b8497e9e312708906ef485d61091476e7a packaged as release-9-doctor,
--sign --jobs4 with unchanged runtime13 and --guest-release release-8-discard.
Only host rebuilt (11.41s); all4signed guest artifacts byte-match release8, without
re-signing.16manifest files and all Developer ID signatures verify; host help
advertises doctor --storage. Root immutable installation completed0:
/Library/Application Support/Darkbloom/qualification-release9-doctor.
No service/VM started by installation; no profile/notarization/persistent-keychain
qualification. Host SHAd73a28994e7e33809e5f492e01a8ce121d9b1e2b5179cf742c1fdb4e115e97ff
GuestSHA6a7f3a9d800666936ae8c63b740560511d4c275fae00a1f27ed76ee74ea8fc00
ManifestSHA2c728a3c80d1a9cd2646752dc4190e6b8f80d5b1d9d238191d044c0b5ae2b5b7
ZIPSHA3af6c20d86a7be32affa9e400d4fddca982948bb35a77557f8f085c08c16dab5
InstallerSHA75c0f86f2f488a7cf8cd3dcd298f01062d1c990e376f4a891768f1fc6fe66b14
Primary installed export release9-doctor-installed-evidence.json
SHA8aa274495a6e431f06924b16dd23687802eece19a6340c76e0f44e8e78c28114.
All primary paths under /private/tmp/darkbloom-sandbox-completion-evidence.

Actual Aqua command: signed host doctor --storage
/Volumes/DarkbloomSandboxTest-20260913/gui501/vms --json, in one root-defined job
loaded only into gui/501, labelio.darkbloom.sandbox.doctor.storage1, KeepAlivefalse,
no UID/GID switching, no HOME/environment override, no recurring startup. Output
lives on encrypted volume /Volumes/DarkbloomSandboxTest-20260913/doctor9-gui501-20260914.
Protected plist /Library/Application Support/Darkbloom/qualification-doctor9.
Operator /private/tmp/darkbloom-gui-doctor9-20260914.
Exactly1run, terminal78:EX_CONFIG, noPID. Host report2026-09-14T15:47:29Z:
-disk_capacity FAIL:216892593701available vs322122547200required.
-apple_silicon, hardware_virtualization, virtualization_framework, cpu_capacity
 (14), memory_capacity(38654705664), aqua_session(actualUID501), secure_enclave
 (transient ECIES roundtrip), virtualization_entitlement allPASS.
No --development-unsigned flag. No persistent enclave key or VM was created.

Initial observer failed parsing launchctl's '78: EX_CONFIG' as an integer after
it had already persisted the terminal observation. Collection recovered that
same completed job without rerunning it, parsed only the numeric prefix, read
the existing bounded report, booted out only the exact job and verified it absent.
The authority keeps its original inode/owner/group/mode/size and noopeners remain.
No pre/post full VM-tree preservation claim is taken from the interrupted observer;
its full in-memory baseline was not persisted. Doctor's code path starts no VM.

Primary gui-doctor9.py SHA936ff78ca2ab0327032555e7e61fbd7e3525f3b9cb065dc1031be46b8e8cc929;
gui-doctor9-collect.py SHA8180911ec6167411c2240e14dccf6ea228115117eb7acbf943ec8299b27372be.
Primary gui-doctor-evidence.json
SHA78dce612265e507a3848d3e62eed9d5295c3741b0891d048cb121e4f8fa4a615.
This provides current signed host/GUI/storage preflight. Actual GUI machineEX
can still be checked through reserve preflight before any new restore; doctor
does not acquire machine authority. No user cache permission reply has arrived.
