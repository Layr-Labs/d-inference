# Automatic configured initiation — private source, 2026-09-20

This successor completes the trigger omitted from the explicit protected local
start slice: both configured member loops publish signed consent on their real
accepted TLS member connections, and rank 0 automatically asks the coordinator
to select the mutually configured pair. There is no test-driver trigger, second
owner, SSH fallback, provider-supplied grant, policy upsert or capacity claim.

A new optional `nativeMember.coordinatorMembership` has schema
`darkbloom_cluster_coordinator_membership_v1` and two ranked `members`, each with
`id` and `signerSHA256`. Both installations must pin the same member labels and
registered signing-key byte commitments. The full saved policy determines the
approval ID and policy digest. These are expectations and explicit user consent;
only the coordinator's preexisting nonempty catalog can authorize that policy.
The local start route refuses missing membership. Legacy members without the
new field keep their original behavior and cannot silently select this route.

The new six-field `native_pair_intent` envelope is mirrored in Swift and Go. Its
canonical payload and dedicated signing domain bind cluster, exact catalog
policy commitment, both member labels/keys, rank, current member nonce and the
same strict per-connection sequence used by all native-pair responses. It has no
grant epoch. Rank 0 is the initiation request; rank 1 is consent. Unknown/null/
duplicate fields, malformed bounds and repeated publication refuse.

The coordinator retains at most 128 bounded intent records on actual attached
connections. It never trusts their signature/key/identity merely because it
stored them. A rank-0 selector waits at most 90 seconds, polling current state at
250 ms while initial registration/trust can complete. Follower consent remains
on its original live connection only until the catalog can no longer cover the
300-second session. Disconnect and coordinator close stop selectors; close
joins them. No device reservation exists until both consents match and the real
Registry verification succeeds.

Selection compares exact current verified member keys and verifies both signed
intents. It invokes the original bilateral atomic reservation, and repeats
consent/current verification after that hold using only that exact pending-hold
exception. Original Prepare, two local preparation ACKs, Commit, native key
establishment, protected Ready, request transport, resources and release rules
remain in charge. Consent cannot start either owner. Both intents are consumed
once the original pending preparation transaction is retained, before its
original writers start. This is distinct from the later Registry Commit.
Cancelled/failed sessions cannot reuse old intent or grant bytes.

The Swift publisher uses the same bounded writer/sequence, retains its task,
checks cancellation after a synchronous signer returns, and joins publication
before the local serving wrapper returns. Native cleanup remains independent of a
blocked signer. A nonpreemptible signer can still hold final control completion;
that uncertainty is retained, never labelled release. Start closes future local
preparation before cancelling its original session and publication.

## Current-master integration requirement

The frozen parent was based on private qualified Provider/Go sources descended
from repository `605651bb`. Upstream `cc225365` adds qualified App Attest serving
leases and verified account/machine identity. Those leases are independent of
legacy MDA/APNs evidence; they must not be translated into fabricated legacy
serial/SE fields. This increment adds no MDM check. It delegates to the existing
`verifiedPairMemberLocked`, which currently still requires the legacy MDA/SE
identity contract. Consequently App Attest-only native-pair admission is **not
yet supported by these source bytes**. The required next successor introduces
explicit identity kinds and binds the actual upstream verified machine,
credential/lease and signing proof while preserving the legacy path. Ordinary
routing eligibility alone is not proof that an arbitrary registration key may
sign native grants.

The exact incoming source context and this limitation are pinned separately.
No configuration absence is treated as permission to bypass catalog, signer,
trust, release or model eligibility. P32/C16/O2, empty stops and all experimental
native resource/serving limits remain unchanged.

## Tests and source scope

Eight Go methods and five Swift methods are staged, unexecuted. They cover the
shared independent canonical vector, malformed/truncated framing, mismatched
signer or membership, absent/revoked catalog, real Registry pending/commit and
quarantine transitions, trust becoming current before reserve, stale original
connections, duplicate sequence, saved mutual consent, and a blocked signer
sharing the original writer. Go Registry fixtures use the existing actual WS
writers and explicitly fabricated trust evidence; they are not hardware proof.

The source has been formatted with gofmt only. No compiler, fixture, model,
remote action, key creation, MAIN mutation or private workspace preparation ran.
Root owns source review and the eventual combined build over current master.
