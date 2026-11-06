# Explicit protected local start — 2026-09-20

Private, source-only successor to the retained-session adapter `1b574ec9` and
qualified private Provider workspace `13bbf9c4`. MAIN and those predecessors
are unchanged. No compiler, Swift parser, fixture, model or remote action ran.

The saved configuration has an explicit `authenticated_ssh_v1` or
`protected_member_v1` choice. Legacy omitted fields keep their previous route;
new saves materialize the choice. Conflicting attachment/transport fields,
unknown values and null refuse. A protected choice never falls back to SSH.

`start --local` selects the route before constructing an SSH session. The
protected route uses the existing `makeClusterMemberLoop` preparation, signer,
registration and attestation. A one-use latch closes configuration before the
member task starts. It captures the actual accepted authenticated connection,
waits up to 90 seconds for its genuine authorized member session and passes that
same retained owner into the existing HTTP/engine host. It creates no worker,
lease, grant, native key, request state owner or policy catalog entry.

The local profile is restricted to exactly 32 prompt tokens, two output tokens,
greedy text generation, C16 and empty stops. The original request-owner shape
check is extracted without changing its guard. Ordinary model EOS behavior is
unchanged; the protected fixed-length route explicitly supplies empty stop IDs.
Unsupported inputs refuse before reservation. No performance-based first-token
promise is supplied. The existing request and native lifetime limits remain.

Cancellation closes future local preparation before cancelling its captured
session, including stop before registration and a late startup result.
Reconnect cannot reopen this loop. The current WSS loop remains alive until the
original member completion joins; the adapter still requires actual cleanup,
release ACK, normal owner exit, request transport, cancellation publication,
local signed release and aggregate release before reuse. Normal protected quota
exhaustion drains; ordinary no-factory exhaustion keeps its previous behavior.
Missing completion retains ownership and can leave a quarantined caller; it is
not a reason to declare release or start a replacement.

This first route runs one authorized cohort and exits after its cleanup. It does
not yet send an automatic coordinator initiation request or renew policy. An
absent coordinator authorization times out without opening the listener. The
separate next Swift/Go initiation slice must use actual verified members, mutual
configured consent and the coordinator's nonempty authorized policy catalog.
Saved policy bytes remain an expectation, never a grant. General workload,
public aggregate routing, encrypted physical qualification and serving flags
remain closed. The existing private native descriptor still records those
limits honestly.

There are 23 Swift files here, 15 effective-predecessor replacements and eight
new files. Together with the adapter the final overlay is 30 files (16 new to
the qualified base). Fourteen staged methods cover transport serialization,
shape/stop refusal, captured authorization/cancellation, late startup cleanup,
and actual loopback HTTP with explicitly fabricated ownership. The adapter's
15 methods and original 117 selected checks are retained. The queued filter
also includes 29 existing HTTP/host/rotation controls: 175 exact completion
labels in all. None has executed against this composition.

`check_sources.py` reads only the explicit small closure and metadata. `BUILD.md`
and `Build/composition.json` give guarded same-cache qualification. Root must
schedule preparation/compiler use. Incoming master `cc225365` is not composed:
its App Attest/routing changes require a separate reviewed merge before final
product qualification. This package is the preserved known-base increment.
