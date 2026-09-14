# Accountless installation and template evidence

These types and validators describe stored evidence. They do not perform an
Apple restore, root installation, native qualification or cleanup. A preparer
must observe each step before publishing its result; constructing a Swift value
is not proof that the physical step ran.

`AccountlessInstallationPayload.prepare` now generates a one-shot first-boot
overlay from an owned raw candidate and its exact signed guest release. It
preserves signing attributes, checks the source and copied guest inventory,
and binds the candidate, installation attempt, source ownership and payload.
It writes no VM disk and performs no mount, root installation or VM start.
The generated guest job refuses a physical host before writing any result,
records actual guest OS/architecture, verifies installation and absent human
accounts, and atomically publishes complete JSON at every observed phase.
Unknown observations remain omitted. Bounded failure diagnostics cannot become
a successful installation or template-readiness receipt. Root staging, boot,
receipt collection, installed-checkpoint publication and native qualification
still require their separate orchestration and physical evidence.

`AccountlessInstallationStagingJournal` and `AccountlessOfflineOverlay` implement
the recoverable file-copy phase for the privileged operator. The journal lives
in an operator-owned private directory and retains a stable exclusive lock.
Its immutable `staging-intent.json` binds the entire raw candidate and generated
payload plan before any guest-file writes. `staged.json` references that intent;
neither file means installed, detached, stopped or qualified. An existing
`boot-intent.json`, installation result or cleanup state closes staging, even
when incomplete. Conflicting, orphaned, linked or shared records are rejected.

The overlay accepts only the producer's ten fixed files and fixed attempt paths.
It walks descriptors without following links or crossing a filesystem, rejects
unexpected partial contents, preserves matching files and signing xattrs, and
publishes each missing file without overwrite. It checks the copied signed
release before publishing the temporary LaunchDaemon last. A matching interrupted
copy can resume before any boot attempt; staging is never an installer retry.
Once `staged.json` exists, missing files are a conflict and are never recreated.
Unrelated guest paths and existing parent permissions are preserved.

These helpers do not acquire machine/native image authority, choose a device,
attach or mount an image, prove the Data-volume UUID, or boot the guest. The
enclosing privileged operator must perform those checks and retain their guards
around the whole operation. It must generate the payload from the protected
signed package, use a protected journal, and capture stopped/detached disk
identity before handing control to the GUI installer job. A staged record alone
does not grant boot authority. Tests use private directory fixtures, including
real ad-hoc signature preservation; production still requires Developer ID.

`LumeRootBaseImageGuard` supplies the root operator's machine and source lock
scope. It rejects nonroot callers before accessing system authority, acquires
the existing machine EX inode, and binds an explicit nonroot source owner. Its
filesystem reader neither adopts directories nor relaxes ordinary runtime IO.
It compares the exact reserved-candidate bytes, decodes raw Apple ownership
through the normal ownership schema, and verifies resources and the disk
snapshot. Prepared artifacts, partial native provisioning/resize state,
replaced paths, shared permissions and linked files are rejected.

The scope holds the existing base-preparation and broker operation locks, then
native resize/config flocks and the process-owner POSIX record lock. Missing
native guard inodes are created exclusively for the selected source owner;
existing inodes are never replaced. Revalidation uses descriptor metadata and
does not reopen the process-owner lock file: closing a second descriptor for
that inode would release the process's POSIX lock. The source/image descriptors
are closed before machine EX is released. A strict unchanged-snapshot check is
separate from collecting a new snapshot after authorized offline IO; neither is
a disk-content hash or native stopped-state proof.

`AccountlessStagingMaintenance` and `AccountlessCollectionMaintenance` connect
this scope to the guarded image transaction. They prove native stopped state,
exclude foreign image openers, bind hdiutil attachment and the sole APFS Data
volume, preserve preexisting attachments and verify detach. Only the exact
retained image descriptor is excluded from the opener check.

The root scope publishes a durable global intent followed by a per-image fence
before offline IO. The shared machine library blocks ordinary inference SH and
sandbox EX admission while maintenance remains pending, including after abrupt
process exit. The broker and pinned native runtime reject any per-image
`.darkbloom-offline.json` entry under their image guards. Ordinary create/start/
delete, clone-source validation, native settings, forced pull and alternate
storage attachment paths cannot bypass or remove it. Read-only native inspection
leaves the fence intact.

Recovery requires the same immutable journal and source identity. The system
worker retains exclusive authority while a mutating system tool is still live.
Completion requires attachment absence, no foreign image opener and a final disk
snapshot; it removes the image fence before the global fence. Collection has its
own post-boot scope bound to the exact consumed boot claim. It cannot reopen the
pre-boot staging transaction. Component fixtures exercise these filesystem and
process boundaries; fresh Apple restore through final qualification still requires
its own physical acceptance evidence.

Existing schema1 installation and template records retain their legacy
`bootstrapRetired` field and encoding. They are never converted into native
qualification. Normal clone validation rejects a schema1 template when its
actual ownership source is `apple_restore`.

Schema2 separates three states:

| Record | Meaning | Evidence required |
|---|---|---|
| `SandboxAccountlessInstallationReceipt`, `rootJobStarted` | The root job started on its bound raw Apple base. | Correct source, method, policy, identities, virtualized-root observation and bounded guest metadata. Unavailable installer results remain omitted. |
| Same receipt, `installationComplete` | The signed existing installer completed and its installed guest payload was checked. | `firstBootRootJob`, `neverProvisioned`, verified signed installer, exit0, verified installed payload, absent bootstrap account and verified tenant identity. |
| `SandboxGuestTemplateReceipt`, schema2 | The installed base passed native qualification and the disposable work was cleaned up. | Complete installation, all native checks, matching source and payload, versioned qualification and complete cleanup. |

Accountless records do not encode `bootstrapRetired`, including false or null.
Their `neverProvisioned` policy requires raw Apple ownership plus root installer
evidence. An absent account alone cannot establish it. Unknown versions/methods,
mixed formats and partial records fail readiness validation; decoding and
re-encoding malformed evidence cannot make it valid.

`SandboxGuestBaseSource` binds the base name, installation UUID, source kind,
source reference and SHA256 of the exact private ownership-marker bytes. That
digest includes resource/provenance commitments; it is not a hash of the VM disk.
`LumeGuestTemplateSource.load` validates existing ownership using descriptors.
It never adopts a raw folder. The preparer must retain the source operation lock
through qualification and recheck unchanged source identity and stopped state
before publication.

`SandboxGuestPayloadIdentity` binds the four guest hashes and original signed
release-manifest digest. Qualification repeats the exact installation payload
identity. Normal readiness compares all four guest hashes with the currently
verified signed manifest, so a host-only upgrade can reuse identical signed
guest bytes while retaining original installation provenance.

Native qualification version1 uses profile `isolated-v1`. It binds a fresh
qualification UUID, distinct clone name/installation UUID, original source and
payload, and observations through the authenticated native channel: guest
authentication, numeric tenant identity, command execution, workspace roundtrip,
protected-path denial, control-disk denial and restart.

Cleanup binds the clone installation UUID and matching material instance UUID.
Clone removal, material removal, capacity release, source stopped proof and
unchanged-source proof must all complete. Missing or mismatched cleanup prevents
publication even when guest commands passed.

`BaseGuestTemplateStore.publishAccountless` validates source, current guest hashes
and the evidence graph before exclusive publication. Its legacy `publish` path
refuses schema2. Existing receipts are not overwritten.
`LumeGuestTemplate.requireReady` applies the same schema/source/qualification
rules before normal cloning. These types add no consumer option, readiness
bypass flag, or qualification-source exception.

## Candidate reservation

`AccountlessBaseCandidatePreparer` accepts an injected base runtime and an
already verified `BaseGuestRelease`. It requires `.appleRestore` and matching
runtime/storage configuration, calls the existing OS restore operation, then
holds the base preparation lock and normal per-VM broker operation lock while
checking stopped state, ownership, resources and the raw disk snapshot.

The exclusively published `.darkbloom-accountless-candidate.json` uses schema1
with phase `awaitingRootInstallation`, fresh candidate/bootstrap-attempt UUIDs,
source ownership digest, exact guest hashes and manifest, requested resources,
and disk device/inode/size plus modification/change timestamps. Its `installed`
and `qualified` fields are both false. It is not a template or an authorization
to rerun an installer.

A replay returns the same IDs and unchanged record only while the source,
release, resources, stopped image snapshot and phase still match. An existing VM
without a candidate record is quarantined, even when it has valid ownership:
it could be an interrupted first attempt or have booted since restoration.
Malformed/later-phase records, changed disks, ready receipts and existing guest
materials are retained and rejected. Cancellation after restore likewise leaves
the unclaimed image for explicit operator inspection.

This preparer does not mount the image, install the guest agent, start the
restored guest, qualify a clone or publish readiness. Managed raw restore retains
exclusive ownership in the native installer process; its signed-runtime
requirements are in `RELEASE_VALIDATION.md`.

## Accountless operator commands

`darkbloom-sandboxd prepare-accountless-base` exposes eight explicit phases. Every
phase requires `--storage DIR --name NAME --host-id UUID --host-identity-file FILE`.
The identity file is the protected selected-user binding from host preparation.
`--json` returns the observed phase and candidate/attempt IDs. Only
`publish-installed` returns `installed: true`; all phases return `qualified: false`.
An installed image still requires native qualification before ordinary cloning.

| Phase | Execution context | Additional options | Completed result |
|---|---|---|---|
| `reserve` | Selected user's actual GUI/audit session | `--lume PATH --ipsw FILE --guest-release DIR`, optional `--cpu N --memory-gib N` | Raw Apple restore and immutable `awaitingRootInstallation` candidate; 100 GiB boot disk |
| `payload` | Root | `--guest-release DIR --output NEW_DIR` | Verified signed overlay and `plan.json`; no disk attachment |
| `stage` | Root | `--lume PATH --payload DIR --journal-dir DIR` | Guarded mount/stage/detach and `payloadStaged` observation |
| `authorize-boot` | Root | `--lume PATH --payload DIR --journal-dir DIR --boot-journal-dir DIR --permit-file FILE` | Private boot intent, permanently closed staging, then immutable root boot permit |
| `boot` | Selected user's actual GUI/audit session | `--permit-file FILE` | One installer attempt stopped, or an existing consumed attempt recovered; no installation-success claim |
| `collect` | Root | `--permit-file FILE --boot-journal-dir DIR --collection-dir DIR --collection-file FILE` | Complete guest receipt, verified installed payload, temporary material removed, detached/stopped proof, immutable root collection record |
| `abort-collection` | Root | `--permit-file FILE --boot-journal-dir DIR --collection-dir DIR` | Settle owned attachments and close collection without an installation claim |
| `publish-installed` | Selected user's actual GUI/audit session | `--permit-file FILE --collection-file FILE --guest-release DIR` | Validated private installed checkpoint; `installedAwaitingQualification` |

`reserve` verifies the selected identity, actual GUI session, eligible host,
encrypted APFS storage and exclusive machine ownership. It uses raw Apple restore
without an unattended account preset and monitors session loss through creation.
Run it through the selected GUI LaunchAgent; changing UID in an SSH process does
not establish this context. Production runtime and guest signatures are required;
these commands expose no development bypass.

`payload` requires a new directory under an existing root-private parent. Partial
materialization is retained on failure; use a new output directory after reviewing
that failure. It cannot overwrite an earlier payload. `stage` requires encrypted
APFS source storage and a root-private journal directory. It rechecks the exact
source reservation and payload plan. Incomplete staging automatically recovers
only the matching durable maintenance intent. Other operations remain fenced.

A repeated `stage` after completion acquires fresh ordinary exclusive ownership,
checks that both fences are absent, binds the exact saved completion to the
original source/directory and final disk snapshot, verifies native stopped state
and observes no attachment or foreign image opener. It never reopens staging IO.
If fence removal itself was interrupted, it completes the original transaction
before performing this independent verification. A later boot closes the staging
journal permanently and requires a separate result-collection journal.

`authorize-boot` requires a different private boot-journal directory. The permit
file's parent must already exist, with root-owned ancestors that allow traversal
but no group/world writes or ACLs. The permit is root-owned mode0444, bounded and
contains no credential. It binds the selected host/user, exact raw reservation,
staged disk snapshot, staging evidence digest, native executable hash and300s
boot bound. Publication order is private boot intent, staging handoff record,
then public permit. Matching interruption prefixes can complete; conflicting
records cannot overwrite earlier intent. An already published permit is replayed
without claiming that the source still has its pre-boot contents.

`boot` validates the root permit, selected real/effective user and GUI/audit
session, encrypted storage, host eligibility, machine EX and exact production
runtime. It rechecks source ownership/resources and the staged snapshot, then
publishes `.darkbloom-installer-boot.json` in the VM directory before native spawn.
That claim is never removed or reused. Native runs `installer-v1` with BLC and
inherited EX; no SSH readiness, control/workspace disks or network are involved.
The owner waits for native exit within300s and independently proves stopped state.
Cancellation/session loss still awaits stop cleanup. The session supervisor drains
both tasks and propagates an operation/cleanup failure even when session loss
arrived first; a logout error cannot hide unproven cleanup. A replay only stops/observes
the same claimed attempt; even a crash before spawn does not authorize another
boot. A different permit cannot replace it. Claimed sources also reject ordinary
base start, new raw-candidate reservation and pre-boot root staging.

`installerBootStopped` means the native owner exited successfully and the source
is stopped. `installerAttemptRecovered` means a prior claim was found and stopped
state was verified; its original native exit code is unavailable. Neither proves
the guest installer succeeded. The collection and installed-publication commands
are implemented; physical validation of this complete path and automatic native
qualification remain required. The legacy `prepare-base` entrypoint retains its
unattended path; these phases do not silently fall back to it.

`collect` requires a root-private journal separate from the boot journal. It
validates the exact consumed boot claim and pinned runtime, observes stopped
state, and captures the post-boot disk under machine and native source locks.
Its separate durable maintenance intent closes ordinary runtime admission until
matching cleanup completes. It uses the same guarded attach, sole-Data-volume
selection, private mount and detach transaction as staging.

Before deleting anything, collection verifies the installed guest binary and
Developer ID signature, bootstrap script, persistent job and synthetic workspace
entry against the signed release. A complete bound guest result and bounded logs
are copied to the private host journal. An immutable removal plan then records
the exact temporary files, directories and APFS volume UUID. File hashes, inodes,
sizes, timestamps and modes remain binding across retries. Device numbers may
change on reattachment; descriptor-relative IO still requires every entry to be
on the currently verified volume. Another volume UUID, replacement, symlink,
extra file or changed remaining payload stops removal without deleting that data.

The temporary boot job is removed first, then the recorded payload. A retry uses
the saved host result even if the guest receipt was already removed. Successful
removal and verified detach are separate checkpoints. Only after both and a
fresh stopped/detached observation does root publish the bounded, root-owned
mode0444 collection record. That public record contains installation and cleanup
bindings, not diagnostic logs. An incomplete receipt cannot authorize deletion.

`abort-collection` settles only the journal's owned attachments and verifies
cleanup without mounting the Data volume for payload IO. It records an aborted
transaction and cannot publish installation evidence. An already completed
transaction cannot reopen collection IO, even when replayed through another phase.
Failed or uncertain cleanup retains the maintenance fences.

`publish-installed` validates the root permit and collection record in the exact
selected GUI session. It rechecks encrypted storage, exclusive ownership, the
pinned production runtime, consumed boot claim, signed guest release and final
disk snapshot before publishing private installed evidence. It never boots the
base or publishes template readiness.

## Installed-candidate validation

`LumeInstalledCandidateCheckpoint` defines immutable host evidence for the next
phase, `installedAwaitingQualification`. The installed-publication command
produces these private files in the already-owned source VM directory:

| File | Binding |
|---|---|
| `.darkbloom-accountless-candidate.json` | Existing immutable raw reservation, including candidate/bootstrap-attempt IDs, source, payload, resources and original disk identity. |
| `.darkbloom-accountless-installation.json` | Complete schema2 `SandboxAccountlessInstallationReceipt`; its `rootJobID` equals the reservation's bootstrap-attempt ID. |
| `.darkbloom-accountless-cleanup.json` | Schema1 `LumeCandidateInstallationCleanup`; same source/attempt, exact installation-receipt digest, post-cleanup disk snapshot, temporary job/payload removed, detached and source stopped. |
| `.darkbloom-accountless-installed.json` | Schema1 installed checkpoint; exact hashes of the three preceding files and the current post-installation, post-cleanup disk snapshot. |

The package-only `publishInstalledCandidate` base-runtime operation publishes
these records after validating complete installation/cleanup inputs. It requires
exclusive host ownership, checks the actual stopped source against its ownership
and the reserved resources, validates the signed guest payload, and binds the
current disk snapshot. Input JSON must be bounded and contain no duplicate keys.
Matching partial files can be completed after interruption; conflicting, linked,
shared or special files are rejected without overwrite. The installed checkpoint
is published last, then all records and the stopped source are checked again.

The root collection command supplies the verified receipt and cleanup handoff to
this entrypoint. Decoding input records does not observe those actions. The raw
reservation remains immutable; its original disk
device/inode/size must match the final disk, while the installed checkpoint binds
the later modification/change times. Neither publication nor replay starts a VM
or publishes template readiness.

`LumeInstalledCandidateStore` reads at most 16 KiB per evidence file through
private, stable, named descriptors. It rechecks storage/directory identity,
all evidence digests, complete receipt semantics, exact source ownership,
current disk identity and signed guest compatibility. A ready-template receipt
or source `.darkbloom-guest` material is rejected. Partial, legacy, mixed,
unknown-version, shared, linked or changed evidence cannot authorize a candidate.

The package-only `qualificationCloneCapability` validator additionally requires
exclusive machine authority, an isolated-guest runtime, the matching real capacity
arbiter, an active dedicated-host lease, exact destination/resources/scope/expiry,
stopped source observation and resource agreement with its ownership record. It
retains the normal source operation lock and binds the capability to its issuing
runtime. Revalidation rejects changed files, disk, runtime, lease or source.
The capability has no public constructor or Codable conformance.

The package-only `createQualificationClone` consumes the capability once, inside
the existing destination operation and lease-mutation locks. It retains the source
lock without reacquiring it, rechecks source evidence and the exact active lease
before and after native cloning, and writes the ordinary fresh lease ownership
record only after the stopped clone and its resources are verified. Native
failure, cancellation or a failed postcondition uses the shared creation cleanup;
the source and capacity reservation remain intact. A consumed capability cannot
recreate a subsequently removed destination.

After successful native creation and ownership publication, the capability binds
the new clone installation UUID. `observeQualificationClone` requires that exact
created clone, a running native observation, the unchanged source, active lease
and matching private guest materials. It returns an opaque
`LumeQualificationCloneObservation` containing the observed clone/material IDs.
Callers cannot construct or decode that object. It contains no guest credential
and does not assert that native guest qualification checks passed.

`verifyQualificationCleanup` uses that observation after teardown. It requires a
durable deletion receipt for the exact lease generation and clone name, an equal
or newer released fencing token, no native VM, no remaining clone directory or
material tree, and no pending deletion intent. It independently rechecks the
stopped source, installed evidence, resource commitments and signed release while
retaining the source lock. Source integrity validation is separate from active
lease admission so a valid deletion can be verified after release. Generic lease
removal, expiration or VM absence alone cannot prove cleanup. This read-only
operation returns matching cleanup evidence and never publishes readiness.

The observation belongs to its issuing runtime and cannot be recovered by
decoding a journal. A future durable qualification owner must define interrupted
attempt recovery and preserve original clone identity; it must not manufacture
an observation or promote saved success booleans after a process restart.

`runNativeQualification` runs the native check sequence only for that runtime's
live managed VM owner, private endpoint and matching material instance. A
capability permits one sequence; failure requires cleanup and a new attempt.
The signed guest executable now includes `qualify-tenant`, an unprivileged probe
that requires virtualized UID/GID2001, only tenant supplementary groups, absent
numeric account records and inability to restore UID0. It requires explicit
EACCES/EPERM when opening the fixed root configuration, control configuration,
guest executable for writing and all observed disk/rdisk devices. ENOENT and other
I/O failures cannot satisfy this check. It also rejects non-loopback IP addresses.
The probe writes no file, reads no credential and adds no privileged RPC method.

The host requires the exact versioned probe response through normal authenticated
execution, records the kernel boot-session UUID, uploads and reads back a marker
bound to the qualification and clone IDs, then stops and starts the clone. It
requires a different boot UUID, reruns the probe and reads the exact marker again.
Command IDs are deterministic per attempt/clone/step and differ before and after
restart, preventing the durable command journal from replaying an old boot ID.
Every upload acknowledgment and downloaded size/hash/revision is checked. A
revision may change on remount; persisted content is compared by bytes and hash.

Success returns an opaque `LumeNativeQualificationResult`. After normal teardown,
`withVerifiedQualificationReceipt` verifies durable cleanup and invokes the
publication callback while explicitly retaining the result, source lock and
machine authority. It then reads back the exact receipt, applies ordinary clone
readiness validation, and rechecks source ownership, stopped resources, disk
snapshot and deleted clone. It exposes no ready receipt to publish after releasing
those guards. The durable attempt journal and public qualification command still
need integration, and this sequence requires fresh real-VM acceptance. Existing
guest bundles lack the new probe: rebuild/sign the guest release and prepare a
matching base before running it.

No template is published and no reservation is added or extended by this path.
Ordinary `create` still requires `LumeGuestTemplate.requireReady`; there is no
public bypass flag. Qualification clones use the existing encrypted-storage,
guest-material and native-start gates when started. The enclosing base factory
must still persist attempt/recovery state, run the actual native checks and
complete cleanup before publishing readiness. Unit fixtures use real locks and
APFS clones to exercise these transitions; they are not physical qualification.
