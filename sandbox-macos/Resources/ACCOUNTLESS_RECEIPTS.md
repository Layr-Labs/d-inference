# Accountless installation and template evidence

These types and validators describe stored evidence. They do not perform an
Apple restore, root installation, native qualification or cleanup. A preparer
must observe each step before publishing its result; constructing a Swift value
is not proof that the physical step ran.

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
image guards, and perform the installation/qualification protocol. No new CLI
is exposed until raw-restore process ownership and crash lifetime are enforced;
the legacy `prepare-base` entrypoint is unchanged.
