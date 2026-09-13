# Sandbox completion checkpoint

Status: implementation and validation in progress; no release-readiness claim.

## Ownership and source

- Working branch: `codex/sandbox-completion-20260913`.
- Starting sandbox state: `0950ac41e` (August VM runtime and durable coordinator).
- Integrated master: `93337ef05`; integration commit `453b37667`.
- Main and previous sandbox worktrees are preserved.
- Evidence directory: `/tmp/darkbloom-sandbox-completion-evidence`.

## Product decisions

Complete an opt-in macOS CPU sandbox service using the existing VM controller,
fenced Lume runtime, and independent sandbox daemon. The initial supported guest
executes tenant commands as an unprivileged user. The root guest supervisor owns
the authenticated vsock channel and fixed-capacity workspace. Host device policy
denies audio, clipboard, host-directory sharing, and uncontrolled networking.
GPU jobs remain a distinct capability requiring separate proof. No inference
behavior or production service changes occur as a side effect of enabling code.

Service enablement, account admission, and draining are separate states. Cleanup
remains possible after admission closes. Runtime ownership must be enforced by
both inference and sandbox services before they can share a machine. No operator
drain is silently cleared on daemon restart.

## Work owners

- Parent: master integration, Lume device/network/guest bridge, runtime storage,
  host ownership, final integration, review and physical campaign.
- guest_architecture: bounded shared guest protocol, guest supervisor/executable,
  tenant process and file operations, package targets and guest unit tests.
- control_audit: coordinator admission/allowlists, cleanup and cancellation,
  command listing, sweep observability and focused Go tests.
- physical_inventory: release/signing and validation scripts, release resources,
  environment/evidence inventory; no service installation yet.

## Acceptance matrix

- [x] Integrate latest master preserving independent inference changes.
- [x] Baseline sandbox Swift package: 282 tests, 6 physical opt-ins skipped,
      zero failures; `swift-baseline.log`. Not physical acceptance.
- [ ] Default-off service, explicit account admission, durable cleanup after drain.
- [ ] Root guest supervisor, authenticated vsock, non-admin tenant, bounded I/O,
      cancellation and escaped-descendant handling.
- [ ] Minimal VM devices, enforced network policy, no host LAN/clipboard/audio exposure.
- [ ] Fixed-capacity workspace, encrypted persistent artifacts, revision binding,
      key deletion and restart reconciliation.
- [ ] Machine-wide inference/sandbox ownership and persistent operator drain.
- [ ] Consumer CLI/API create/upload/exec/read/cancel/delete and useful diagnostics.
- [ ] Signed host/guest/Lume release artifacts and reproducible installation checks.
- [ ] Full Go tests, focused races, real disposable PostgreSQL, vet, Linux build.
- [ ] Full Swift unit tests, release builds, pinned Lume tests, protocol symmetry.
- [ ] Physical single-VM and two-VM end-to-end tests, denial/cleanup/crash campaign.
- [ ] Paired host/VM CPU and CI performance evidence with raw measurements.
- [ ] Modular refactor and independent review; docs and release claims match evidence.

## Environment constraints found

Local Mac: 128 GiB RAM, 16 cores, macOS 26.5.2, Xcode Swift 6.3.3. About 238 GiB
available at inventory. The existing two-VM reservation policy needs at least
272 GiB for two 100 GiB boot disks, two 25 GiB workspaces, overhead and headroom.
No existing Lume binary, IPSW, or VM image found. Developer ID signing identity
exists; a matching sandbox keychain provisioning profile has not been found.
Existing Darkbloom provider processes are running and must not be stopped or
reconfigured without a specific, concrete local test decision.

## Current implementation checkpoint (September 13)

The goal remains active. This is an in-progress checkpoint, not a completion report.

- Coordinator access, cancellation, metadata-only command history, and bounded
  resumable file relay are implemented. Downloads now pin a file version across
  chunks. Focused Go, disposable PostgreSQL16, race and docs checks have passed
  at intermediate revisions. The temporary DB listens only on localhost60817.
- A real single-connection Postgres startup deadlock was reproduced and fixed by
  keeping migration advisory-lock ownership out of the constrained pool.
- Guest protocol/runtime/executable, root-authority validation, unprivileged
  execution, descendant cleanup and resumable filesystem operations are present.
  Twenty-one focused tests passed before later version-binding additions.
- Host vsock client authentication, request/response identity and cancellation
  tests passed. Runtime start/execute/file mapping is being integrated.
- The complete pinned Lume test suite passed171 tests plus six exact lifecycle
  regressions; Developer ID release build completed with patch0005. Patch0006
  adds inherited machine-ownership proof and narrow macOS path-alias handling;
  the final signed runtime must be rebuilt from that exact updated lock.
- The first combined Swift run executed314 tests with6 physical skips and one
  pin mismatch because the patch digest changed after compilation during that
  run. It is not the final authoritative test gate; rebuild after edits settle.
- Signed debug host/guest products and release-tool tests passed. Those products
  have no matching sandbox keychain profile and are not a notarized release.
- Apple's19,772,231,540-byte macOS26.6.2 restore image downloaded with SHA256
  885503b7f4b06609e9a512f2befd40f59730640a3f1233e3892d60affdd51c95.
- A live material-generation test produced exact128MiB control and25GiB workspace
  APFS disks, checked read-only control contents, and detached its test mount.
  It caught a blocks-vs-bytes hdiutil argument bug, fixed using explicit sectors.
- Raw VM image files use verified FileVault-encrypted APFS host storage for the
  initial at-rest guarantee. They do not provide per-VM key erasure. Artifact
  encryption/key wrapping remains distinct and must not be represented as an
  integrated per-VM encryption mechanism.
- Independent host-runtime package and provider lifetime hooks are implemented.
  Eight tests passed including child retaining EX after parent closes its copy.
  The Lume process must inherit that descriptor so broker death cannot release
  exclusivity before the VM dies. No system authority has been installed.
- `sudo -n true` reports password required. No administrator mutation performed.
- User home has a normal deny-delete ACL that strict authority code rejects.
  Never remove it. Use a private0700 lab directly under `/private/tmp` and only
  the supported `/tmp`/`/var` system aliases. Existing lab Lume output under the
  worktree must be relocated/rebuilt for this trusted-ancestor requirement.

Current subagent ownership: control_audit is building the standalone Go consumer
CLI; guest_architecture owns signed base-image installation and shared template
receipt; physical_inventory owns machine ownership and Lume patch0006. Parent
owns service integration, clone qualification, final tests and physical campaign.

## Latest integrated checkpoint (supersedes earlier intermediate counts)

The goal remains active. All feature files are still uncommitted on the isolated
branch; the main checkout remains untouched. No production or administrator
installation has occurred, and no guest image has qualified yet.

- Full coordinator baseline: 5,960 passing test events (3,502 top-level + 2,458
  subtests), 29 tested packages, three explicit opt-in skips. Vet and Linux
  build passed. A second full suite is running after start/recovery changes.
- Full sandbox Swift wave4: 372 tests, seven physical opt-in skips, zero
  failures in77s. Later focused durable-resume and adapter proof tests passed;
  another final complete run is needed after the Lume8 pin and latest fixes.
- Lume7 full suite and release build passed; three new tests prove fail-stop
  diagnostics reach stderr without buffering, without blocking on a full pipe,
  and without SIGPIPE when the reader closes. Six required lifecycle regressions
  also passed. Signed binary SHA256:
  dcd9ecdfd721b9399dc0a96b226b0490a16dfd20fe07bbca301c4d8bed1d98ca.
  Runtime: /private/tmp/darkbloom-sandbox-lab-20260913/runtime/lume-diagnostic.
- Exact patch7 SHA256:
  175352985a63ba818926c36604d79dc89e5e457cd369292365544c83657e66a5.
  External source baseline6 commit50c05cdcc; guest_architecture now owns patch8.
- Real base creation failed repeatedly with exit70. Patch7 finally exposed the
  cause: cancellation during unattended setup races two VZ.stop requests, and
  the second rejects stopping->stopping, triggering fail-stop. Agent is fixing
  shared bounded native stop completion without relaxing terminal proof.
  Evidence: base-prepare-diagnostic-v4.log. Failed VM files were cleaned up.
- Guest safety fixes now include native nofollow workspace/.tmp setup,
  synthetic root mountpoint staging for next boot, root-only scheduler allowlists
  plus disabled cron/at services, tenant launchd-domain removal before/after UID
  cleanup, and bounded binary-plist worker payloads covering JSON escaping cases.
  Native13 focused tests passed. Live root policy remains unverified.
- Explicit start API uses old scope + requested new fencing token + unchanged
  lease expiry. Host resume atomically rotates authority without adding capacity
  or extending the deadline. Replay must force identical-state publication
  before starting; later fences reject replay. All failed start responses now
  require stopped proof, or return runtime_cleanup_failed. Coordinator retains
  failed+lease in that case, with DELETE still actionable.
- Current authoritative stopped heartbeats can transition ready->stopped after
  command/file cancellation stops a VM. They never promote ready, never override
  pending lifecycle operations, and must exactly match epoch/host/fence/resources.
  Active command cancellation still blocks Start until cleaned up.
- Durable delete intent is re-fsynced before any bytes are removed on retry.
  Private journals are inside the VM tree. Recovery covers partial tree removal,
  full removal before capacity release, and durable release before intent removal.
  Clone sources with pending deletion also fail admission.
- New command IDs are limited to256 per VM installation. This bounds worst-case
  serialized output+allocation allowance+128MiB control disk+128MiB safety below
  the existing1GiB overhead. All previously accepted IDs continue to replay,
  including legacy journals already above the limit. No eviction/re-execution.
- Host adapter was split into interfaces, thin actor, provisioning, commands,
  start, teardown, file mapping and wire-result modules. Full wave4 covered it.
- Offline tests passed: release tools15, live acceptance harness10, benchmarks3.
  Consumer live harness has not contacted an API/VM. It prepares two owned
  sandboxes, positive controls/isolation, bounds, timeout/cancel/start, overlapping
  jobs, explicit deletion and real30min expiry, with owned-ID-only cleanup.
- CPU benchmark compiles once, verifies identical uploaded binary/checksums,
  and records alternating host/guest execution separately from API wall time.
  Host-only smoke passed; it does not establish VM or CI performance.
- README now states implemented offline CPU profile, transport trust boundary,
  FileVault at-rest guarantee, and pending physical gates. No egress gateway,
  GPU, snapshot restore, or per-VM cryptoerase is claimed.

Current agent ownership:

- guest_architecture: external pinned Lume8 coalesced native stop + tests; notify
  root before updating lock/config/test pin. Root then owns canonical signed build.
- control_audit: final Go recovery full suite, docs, race/PG evidence. No staging.
- physical_inventory: final packaging installer permissions/ACL verifier fix
  (0700 staged root cannot remain0700 after root-owned install), optional bounded
  workspace-exhaustion acceptance case, and final scripts review.
- root: integration, physical base campaign, release3 rebuild, final tests and
  review evidence. Existing release1/release2 packages predate security fixes and
  must not be installed for tenants. No signed release3 yet.

The original async request for a nonproduction test Mac/admin access and≥300GiB
free remains unanswered. Current Mac has around185GiB free after failed-VM
cleanup, two existing inference providers, no system ownership authority, and
no passwordless sudo. Do not stop providers or bypass ownership checks. No
sandbox-specific provisioning profile/notarization/production adoption proven.
