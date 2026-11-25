The smallest useful change is a request-owned conditioning mirror on the assistant,
retained across proposal-branch retirement. Keep the initial full snapshot. At a
later reseed send only the newly committed KV suffix and the new target hidden row.
Do not refresh the snapshot after every accepted window: the current algorithm
intentionally continues its frozen assistant branch until rejection or bonus-bridge
failure. Changing that schedule would change both acceptance and compute cost.

This is a source-only design against the actual c8688c2d composition. No runtime
files were changed and no compiler, native process, GPU or remote command ran.
The byte figures below follow the validated native shapes; they are not observed
wire traffic or measured transfer/crypto latency. The actual remote hidden dtype
has not yet been observed, so both permitted element widths are retained.

## Current traffic

`reseed` obtains the actual post-reconcile capture from the original target session.
The sender transfers seven tensors: hidden; two individual heads each for full K
and V; sliding K; sliding V. The receiver assembles the full heads and fences the
capture before the exact seeded ACK. Target capture roots remain retained through
that ACK. Only two target layers are captured, the last full and sliding attention
sources, not the complete 30-layer target state.

For committed input frontier F, the BF16 KV payload is exactly
`4096*F + 8192*min(F,1024)` bytes. Hidden adds 5,632 bytes at BF16/FP16 or 11,264
at FP32. The initial frontier is P+1, after the real width-one prime.

| Prompt | Initial frontier | KV bytes | Tensor bytes, FP32 hidden | Plus seed/seeded controls |
|---:|---:|---:|---:|---:|
| 128 | 129 | 1,585,152 | 1,596,416 | 1,629,184 |
| 4096 | 4097 | 25,169,920 | 25,181,184 | 25,213,952 |

The P4096 KV alone is 25.169920 decimal MB / 24.00390625 MiB. Each control record
is currently 16,384 bytes. Seed/seeded costs 32,768 bytes; a preceding branch
retire/retired costs another 32,768. Each credit/queued, pull/proposals and
resolve/resolved pair also costs 32,768 bytes. These control costs occur separately
from tensor payload. No transport framing, encryption tag/header, retransmission
or extra host/device copies are included in these byte figures.

For O16, reseed can occur only at F=P+2 through P+13: the driver restarts only while
selected output count is below15. Thus there are at most12 reseeds after the initial
seed. An all-accepted branch sends no additional snapshot. A reseed can follow several
accepted windows, so its delta is not necessarily at most3 positions. Total delta
positions across every reseed are nevertheless at most12 for this cohort.

Worst-case source bound with13 seeds and FP32 hidden: current tensor traffic is
21,711,872B for P128 and 327,674,880B for P4096. Initial-full-plus-deltas would be
1,879,040B and 25,463,808B respectively. These are bounds for a maximal restart
pattern, not the measured behavior of the pending remote run. Existing final reports
provide restart counts but not each reseed frontier/dtype; exact observed per-round
traffic needs those scalar fields recorded after the matching ACK.

## Minimal delta path

Let F0 identify the last snapshot actually installed and acknowledged by the
assistant, F1 the current reconciled target frontier, and d=F1-F0. Use the existing
`mtpConditioning(after:)` first; this preserves its provenance and guards. Slice
the new committed suffix, without sending rejected target columns or deriving
KV from assistant proposals. Send five tensors:

- current target pre-norm hidden `[1,1,2816]`;
- full K and V, each `[1,2,d,512]` BF16;
- sliding K and V, each `[1,8,d,256]` BF16.

For the present d<=12 envelope every tensor is far below the existing16MiB limit.
KV traffic is exactly12,288*d bytes. At FP32 hidden, d=1/2/3 costs23,552/35,840/48,128B;
including the delta command/ACK it costs56,320/68,608/80,896B. A maximal d=12 costs
158,720B of tensors, or191,488B including that control pair. Keep the initial seven
tensors unchanged; only the new delta mode uses five completed transfers.

Reconstruct full KV by appending the suffix to the confirmed prefix. Window snapshots
are already chronological: old range is `[max(0,F0-1024),F0)`, new range is
`[max(0,F1-1024),F1)`. Retain the overlap from the old mirror and append the d new
positions. Rebuild the same unchanged frozen proposal branch with anchorF1,
slidingStart=max(0,F1-1024), fresh hidden and the authoritative next seed token.
No change to drafter math, target acceptance or proposal order is required.

## Required identity and lifetime changes

Use an explicit v2 protocol scope/magic and delta-seed opcode, not reinterpretation
of v1 padding. Bind request/epoch/build/artifact identities, current branch ordinal,
base snapshot identity and frontier, new frontier, seed, hidden dtype and derived
tensor geometry. The snapshot identity remains a provenance identity, not a hash of
the KV contents. Accept a delta only after the exact previous branch retirement,
with no grant/window pending, an installed matching base and a strictly advancing
frontier equal to the target ledger. Initial delta without a full seed, duplicate,
gap, rollback, stale base and over-budget count must refuse. Future AEAD associated
data must bind this same descriptor and tensor index/shape/dtype/byte count; current
raw Collective traffic does not establish encrypted product admission.

Do not silently retain the old capture under the existing all-roots-retired claim.
Make the new retirement disposition explicit: branch/batch/hidden-chain roots and
their leases retire after the existing native fences, while four immutable KV
arrays transfer to the original service's request-owned mirror. Keep that mirror
distinct from proposal state in the scalar ledger. Terminal finish/cancel still
releases both branch and mirror under the original owner; transport/fence failure
retains all roots until original process cleanup, without manufacturing a reuse ACK.

On update, the service retains old mirror + five received arrays + four assembled
arrays through the assembly fences, validation, installation and exact ACK send.
The receive staging needs at most nine new roots, as today; the four old mirror roots
are separately named. Promote/drop the old mirror only after successful ACK completion.
The target advances its acknowledged base only after receiving the exact ACK and
retains its existing pending capture until then. A failed ACK poisons the request,
so there is no ambiguous-base retry or fallback to an invented complete snapshot.

Keep all current resource terms. Existing three-set receiver reservation appears
ample for old mirror + small delta + assembled new mirror, but this must be checked
with the actual allocator bound on every individual live allocation, including hidden.
Extend `requireReceiverAllowance` to enumerate the simultaneous old and new roots;
do not assume rounding is linear. Existing target capture and full-size send-pack
reservations remain conservative. Initial implementation still constructs the full
local target snapshot and new receiver arrays: it saves network/crypto payload but
does not eliminate those GPU copies or their fences. No speedup is established yet.

## Small implementation and qualification sequence

1. Extend `Gemma4MTPPullRecord` and `Gemma4MTPPullTransferPlan` with versioned delta
   identity/geometry. Add a small pure conditioning-mirror state helper next to
   `Gemma4MTPPullMirror`; retain proposal credit5 and maximum drafts2 unchanged.
2. Extend `Gemma4MTPPullSnapshot` with the five-tensor suffix send/receive and exact
   chronological assembly. Extend its allocation proof; keep full seed unchanged.
3. Change `Gemma4MTPPullAssistant`/`BatchOwner` retirement to explicitly return KV
   ownership to the service mirror. Finish/cancel must clear it only after fences.
4. Change `Gemma4MTPPullTarget.reseed` to choose full once, then delta from its last
   acknowledged base. Add bounded scalar seed records to target/assistant reports:
   base/new frontier, ordinal, hidden dtype, tensor count/bytes and completed ACK.
   `RemoteMTPInput` must bind the v2 mode; owner/request/Collective creation stay unchanged.
5. Qualify pure replay/cancel/base-mismatch controls, then real two-rank tiny tensors
   at F129 and4097, d1/2/3/12 and a sliding1024 wrap boundary. Compare every reconstructed
   component byte against a same-source full snapshot; inject post-receive/fence/ACK
   failures and prove roots remain owned until original cleanup.
6. Run the matched real packed/serial target policy under unchanged resource guards,
   compare all tokens/full final rows/whole state against same-build solo, and measure
   actual reseed/control/target/draft times before claiming faster decode. No new
   capture/state framework, background receive task or overlapping P2P/GPU on one
   rank is needed for this first delta implementation.
