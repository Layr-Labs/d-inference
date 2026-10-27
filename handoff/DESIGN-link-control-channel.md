# Link control channel (S06): an authenticated, encrypted TCP session per link edge

Status: built; unit, two-process loopback and cable checks pass on today's link
(link setup v2 not applied). Not wired to coordinator serving: S08-S10 build the
follower endpoint and the pair slot on top of it.
Code: `libs/darkbloom-cluster/Sources/DarkbloomClusterRemote/ClusterLinkControl*.swift`,
`ClusterLinkInterfacePolicy.swift`, `DarkbloomClusterSecurity/ClusterLinkControlKey.swift`,
`provider-swift/Sources/ProviderCore/Inference/Distributed/LinkControl/ClusterLinkControlHost.swift`.

## Why

Production has no SSH (owner decision 5). The members of a cluster need a
control path for leases, request reserve/start metadata (with prompt token
IDs, so it must be encrypted), rank events, small decisions, cancel/stop votes,
barriers and agreements, and status mirrored to the head. The owner's oMLX
lesson is that nothing control-like goes over RDMA (tiny reductions gave
corrupt headers and lost completions; RDMA heartbeats during a long prefill
tripped the guard). macOS ties firewall and Local Network approval to the
binary that listens, so the listener lives in the provider process and the
owner approves the signed provider once.

Ported in concept from the owner's `omlx/cluster/control_plane.py` (persistent
socket per rank, mutual HMAC handshake `OC2C/OC2H/OC2A`, per-frame sequence and
authentication, `OC2B` small decisions, `OC2R` barrier) with the survey's
changes: Codable instead of pickle, the secret never on a command line, keys
from the native key derivation, and frames encrypted, not only authenticated.

## Shape: edges, for two Macs and for N

- The unit is one **edge**: two members over one cable, with an edge ID, an
  epoch and an edge key. `ClusterLinkControlEdge.derivedEdgeID` derives the ID
  from the sorted (member pin, interface) pairs (NMAC 2.2).
- One end listens (`ClusterLinkControlListener`), the other dials
  (`ClusterLinkControlClient`). A listener binds one interface address and can
  host several edges: the head of an N-member cluster runs one listener per
  link interface, and each member dials the head over its direct edge (NMAC
  N16's control star). One live session per edge; a newly authenticated
  session supersedes the old one, unauthenticated input never touches it.
- Both ends of an edge share a reliable message stream that outlives TCP
  connections (`ClusterLinkControlPeer`).

## Keys

- `ClusterLinkControlKey.nativeDerived`: the native X25519 agreement of
  `ClusterNativeKeyDerivation.swift` (canonical public key, all-zero secret
  refused, HKDF-SHA256 salted with the 32-byte transcript digest) under a new
  label `darkbloom/native-link-control/master/v1`, so it is independent of the
  RDMA record master and the confirmation key. Who runs that exchange in the
  provider (the coordinator-relayed hellos, or later the S17 pairing pins) is
  S10/S16/S17 work; this slice provides the derivation and its tests.
- `ClusterLinkControlKey.qualification`: local qualification only; a random
  secret of 32+ bytes read as one hex line from standard input or a pipe, bound
  to the epoch and the edge by HKDF.
- The key value never leaves the security module: callers get handshake tags,
  constant-time verification and per-connection directional keys.

## Handshake (fixed-size, before anything else)

```
listener  -> CHALLENGE "DBLC" v | nonce(32)                                    40 B
connector -> HELLO     "DBLH" v role | epoch | edge | nonce(32) | incarnation |
                       known listener incarnation | delivered | record limits | tag  164 B
listener  -> ACCEPT    "DBLA" v | incarnation | known connector incarnation |
                       delivered | tag                                          80 B
```

The connector's tag covers the listener's fresh nonce (a replayed hello
fails); the listener's tag covers all three records (a replayed accept fails).
The listener refuses, before the tag check, an unknown edge, another epoch,
different record limits or a source that is not the edge's peer. Session keys:
HKDF from the edge key over the SHA-256 of the three records, the epoch and
the edge, one key per direction. Every pre-authentication read is fixed-size.

## Frames

Each frame is one record of the existing authenticated record codec
(`ClusterAuthenticatedRecordChannel`, AES-256-GCM, new record type
`linkControl`), using two codec instances per connection (one only seals, one
only opens) so reader and writer never contend. Plaintext: version, kind,
message ID, acknowledgement, body. Kinds: heartbeat, ack, ping, pong, goodbye
(per connection) and message (Codable JSON) and opaque (2-byte tag + bytes)
(sequenced). The record layer gives order, replay rejection within a session
and byte/record budgets; before a budget runs out the session says goodbye
(rekey) and the client reconnects with fresh keys immediately.

## Delivery and reconnect

- Sequenced frames are kept until acknowledged and resent, in order, on the
  next session: exactly once and in order while both processes live.
- Each process end is an **incarnation**. If the peer's incarnation changed
  (it restarted), what was queued for the old one is dropped and reported as
  `peerRestarted(droppedUnacknowledged:)`; the application decides what to send
  again.
- The client reconnects with backoff (20 ms doubling to 1 s, jitter), at once
  after a rekey or supersede. Heartbeats every second while idle; a session
  with no frame for 5 s is ended (`peerSilent`). Messages naming an epoch must
  name the edge's epoch, on both ends.

## Admission and bounds (DoS)

- Sources outside the configured peer addresses are closed before a byte is read.
- At most 8 unauthenticated connections; the oldest is evicted for a new one;
  each has 2 s to authenticate (slowloris connections are cut).
- Frame length is checked against the bound (4 MiB body by default, at most
  16 MiB) before anything is allocated.
- The outbox is bounded (4,096 messages, 64 MiB): a full outbox is
  backpressure (`send` waits up to the send timeout, then throws), and a socket
  that does not drain ends the session after the write timeout.
- Events reach the application on one serial queue per edge with at most
  4,096 pending; a slow handler stops that edge's reader (TCP backpressure),
  never memory growth. A reader never blocks on the write lock, so two ends
  with full send buffers still drain each other.

## Interfaces and addressing

`ClusterLinkInterfaceAdmission` admits a Thunderbolt port (IOKit provider
`AppleThunderboltIPPort`) or a bridge whose configured members are all
Thunderbolt ports; Wi-Fi (SystemConfiguration IEEE 802.11), or a bridge with a
Wi-Fi member, is refused under every policy. `thunderboltOrWired` adds wired
Ethernet for NMAC's `tcp-lan` edges; `loopbackForTests` admits only `lo0`.
Sockets are bound to the interface (`IP_BOUND_IF`) and its address, so traffic
cannot leave through Wi-Fi whatever the routes say (169.254/16 routes are
ambiguous on a Mac with Wi-Fi). The local address is the one on the peer's
subnet, else link setup v2's `10.219.0.0/16`, else any ordinary address
(today: Internet Sharing's subnet), link-local last; a peer off that subnet is
refused. `ClusterLinkControlHost.listenInterface(forDevice:)` picks the port
when it carries IPv4 (v2, per-edge /30 later) or the Thunderbolt Bridge
holding it (today's Mac B).

## In the provider

`ClusterLinkControlHost` starts and stops the listener inside the provider.
The hidden `darkbloom cluster link-channel listen|probe` command runs
qualification through it (secret on standard input). Not wired: member
startup, coordinator start, follower endpoint (S08-S10).

## Measured (2026-10-10, today's link, M3 Ultra listener on its Thunderbolt port, M5 Max on its Thunderbolt Bridge)

All four lanes held; Mac A load average about 7 from work outside the lanes.
Evidence: `T/evidence/link-channel-20261010/` (`hw-quoted-*`, `raw-tcp-floor-*`).

| Round trip, 64 B | p50 | p99 |
|---|---|---|
| Ping, back to back, listener Mac A | 98.5 us | 204 us |
| Ping, back to back, listener Mac B | 116 us | 221 us |
| Ping, 0.2 ms apart (A / B listener) | 106 / 132 us | 176 / 256 us |
| Ping, 1 ms apart (A / B) | 345 / 310 us | 935 / 1,087 us |
| Ping, 10 ms apart (A / B) | 609 / 559 us | 1,231 / 1,464 us |
| Typed message echo, back to back (A / B) | 160 / 167 us | 689 / 758 us |
| Raw plaintext TCP (Python), back to back / 1 ms / 10 ms apart | 72 / 276 / 364 us | 191 / 630 / 2,689 us |

1 MiB frames, 1 GiB each way: 3.35-3.65 GB/s.

The p99 < 0.5 ms target holds while the link is busy (back to back or 0.2 ms
apart). With 1 ms or more between messages both the channel and plain TCP
pay the idle wake-up of the Thunderbolt IP path (ICMP 100 ms apart: 0.65 ms
average), so sparse control traffic sees about 0.3-0.6 ms median and 1-1.5 ms
p99. Nothing in v1 sends per-token traffic on this channel (decisions stay on
the data plane and rank 0); leases (5 s), reserve/start and events are far
from that budget. The typed echo's tail is the two event-queue hops per end.

Reconnect on the cable: the Mac A listener killed (SIGKILL) and restarted a
second later — the Mac B client reconnected and reported the restart, outage
1.43 s including the 1 s restart delay; the Mac B client killed and restarted
— the listener reported the restart and a new session; every message sent
afterwards was acknowledged.

## Permissions

The first listener on Mac B (an ad-hoc-signed provider debug build) was
blocked by Mac B's application firewall until the owner answered its prompt
("Allow"); with that rule it passes. Every new ad-hoc build at a path may
prompt again: that is the per-build approval the owner requirement forbids,
and the reason the listener belongs in the signed provider. Mac B allows
downloaded signed software automatically and both installed providers are
Developer ID signed, so a signed release hosting this listener should need no
prompt — not verified (no signed build here). No Local Network denial was seen
on either Mac.

## Checks

```sh
bash libs/darkbloom-cluster/Tests/RemoteChecks/run.sh        # unit tests (XCTest)
bash libs/darkbloom-cluster/Tests/LinkControlChecks/run.sh   # two processes over loopback
```

Unit cases: wrong key, wrong epoch, unknown edge, limits mismatch, replayed
hello, replayed record (inside a session and into a new one), oversize frame
refused before allocation, slowloris cut and real peer admitted, silent peer,
reconnect resumes exactly once in order, listener restart reported, record
budget rollover, backpressure, Wi-Fi refused, today's and v2 and /30
addressing, strict codecs, key derivation and secret from a pipe.
