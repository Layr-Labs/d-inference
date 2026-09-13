# Sandbox completion checkpoint

Status: active goal; implementation under review, physical qualification incomplete.
No production deployment. Keep PR #996 draft until the physical gates pass.

## Source and ownership

- Worktree: `.worktrees/sandbox-completion-20260913`.
- Branch: `codex/sandbox-completion-20260913`.
- Starting sandbox tip0950ac41e; master93337ef05 integrated in453b37667.
- Latest pushed commit:5c25e79a22da55443ccc639ba6c3e567d41eb280.
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

## Validation at the pushed source

- Swift wave8:400tests,7 physical opt-in skips,0failures,78.9seconds.
- Coordinator:6005passing events (3527top-level,2478subtests),30packages,
  3opt-in skips,0failures. Focused race/vet and macOS/Linux builds pass.
- Packaging26tests; live harness13 offline tests; CPU harness3tests;
  real Go CI harness12Python tests and its Go runner race suite pass.
- Pinned Lume186tests plus6required checks; native stop9focused tests;
  fail-stop diagnostics3tests. Physical public-base create/boot/SSH/stop pass.
- Provider ownership14focused tests; benchmark CLI target built.
- Docs lint283files; actionlint pass.
- Go CI benchmark host-only baseline:356passing events per sample, two native
  samples plus relocated source, four compiled artifact hashes identical.
  No guest performance or compatibility claim yet.
- GitHub5c25: coordinator/sandbox/lint/docs/UI/release-integrity/CodeQL pass.
  Provider/E2E integration were still running at the last snapshot; benchmark
  gate waits. Threat Model Review returned external API401 invalid credential;
  no review result exists and no secret/workflow was changed.

The live-harness improvements add active-VM natural expiry, file
resume/abort/version controls, idempotency replay/conflict, and accurate
coverage exclusions. Their26offline tests, syntax/diff checks and docs283-file
check pass. Second-account and in-flight transport-disconnect proof remain
explicitly outside this harness; command timeout can race natural lease expiry.

## Authorized test Mac and storage

The user authorized SSH/sudo on nonproduction `gaj@100.104.151.128`.
Credentials remain in the conversation and transient authentication only.
ControlMaster: `/private/tmp/darkbloom-sandbox-test-remote-20260913/control`.
Held SSH session49221. Never write the SSH/sudo password into files or logs.

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

The new volume root is initially gaj:staff0775. Before broker use, the reviewed
root setup must make that EXACT root root:wheel0755, then private broker0700
children. No broker or machine authority exists yet. UID/GID430 and runtime
GID431 were free at inspection; recheck before creation. Agent prepares a
root setup script but root must review and explicitly execute it. Review
found automatic macOS groups12(everyone),61(localaccounts),701(gaj Public
Folder sharepoint nesting everyone),100(Print Operator nesting localaccounts).
The script is being revised to verify this exact measured implicit graph and
only the intended explicit memberships. InitGroups=false alone is not proof
that opendirectoryd cannot resolve further memberships. Actual launchd
credentials and group-file-access qualification remain separate.

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
listens only127.0.0.1:60817. Its admin is sandbox_test. The dedicated database is
darkbloom_sandbox_acceptance_02eeb9902f48, with restricted owner
sandbox_acceptance_02eeb9902f48. The real fixture seeded one ordinary consumer
with24hour API key and separate host credential. No production/admin key.
DSN/coordinator environment remain private on the primary Mac. No fixture
credentials have yet been copied to the test Mac or broker.

Real coordinator session76358, PID95344, listens ONLY127.0.0.1:18080.
SSH reverse tunnel exposes only test-Mac127.0.0.1:18080. Authenticated sandbox
list returns empty; unauthenticated list401. No registered host or allocations.
Health explicitly reports source5c25e79a22da55443ccc639ba6c3e567d41eb280.
The prior owned coordinator34128/session77821 stopped with zero allocations.

Current binaries came from a private git archive of committed source5c25,
Go1.25.4, -buildvcs=false -trimpath -mod=readonly, explicit coordinator build
metadata. Manifest: private fixture/artifacts-5c25e79a2/manifest.json.
The earlier linked-worktree Go build used correct source but Go1.25.4 stamped
the outer checkout because .git is a file. Do not trust that old VCS stamp.
Old binaries are preserved under private fixture/pre-provenance-bin.

## Guest installation blocker and exact probes

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
v6 diagnostic probe is running in session55768; inspect it before any next VM
action. Its signed SHA256 is
6b72307feaddafcebbef4b6198c5f929e23dbf9934fdde07f8a0a428279440b4.
v6 removes the prior own inspection job before attempting the reset, then
stages inspection for the following cold boot. Latest v5 driver session83363
completed. Evidence retirement-v5-proof.log and
retirement-v5-final-state.json under REMOTE lab/evidence. Check newest state
before further actions. Root owns VM lifecycle and all probe signing/transfers.

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

## Remaining gates

1. Diagnose actual macOS retirement failure; implement modular supported
   retirement and strict startup verification, focused tests and fresh signing.
2. Complete fresh signed guest installation, clean shutdown and cold-boot
   qualification. Never admit the partial base/probe as a tenant template.
3. Review/execute test-host authority setup, safely reserve idle test machine,
   install immutable signed package under broker identity and qualify doctor,
   actual guest channel, encrypted disks and dedicated admission.
4. Run real single/two-VM API/file/isolation/quota/cancellation/timeout/start,
   natural expiry, idempotency and cleanup campaigns. Independent host inventory
   must prove VM/material removal. Add actual broker crash/restart/reboot and
   submitted-launchd-job respawn tests; API terminal state alone is insufficient.
5. Run paired host/VM CPU and real offline Go CI build/test measurements under
   the actual tenant UID; include contention and compatibility limits.
6. Final modular refactor/review, relevant tests, docs/checkpoint/PR refresh and
   latest CI. Production signing profile/notarization/external review, merge,
   publication and adoption remain separate explicitly evidenced gates.
