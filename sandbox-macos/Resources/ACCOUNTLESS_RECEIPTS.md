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
restored guest, qualify a clone or publish readiness. A later orchestrator must
persist a one-shot phase transition before offline writes, acquire the native
image guards, and perform the installation/qualification protocol. No accountless
CLI is exposed; the legacy `prepare-base` entrypoint is unchanged. Managed raw
restore now retains exclusive ownership in the native installer process; its
signed-runtime requirements are in `RELEASE_VALIDATION.md`.

## Installed-candidate validation

`LumeInstalledCandidateCheckpoint` defines immutable host evidence for the next
phase, `installedAwaitingQualification`. A future root-installation orchestrator
must produce these private files in the already-owned source VM directory:

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

The privileged staging, boot, collection and cleanup orchestration remains to be
wired into this entrypoint. Constructing or decoding input records does not
observe those actions. The raw reservation remains immutable; its original disk
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

No template is published and no reservation is added or extended by this path.
Ordinary `create` still requires `LumeGuestTemplate.requireReady`; there is no
public bypass flag. Qualification clones use the existing encrypted-storage,
guest-material and native-start gates when started. The enclosing base factory
must still persist attempt/recovery state, run the actual native checks and
complete cleanup before publishing readiness. Unit fixtures use real locks and
APFS clones to exercise these transitions; they are not physical qualification.
