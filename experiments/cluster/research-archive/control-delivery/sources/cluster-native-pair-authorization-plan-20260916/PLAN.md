# Native pair authorization and child-owned traffic keys

Source proposal, not implementation or qualification. Trusted endpoint Macs;
protection is authenticated encryption in transit plus verified membership.
A peer's owner can inspect that peer's memory. No untrusted-owner blindness,
remote attestation of native MLX by inference, or encrypted-RDMA measurement is
claimed. The member role is frozen separately at manifest 4ae431c6 and still
awaits compilation. The record codec is already tested; the protected facade
4338ce5b still refuses unqualified memory policy.

## Concrete ownership boundary

Each registered member will own the existing configured local worker-owner
endpoint through `ClusterRemoteWorkerEndpoint(localOwner:...)`. This public
constructor already uses the same Process, bounded owner protocol, canonical
journal and actual native cleanup/release acknowledgment as the SSH endpoint.
The coordinator routes bounded control records to the other member; native
activation traffic stays direct RDMA. No new native supervisor, model loader,
request engine or lease resolver is needed. The selected protected path must
refuse an unregistered peer, unavailable coordinator, missing grant or missing
key. It must not fall back to SSH/native TCP/plaintext.

`DistributedInstalledSession` currently stores concrete remote endpoints and
constructs the peer over SSH. Integration needs a small owner-endpoint protocol
that extends the existing WorkerEndpoint with actual owner-release/transport
completion, and a coordinator-backed endpoint view. Keep the existing local
endpoint implementation and original installed nonprotected path separate
until the new authorization and resource gates qualify; never advertise the
old path as encrypted. The member owns the physical local endpoint; the leader
view forwards the existing worker messages and never owns a second native child.

## Authority and approval

The live coordinator connection is the identity boundary. Wire handlers use
the exact registered Provider object and negotiated member nonce, never a
peer-supplied provider ID to select an authority. Existing Reserve/Validate
check current hardware/SE/process key, approved provider release generation,
code freshness, model policy, connection liveness and atomic device holds.
Fresh WSS connectivity proves control routability; it does not prove a working
RDMA path. The first completed protected readiness exchange establishes that
physical data path, independently of subsequent loaded-state readiness.

Add an explicit coordinator-owned native-runtime approval table. Its immutable
entry must bind native executable, native metallib and resource-library hashes,
capability descriptor, adapter/profile, supported transport and schedule,
canonical Plan/artifact commitments, frame and cumulative-byte limits, and the
qualified staging/resource policy. Each entry has a policy generation and
revocation. Provider claims or the current ProposedRuntimeBindingSHA256 are
inputs for comparison, never approval. Absence/mismatch is closed. No arbitrary
runtime hash received on a WebSocket can populate this table.

The existing provider binary attestation does not attest a separately launched
native executable. The approved provider checks its installed native bundle and
holds unchanged file identity through launch using the existing installed
validation; the coordinator compares that exact bundle to its own approved
entry. This is attested-provider observation of a trusted local child, explicitly
not independent hardware attestation of the native process.

Use the existing authenticated WSS channel for coordinator grant delivery,
then the provider's owned local process and PID-authenticated bootstrap socket.
This forms a live, nonportable authorization chain. A public JSON grant copied
from a log is not a valid native constructor argument: native acceptance also
requires the expected parent PID, launch/lease/incarnation, current local grant
state and locally verified native/configuration binding. Do not add a peer-key
or authority-key override. If portable offline grants are desired later, a
separate pinned coordinator signing authority is required; it is not present
in this proposal and must not be invented from the provider's key.

## Ordered transaction

1. Coordinator reserves both actual devices with `ReserveVerifiedPair`. No
   owner/native launch is permitted in pending state. It sends a bounded
   `cluster_pair_prepare` over both exact registered member connections.
   Members verify their saved installed configuration and empty canonical gate,
   complete any old solo teardown, and return preparation observations. The
   member role never clears a live solo gate itself.
2. Coordinator checks native-runtime approval and both exact prepared replies,
   revalidates membership, then calls `CommitVerifiedPairOwners` BEFORE sending
   `cluster_owner_start`. This is the start-authorization linearization point.
   A child that only generates a public key still counts as possibly active.
   Failed/partial delivery now quarantines both device holds; elapsed time or
   key failure cannot free them.
3. Each member launches only its fixed configured owner. The owner records the
   canonical journal before native launch as today. A protected native child
   performs a new bounded authorization prelude BEFORE process/group admission,
   native JACCL bootstrap, model loading or readiness publication. The native
   process generates a fresh X25519 private key with CryptoKit, keeps it private,
   and publishes only its 32-byte public key plus its exact public launch binding.
4. The local member verifies that the hello came through its owned endpoint and
   authenticated child socket, then signs the canonical hello transcript with
   its existing attested SE signer. Coordinator receives it on the exact member
   connection, verifies against the already-bound SE key, current active grant,
   approved native binding, rank and fresh owner/launch identifiers. It accepts
   one hello per rank; identical duplicate messages do not cause a second key
   or state transition, and conflicting duplicates invalidate the grant.
5. Once both hellos are accepted, coordinator emits one immutable
   `cluster_pair_key_binding` containing BOTH public keys and launch bindings,
   original membership transcript and native approval generation. It rechecks
   `ValidateVerifiedPair` before each delivery. Members require exact equality
   with local state and relay the public binding to their own child. The child
   verifies its own key and original expected grant/Plan/rank unchanged. It
   computes a shared secret locally; no secret is returned to the owner.
6. Each child derives a 256-bit record master key and a separate confirmation
   key using HKDF-SHA256 with a canonical transcript salt and distinct domains.
   It publishes a rank-specific HMAC confirmation over the complete transcript.
   Confirmation messages are public, bounded and replay-bound. Both children
   must verify the other's confirmation before creating the protected group.
   Reject malformed/all-zero or failed X25519 agreement, equal peer public
   keys, wrong rank/context and mismatched confirmation. No plaintext fallback.
7. The existing PID-authenticated bootstrap then exchanges native mesh metadata.
   All inference-bearing P2P/readiness/control records subsequently use the
   same record channel and monotonically increasing directional counters.
   Native readiness is published only after protected data-path confirmation,
   actual model load, live charges and existing loaded-state agreement. It is
   independent of protocol ACK, accepted membership and public-key receipt.
8. Cancellation, grant Done/revocation, control loss, key error or request
   expiry closes admissions and invalidates crypto immediately; existing
   owner cancellation/fencing proceeds independently of writer progress.
   Actual native retirement, owner terminal, lease-release ACK and transport
   completion remain separate facts. Coordinator releases physical holds only
   from the original member's authenticated actual cleanup observations.
   Reconnect gets a fresh member connection, grant, epoch and child key. It
   cannot reuse a previous start or clear that previous uncertain active hold.

## Public wire and private memory

New coordinator wire records use a closed version/type allowlist, unknown and
duplicate field rejection, strict canonical lower-case digests/base64, bounded
strings and fixed rank order. They carry a grant ID, member-registration nonce,
registry generation, membership epoch/transcript, approved native-policy ID
and generation, Plan/artifact/profile/schedule/transport, rank, and a monotonic
per-connection message sequence. Owner hello adds owner incarnation, lease ID,
launch ID and native public key. Key binding adds the two full hello records,
SE signatures and canonical transcript digest. Control/release wrappers add
only the already bounded existing worker/owner frame and its exact route.
No prompt/token payload appears in the grant/KDF context or diagnostics.

Native key holders are neither Codable nor publicly descriptive. Never accept
or export a private/shared/traffic key via argv, environment, saved config,
owner/native NDJSON, stderr, an API response or a fixture default. Only local
CryptoKit objects hold secrets. The existing record channel gets the derived
SymmetricKey directly inside the child. Dropping those objects after pending
operations retire is a lifetime guarantee, not a claim of verified memory
zeroization. Avoid logging arbitrary CryptoKit errors or key-bearing objects.

KDF canonical input is length-delimited/versioned and independent of JSON key
order. Salt is SHA256 of the complete accepted membership + approved native
binding + ordered child hellos. Separate info domains are
`darkbloom/native-rdma/record-master/v1` and
`darkbloom/native-rdma/key-confirmation/v1`. Rank-tagged confirmation includes
the full transcript digest and a distinct role domain. Record-master derivation
feeds the existing codec's directional HKDF; it never resets those counters.
An independent cross-language test vector must bind exact canonical bytes,
public keys, shared secret derivation, KDF and both confirmations. Test secrets
exist only in fixtures and never provide a product bypass.

## Reuse of the bootstrap socket

The current BootstrapConnection accepts one verified parent/child PID and
bounds socket IO/cancellation. Reuse that transport for a new explicit
protected profile and prelude; do not reinterpret the existing mesh2 profile's
four gather rounds. Its existing reply is exactly twice the contribution with
local-byte echo, and its sequence ceiling is six: it cannot silently transport
an arbitrary grant. Add a small closed authorization frame codec with fixed
header and a 32 KiB public-packet ceiling, phase checks and original deadline.
After authorization completes, hand the SAME owned connection to the existing
mesh gather sequence with an explicit phase transition. Default mesh2 bytes
and legacy decode remain unchanged. Failed prelude cancels the connection and
requests normal owner cleanup; it never emits native ready/shutdown/released.

## Bounds, deadlines and backpressure

The new coordinator relay must not reuse an unlimited generic SendHandle
queue. Per active rank, at most 16 outstanding control frames and at most 1 MiB
of encoded queued bytes, including JSON/base64 overhead, are admitted. Each
inner record retains WorkerLimits.commandBytes/eventBytes and owner framing
bounds. Reserve queue credits before forwarding and release on completed send;
no IO/callback runs under registry/provider locks. Key/grant phase admits only
one pending packet per rank. Refuse a new request before admission when relay
credits are unavailable. Never drop committed-token/terminal/release events.

Cancellation/revocation is a separate idempotent latch and reserved control
slot, independent of the data queue and model readiness. The existing two-lane
WebSocket writer remains bounded by its watchdog; a failed/stalled writer
triggers cleanup rather than blocking cancellation. Receipt of a queued event
is not proof the downstream writer accepted it. Every asynchronous callback
carries the exact grant state and member connection generation.

All preparation/hello/key exchange consumes the original fixed session
lifetime and preparation budget; no Ready or key message refreshes it. Preserve
the trusted HTTP request origin, actual input-token count and first-visible /
raw-token / generation deadlines. Relay recomputes remaining duration at actual
send and the receiver takes the minimum with its already-bound local ceilings;
remote uptime is never subtracted from a local clock. Such hop-local duration
ceilings never replace the original leader deadline or turn late output into
SLA success. Leader expiry requests out-of-band cancellation immediately.

Charge crypto staging and queued encoded relay bytes before allocation. The
record's 40-byte framing overhead counts toward the transport frame ceiling.
Use one n+40 frame for exact-size hot paths; do not add a length-prefix fence.
Reserve the full worst-case directional transfer envelope against the 4 GiB
counter budget before request admission, including controls and confirmation;
rotate only after actual retirement. Native-tail initialization and qualified
host/device staging remain mandatory independent gates. Current CPU codec
measurements do not qualify those native resource costs.

## Small implementation order and qualification

A. Add the closed public authorization transcript + native-only key holder,
   explicit socket prelude and provider-owned local endpoint hook. Test real
   CPU parent/child PID authentication, byte bounds, cancellation, wrong peer,
   transcript substitution, pre-grant launch refusal and no secret publication.
   No native group or weights are needed for these tests.
B. Wire coordinator approval + exact active-grant handlers and member task into
   the existing registry; add false/restore, duplicate/reconnect/revocation,
   partial-start delivery, queued-cancel and actual-owner-release tests. The
   handler must call the real registry, not a disconnected mirror state machine.
C. Bind the child-produced SymmetricKey to the protected Collective path only
   after both confirmations. Run existing codec/interoperability fixtures and
   old default/mesh bootstrap regression, then scoped native staging/resource
   checks. Real encrypted RDMA and actual recorded cleanup are separate gates.
D. Only after those checks enable the selected protected product mode and run
   matched serial/lookahead, deadline/disconnect and quota-rotation cases. No
   security or speedup claim follows from source or key-exchange fixtures alone.
