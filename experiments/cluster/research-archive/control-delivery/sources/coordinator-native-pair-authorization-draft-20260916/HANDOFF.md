# Coordinator native-pair authorization B — private source candidate

This increment connects explicit native-runtime approval to the real verified-pair
registry and the real provider WebSocket read loop. It is source-only: no compiler,
CPU fixtures, model, native child, remote operation, deployment or MAIN mutation
was performed. The default coordinator has no approval catalog and cannot start
this path. Member/native invocation and production enablement remain separate.

## Exact bases

- MAIN contains the qualified V2 verified-pair registry (frozen source manifest
  `22022f178730d3e80c11e9e18329dd9ff86039c7f21e28c5ab52e552237f0e6f`).
- Apply frozen registered-member source first: manifest
  `4ae431c60990ff9e4dfe319b8b5387ac8fb6bffcd54eac0213d3f85ed60ef965`.
  Four B replacement preimages are from that member overlay; Server and
  ServerConfig preimages are current MAIN. `integration.json` records both the
  effective preimage and current MAIN digest for every replacement/addition.
- Native public-byte format matches the actual qualified A source at
  `cluster-native-key-prelude-validation-3-20260916/source`, manifest
  `61f28887e6165c6f488071882868216c6e92bb1f1f6f81cec826c7de0349c5bf`.
  A's original source and both failed runs remain untouched. B does not modify A.
- The public fixture extracts only common/start/hello/binding/public-key bytes
  from A's actual independent OpenSSL vector. It deliberately does not copy its
  fixture private keys, shared secret, confirmation key or record master.

## Implemented path

`NewNativeRuntimeCatalog` accepts explicit trusted coordinator startup policy and
owns defensive copies. Nil/empty disables the path; there is no provider upsert,
environment switch, self-approved hash or model-capability alias. The immutable
approval binds exact model, native binary, metallib/resource library, artifact,
Plan, capability, profile, resource policy, schedule, hardware names, AEAD framing
and cumulative limits, policy generation and absolute expiration. Its canonical
public policy bytes are hashed as the approved native binding. Revocation is
one-way for that running coordinator.

`ServerConfig.NativePairCatalog` constructs a coordinator tied to the real
Registry. The current member role ACK still proves protocol support only. After
that registration, the actual read loop attaches its exact Provider pointer and
immutable registration nonce, requiring a completed **actual** `r.TLS` handshake.
An arbitrary `X-Forwarded-Proto` header is not accepted as TLS evidence. The
existing attestation/challenge/heartbeat loops continue. Reserve, Commit and each
active operation recheck the real current hardware/release/routability gates.

`Server.BeginNativePair` is an explicit in-process coordinator selector hook,
not a public HTTP or member request that can select arbitrary peer IDs. It uses
exact registered connection objects, the reviewed approval ID and a bounded
lifetime. The existing Registry atomically reserves both physical devices.
Entropy acquisition and Registry reservation run outside the new coordinator
mutex; on return the exact connection objects, current approval and remaining
preparation budget are rechecked before publishing even a pending result.

The coordinator sends a prepare envelope containing its canonical public policy
and rank-specific A start bytes. A signed `native_pair_prepared` must echo those
exact start bytes. Its meaning is that the attested member has verified the
approved files and prepared the canonical device gate; **this member-side work
is not implemented by B**. Empty slots are not a substitute. Only after both
receipts does B call the real `CommitVerifiedPairOwners`. Only after that call
succeeds are `native_pair_owner_start` frames created. Partial delivery after
Commit therefore retains the existing uncertain active ownership.

A hello must repeat the exact approved start and canonical X25519 public key.
Both signed member hellos form exactly A's `DBNB` transcript. Each 32-byte signed
confirmation is relayed to the other member. The coordinator does not possess
the private/shared key and **does not claim to have verified the MAC**; that is
the child's job in A. There is no nativeReady, load, mesh or inference enablement
in B. All messages carry fixed membership epoch/generation, original connection
nonce and monotonic connection sequence. Signatures use the already bound SE
P-256 key and a domain-separated canonical byte encoding; strict DER verification
rejects trailing data. Public data is not logged by these handlers.

## Cancellation, bounds and ownership

Each session owns exactly two public writer tasks plus one Done observer. Each
rank retains at most 16 encoded frames including its in-flight frame, at most
1 MiB total, plus one separate small cancellation record. There are at most 64
native sessions including quarantine. No unbounded per-message tasks or queues
are added. Writes use the existing priority provider writer and an absolute
membership deadline capped at five seconds per control write. The codec limits
in the policy remain separate from RDMA message admission; B sends no RDMA.

Cancellation first ends real Registry admission, queues a separate small priority
cancel, then interrupts the public worker context. If a real write was already
in flight, the existing writer may close the socket to interrupt it. This is a
stop signal, never cleanup evidence. Public workers are joined and their queued
buffers reclaimed. `WaitControlStopped` describes only those two workers.

Inbound sequences are strict and never reset on a new grant. A terminal outbound
cancel can skip unsent lower sequence frames; the future member consumer must
accept a higher sequence **only for a terminal cancel bound to that exact grant**
and permanently stop that grant. It must not treat such a gap as a new start.
Ordinary outgoing records retain FIFO order; new sessions wait for old public
workers to end, and the existing priority queue orders the old cancel before a
new prepare. Sequence exhaustion closes the attachment instead of wrapping.

Pending cancellation releases through the real Registry because no owner start
was committed. Active cancellation, expiry, failed delivery, reconnect, approval
revocation or failed key establishment keeps physical devices quarantined. Only
the original still-authenticated connection can submit the exact `DBNR` receipt:
native cleanup, actual authenticated owner lease-release ACK and actual owner
transport completion. False/missing flags, replay, copied identity, replacement
connection, timer or public-worker drain cannot erase the hold. B records these
member observations; it cannot independently inspect remote native memory.

Preparation and membership expiration are the original Registry values and are
not refreshed by start/hello/confirmation. Their wire timestamps are binding
information, not permission to create a fresh local timeout. This slice has no
user inference request or TTFT origin. The later invocation layer must retain
its original local monotonic preparation/request deadlines, never restart a
request budget at nativeReady and never subtract another host's uptime from its
own clock. Coordinator expiry remains authoritative for its admission.

## Required next boundaries

1. Qualify and integrate the frozen registered-member mode, then implement its
   approved-file identity hold, canonical gate preparation, signed receipts,
   real owned child prelude and cleanup observations. Never synthesize a receipt.
2. Add the trusted coordinator selection/caller-authorization policy that invokes
   `BeginNativePair`. No broad public start route was added to approximate it.
3. Supply a reviewed explicit catalog and production ingress trust. Current
   reverse-proxy TLS deployment is not authenticated by `r.TLS`; this candidate
   refuses that opt-in attachment until explicit trusted proxy wiring exists.
4. Preserve the existing 27B M5/NAX model gate. A later approved non-NAX native
   adapter needs its own explicit compatible arithmetic/runtime/hardware policy;
   B does not fake a capability or rename a model. 9B remains the first target.
5. Connect A to the protected Collective and real native readiness/load/request
   path, including native tail initialization, admitted sealed buffers and byte
   budgets. A public grant alone is never native-runtime approval or encrypted
   RDMA qualification. No plaintext fallback is introduced.

## Staged checks and intended execution

There are 15 new Go methods (11 Registry, 2 protocol, 2 API) plus 2 Swift methods.
The Registry cases use the existing full attested fixture and real WebSocket
writers. They cover no self-approval/solo attachment, Commit-before-start, exact
public binding, cancellation with actual bilateral release, false cleanup,
replay, early hello, revocation, reconnect substitution, bounded relay and joined
writers, concurrent revoke/Commit, wrong nonce/key/connection and fixed expiry.
API cases enter the actual read loop for an unregistered native frame and test a
real local TLS handshake against a forged forwarded-proto header. These are
unexecuted source fixtures, not evidence of installed member or native behavior.

After root grants a compiler slot, prepare a new isolated copy using the existing
registered-member validation wrapper's complete source/fixture closure, apply the
frozen member overlay and then B with **all** `integration.json` preimages checked
before any replacement. Retain a new complete source inventory after applying B.
Do not reuse the old wrapper inventory as though the B files were already pinned.
No MAIN mutation or native/MLX build is required for the Go checks.

Use the locked offline Go 1.25 toolchain with existing cached modules, `GOMAXPROCS=2`
and the existing unreaped-process-only owned runner. Focused command from the
isolated `coordinator` directory:

```sh
go test -race -count=1 -p 2 -parallel 2 -timeout 120s ./protocol ./registry ./api -run 'TestNativePair|TestVerifiedPair|TestMemberRole|TestClusterMember'
```

After focused PASS, run all three packages with the previously approved 180-second
package timeout, 300-second parent bound and 16 MiB retained Go diagnostics.
Preserve the five cross-repository fixture inputs already enumerated by
`cluster-registered-member-validation-fixtures-20260916` (`0550d8fb...2be06`).
For the Provider workspace, add the two B Swift files to the corresponding exact
member source snapshot, retain the ordinary anonymous metallib binder, then run
`swift test --jobs 2 --filter NativePairMessageTests` plus the member/legacy
selection already specified in that wrapper. Runtime execution is not authorized
by this handoff; no fixture has been run in B yet.

New runtime files are 22–200 lines and separated by policy, connection binding,
reservation, relay, handlers and public byte codecs. Existing-file diffs contain
only the six necessary registration/config/dispatch hooks. Independent B source
review and compiler qualification remain pending.
