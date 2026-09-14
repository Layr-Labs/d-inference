# Sandbox completion checkpoint

Status: active goal; implementation under review, physical qualification incomplete.
No production deployment. Keep PR #996 draft until the physical gates pass.

## Current verified state

Current changes add recoverable accountless payload staging and its durable
journal. Localf235b8ad2 adds signal cancellation, actual GUI-session monitoring
and cleanup covering all post-runtime startup/service exits. Source6cf8f3381 adds
installed-checkpoint publication after qualification-clone consumerb48455139 and
requested-resource configuration32be94642. Full sandbox suite passes539tests,
7explicit skips,0failures (130.665s). Coordinator suite, Linux
build, docs lint, UI lint and Next.js build pass. CI34811478625 passed6cf8f3381;
integration34811478687 is still running. The latest local code requires fresh CI; benchmark
environment approval is separate and has not been granted.

Physical guest exercise14 and coldboot15 PASS on the test Mac. They prove
selected authenticated execution/files/isolation/cleanup, retained workspace,
and a genuinely different guest boot. Both VM owner exits and independent root
quiescence pass. No VM is currently running. The diagnostic clone has guest
inode32638, SHA8dd96a80d7c96d15cf49e143416c8bf665c9a47464885ee1733d06b8544a3369;
it is not a qualified production template. The full details and exact root proof
digests are recorded at the end of this checkpoint.

Next: complete accountless privileged staging/boot/collection orchestration and
the automatic qualification/cleanup-to-ready-template handoff; physical GUI host
service termination/login recovery and recurring startup; full2VM coordinator acceptance, build tools,
performance and final release qualification. Keep test CI paused and gaj's
explicit temporary runtime-group membership until the machine campaign finishes.

## Source and ownership

- Worktree: `.worktrees/sandbox-completion-20260913`.
- Branch: `codex/sandbox-completion-20260913`.
- Starting sandbox tip0950ac41e; master93337ef05 integrated in453b37667.
- Latest pushed code:6cf8f3381; local lifecycle commitf235b8ad2 plus current
  accountless staging changes. Verify git HEAD and remote before resuming.
- Local GUI plan commit3abe05f712de1d2dcc6958315c1fbf56b4b693ff follows
  host context50145d4b4 and qualification validator4cab8f470.
- Managed restore lifetime commitb5680748bd9d4670f3ee4c02ea2ffc38810c981d
  and native patch9 are implemented; signed runtime9 still needs physical tests.
- Local updates:c5d452148 requires explicit schema2 accountless installation/
  native qualification/cleanup evidence;4245ae67a persists one-shot raw candidates.
  Candidate14tests pass; receipt34pass/1existing opt-in skip.
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
