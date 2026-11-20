# One prepared prompt chunk across two contiguous Qwen stages

Status: source-only design and Foundation-only state/check drafts, 2026-09-14.
The separately authorized Foundation/CryptoKit-only Swift harness passed: four
complete traces and 23 rejected transitions, exit 0. No source integration,
native target build, model run, transport run or performance measurement was
performed for these drafts. Keep the tested v1
serialized path intact. Qualify the actual serialized ranks against the frozen
baseline before testing this follow-on schedule.

The useful overlap is stage zero's next **prompt** microchunk with stage one's
current microchunk. Every worker still has one synchronous MLX caller. There is
one received boundary awaiting consumed acknowledgement and at most one next
output prepared on stage zero. No second header is sent until the first frame's
consumed ACK is validated. No generated decode is speculated.

## Exact admitted protocol

Use a new, closed envelope instead of changing the meaning of a v1 header:

```json
{"version":2,"flow":"prompt_lookahead_one_v1","boundary":{"version":1,"...":"existing strict v1 header fields"}}
```

The illustrated inner object is schematic, not an accepted fixture. Actual
`boundary` is the unchanged complete v1 header built from the producer's actual
boundary and then validated against locally known source, request, frame, token
and native geometry. The total outer JSON cap remains 16 KiB. Validate the raw
outer JSON recursively for duplicates, integer lexemes, booleans and closed field
sets before any nested reserialization; then use existing v1 admission. Allocate
the payload from local expectation, never an unchecked envelope dimension.

All three ACK phases (`ready`, `received`, `consumed`) bind the exact outer bytes:

```text
SHA256("qwen-stage-ack-v2|prompt_lookahead_one_v1|PHASE|SHA256(rawEnvelope)")
```

Keep the existing 64 ASCII digest characters represented as 64 Int32 elements.
The v2 flow and namespace are explicit protocol identity, separate from artifact
and plan hashes. A bare v1 receiver rejects this envelope before ready/payload;
a v2 receiver rejects a bare v1 header. Cohort startup also agrees on this exact
flow string before any payload; no negotiation fallback or mid-request switch.
Use one fresh common cohort/request UUID after every fence. Header hashes bind
that UUID and frame sequence. A previous cohort's matching artifact is not a
valid ticket for this request.

## Single-thread step order

Every `begin` / `completed` interval below contains one synchronous operation on
that worker. No model evaluation, callback-triggered work or second transfer may
run concurrently inside it. Backend implementation threads are not additional
application MLX callers.

| Rank zero | Rank one |
| --- | --- |
| Prepare frame j; evaluate hidden plus every KV/conv/SSM root; commit; copy CPU capture; observer succeeds. | Receive exact next header length and envelope. |
| Send bounded header length and envelope; validate ready ACK. | Validate envelope, identity, tokens and geometry; complete ready ACK send. |
| Complete native payload Send, keeping source and Send handle alive until completion. | Complete native payload Recv; validate owned compact zero-offset storage, dtype, shape, logical length and SHA. |
| Validate received ACK; release the old boundary, output enum, Send handle and scope. Retain only CPU pending ticket and capture. | Complete received ACK send **before** calling the stage-one forward/capture callback. |
| If frame j+1 is prefill, prepare that one frame and capture its committed local state. | Evaluate frame j output and all native state roots; commit; snapshot/logit copy and throwing observer complete. |
| Begin receiving consumed ACK for j. No next header has started. | Release explicit received boundary/output references; complete consumed ACK send for j. |
| Validate consumed ACK for j; publish j's saved completion. | Publish j's completion; wait for the next exact header. |
| Send the already prepared j+1, or prepare a serialized admitted frame if none is prepared. | Repeat. |

If there is no next prompt chunk, rank zero drains consumed ACK immediately.
In particular final prefill → first decode and decode → next decode have this
barrier. The last request frame always drains its consumed ACK before close.

Example for prompt 65 / chunk 32 / output 4, with frozen diagnostic teachers:

| Frame | Phase / offset / count | Rank-zero action after received ACK |
| --- | --- | --- |
| 0 | prefill / 0 / 32 | Prepare frame 1, then drain consumed(0). |
| 1 | prefill / 32 / 32 | Prepare frame 2, then drain consumed(1). |
| 2 | final prefill / 64 / 1 | Drain consumed(2); no decode lookahead. |
| 3 | teacher decode / 65 / 1 | Drain consumed(3). |
| 4 | teacher decode / 66 / 1 | Drain consumed(4). |
| 5 | teacher decode / 67 / 1 | Drain consumed(5); close at frontier 68. |

```mermaid
sequenceDiagram
    participant A as Rank zero
    participant B as Rank one
    A->>A: Commit + capture prompt j
    A->>B: v2 header length + envelope j
    B->>A: ready(j)
    A->>B: residual j
    B->>B: Recv complete + ownership/hash validation
    B->>A: received(j)
    par Separate workers, one MLX caller each
        A->>A: Release old source; commit + capture prompt j+1
    and
        B->>B: Commit + capture j; release explicit residual
    end
    B->>A: consumed(j), possibly blocking/buffered
    A->>A: Validate consumed(j); complete saved frame j
    A->>B: Next header only now
```

## Causal state and decode constraints

The admitted model is a causal, full-width dense Qwen trunk split into contiguous
layer ranges with preserved full-attention phase. Each stage owns its own local
layers' KV, convolution and SSM state. Stage zero's next prompt chunk depends on
known prompt tokens and stage zero's preceding local state; it does not depend
on stage one's previous activations, logits, caches or a collective. Sequence
positions remain the same full-model token positions on both stages, unrelated
to each stage's global layer offset. No cache rewinds, pruning or hidden changes
to chunk size or teacher history are allowed.

The pure plan explicitly admits either `prefillOnly` (outputCount 1) or
`frozenTeacherDiagnostic`. There is no generated-token case. The latter must be
bound by the native coordinator to the same immutable `RecordedRequest` teacher
IDs as the frozen baseline. Even that mode keeps every decode serialized. A
production decode adapter must first receive and validate the actual rank-one
chosen token, tied to the prior committed logits and request/frame, before
stage zero embeds it. Consumed ACK carries no token and is insufficient. Token
return/sampling and a generated-decode adapter are intentionally absent here.

The sender tracks three different frontiers:

```text
completedFrames <= receivedFrames <= producedFrames
receivedFrames - completedFrames <= 1
producedFrames - receivedFrames <= 1
producedFrames - completedFrames <= 2
```

There can be **two** produced frames not yet acknowledged consumed: the receiver
owns one inflight residual and the sender owns one prepared next output. Before
stage one commits the inflight frame, stage zero can therefore be two chunks
ahead of its actual committed frontier (at most 64 prompt tokens with current
caps). The queue of *prepared next* outputs still has depth one. Never describe
this as a one-frame total frontier difference.

For a consumed(j) completion, compare j's saved CPU capture to its ticket and
expected frame. Validate live stage-zero state against `producedFrames`, not j's
old end position. The current serialized wrapper's final
`requireCommittedFrontier(step)` cannot be reused unchanged after lookahead.
State/logit comparisons join captures by exact frame/frontier and global layer
index/component, so different most-recent live stage frontiers do not mix rows.

## Buffer and native ownership

The bounded application slots are one pending CPU ticket/capture, one explicit
sender native boundary and one receiver native boundary. After received ACK and
completed Send, the old source must leave its enclosing autorelease scope before
the next forward begins. A pending ticket contains only bounded envelope Data,
hash/nonce/frame/scalar metadata and the old CPU capture; never an MLXArray,
output enum, model/session reference or closure that captures these objects.
The prepared slot contains just the next committed output and its CPU capture.
The receiver's callback returns CPU capture only, and the explicit received
boundary scope ends before consumed ACK send or another header receive.

This is a logical owner-slot bound, **not** a claim of exactly two physical
allocations. During transfer the source and destination coexist. The pinned CPU
Send first makes noncontiguous inputs row-contiguous and can retain an extra
temporary copy. Native state roots, model weights, graph/workspace intermediates,
allocator cache and backend queues are separate. Dropping an explicit residual
also does not prove a native state root cannot retain an underlying allocation.
Keep the existing native storage checks and measure actual allocation/lifetime
behavior; do not call these copies RDMA zero-copy evidence.

Current caps remain batch one, prompt <=128, chunk <=32, output <=4, H<=8192,
native float16/bfloat16/float32, residual <=1 MiB, outer header <=16 KiB, each ACK
256 bytes, and <=132 frames (the admitted maximum is actually 131). Existing
state/logit capture bounds remain unchanged: full vocabulary <=262144 and finite
logical logits only. CPU capture records can be large and must retain their
bounded report-file/line policy; they do not retain native state snapshots.

## Blocking and buffered backends

The ordering is safe whether consumed ACK send finishes early in a backend
buffer or blocks until rank zero posts receive. If it buffers, rank one may
reach its next-header receive while rank zero prepares j+1; rank zero still
drains consumed(j) before sending that header. If it blocks, rank one waits in
send while rank zero finishes strictly local work and then drains the ACK.
There is no cycle because that local work contains no collective, peer token
dependency, wire operation or lazy graph edge requiring rank one.

Pinned evidence (repository-relative locations):

- `CollectivePointToPoint.swift:26-47,106-117`: keep Send input through checked
  graph evaluation and CPU/GPU fences; returned Send handle aliases the source.
  The shim lock serializes shim calls, not unrelated MLX work.
- `libs/mlx/mlx/backend/cpu/distributed.cpp:73-95`: Send can create and retain a
  contiguous temporary; Recv allocates its destination.
- `libs/mlx/mlx/distributed/ring/ring.cpp:198-205,505-523`: send progresses after
  OS send accepts bytes; a completed send does not prove peer consumption.
- `libs/mlx/mlx/distributed/mpi/mpi.cpp:454-476`: ordinary MPI_Send and
  MPI_Recv(ANY_TAG) are dispatched. The protocol cannot require eager buffering
  or add uncoordinated control messages on this same ordered stream.

An independent source review by transport_probe reached the same dependency
result. No MPI or TCP experiment is evidence for this draft yet. Every operation
still needs a native alarm and parent process-group deadline: synchronous native
I/O or cleanup can block, and no Swift state flag can interrupt such a call.

## Failure, callbacks and integration seams

Any header/ACK mismatch, wire error, native fault, frontier mismatch, capture or
observer error fences the whole cohort. Mark the pure machine and transport
failed immediately; cancel the local request; discard prepared output and CPU
pending slots; preserve primary and cleanup errors; terminate both rank processes
via the parent. Stage zero's already advanced frame is discarded with the entire
request. Do not trim, roll back, replay a frame or reuse a transport/group/model
session as if that speculative state had never existed.

Rank zero's observer for j runs after local commit and before sending j. Its
observer for j+1 can fail while consumed(j) is pending; rank one may then be
blocked sending that ACK. Rank one's observer runs after local commit/capture
and **before consumed ACK**, although received ACK has already let stage zero
advance. Failure in either place is fatal to both. Observers receive only CPU
records and must not call model/transport methods. Captures without matching
transport completion plus final request retirement are incomplete evidence.

Concrete integration changes, kept separate from the existing v1 path:

1. New v2 envelope/ACK codec with strict pre-payload flow admission.
2. New native transport `sendUntilReceived` returning a CPU-only pending ticket;
   `finishConsumed(ticket)` validates the final ACK. Only one ticket is pending.
3. Receiver inserts completed received ACK after ownership/hash validation and
   before the existing commit/snapshot/logit/observer callback; it releases the
   explicit boundary before consumed ACK.
4. New rank-zero owner separates `prepare`, `dispatch prepared`, and `finish old
   completion`, with one native slot and one pending CPU slot. No old native
   output survives dispatch scope exit. Rank-one owner stays sequential.
5. Coordinator pins flow, teacher admission, fresh cohort UUID and exact input
   timeline; final reports include produced/received/completed counters and final
   retirement. The parent joins CPU evidence to the separately released baseline.

The pure draft event machines deliberately execute none of these side effects.
Each completion/release event must be called only after the native operation or
scope exit it names actually succeeds. They cannot prove a caller's native
completion claim, ARC release or token provenance by themselves.

The sender's typed `nextAction` prioritizes releasing the sent source, preparing
one permitted next prompt chunk, draining the pending consumed ACK, dispatching
the prepared output, then preparing/closing when no ACK is pending. The receiver
exposes the next receive/ACK/consume/release action for its exact local phase.
Both return `inProgress` during a bracketed operation and `unavailable` after a
terminal state. Native phase hooks should record actual completion transitions;
they may check or throw but must not perform MLX work or reenter transport.

## Next bounded proof

`QwenLayerStageOverlapCheck.run()` passed in `overlap-foundation-check.swift`,
which imports only Foundation/CryptoKit and the exact existing pure schedule plus
three small support definitions extracted from current Sources. It covers the
six 65/32/4 frames under blocked and buffered consumed
ACK orderings, maximum 131-frame admission, one-frame final drain, no decode
lookahead, wrong/duplicate transitions, slot release, wrong frontier/ticket,
premature close and permanent retirement. `overlap-foundation-result.json` records
four complete traces and 23 rejected transitions. The generated harness is a
standalone artifact and must not be integrated into Sources.

Then test v2 native synthetic payloads and failure phases using the same isolated
two-rank launcher. Only after those pass, use actual tiny stages and the same
frozen baseline comparison, including all per-frame KV/conv/SSM and full logits.
Follow with the admitted real artifact, separately loading/releasing the baseline
before either native rank. Failures with a prepared stage-zero chunk must fence
both workers inside the parent deadline.

Event ordering creates an opportunity for overlap, not proof of simultaneous
GPU work or faster prefill. For N equal-size chunks, compute-only ideal makespan
is c0+c1+(N-1)*max(c0,c1), versus N*(c0+c1) serialized; transfer, ACKs, hashes,
captures, stream fences and unequal final chunk all add work. Three balanced
chunks have only a 1.5x compute-only ideal, so this diagnostic cannot establish
long-prompt throughput. Measure both stage work and end-to-end TTFT on the actual
two-machine configuration before making a TPS or decode-speed claim.
