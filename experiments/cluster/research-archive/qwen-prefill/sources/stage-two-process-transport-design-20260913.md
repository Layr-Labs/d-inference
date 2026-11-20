# Sequential whole-layer handoff: pinned transport design

Source-only review, 2026-09-14. No build, native process, GPU operation, SSH, network configuration, or performance measurement was performed. Paths below are relative to the repository; `M` means `libs/mlx-swift/Source/Cmlx/mlx/mlx`.

## Actual capability

Both real backends implement point-to-point byte transfer. A bounded two-process loopback correctness implementation is feasible now, without a pinned-source change. Use a distinct stage execution mode with the existing immutable bundle and process supervisor; do not relabel the current tensor-parallel worker.

| Surface | Actual implementation and limit |
| --- | --- |
| Cmlx public API | `libs/mlx-swift/Source/Cmlx/include/mlx/c/distributed.h:51–71` exports `mlx_distributed_send`, `mlx_distributed_recv`, and `mlx_distributed_recv_like`. No high-level Swift send/receive wrapper was found in the pinned Swift sources. |
| TCP ring | `M/distributed/ring/ring.cpp:505–547` implements raw-byte send/receive between neighbors. In a two-rank group either peer is a neighbor; receive deliberately checks the left connection first for this case. `:770–807` waits for socket-transfer futures. This is TCP, not RDMA. |
| JACCL | `M/distributed/jaccl/jaccl.cpp:132–148` dispatches raw bytes to `jaccl::Group::send/recv`. Both `lib/jaccl/mesh.cpp:181–186` and `lib/jaccl/ring.cpp:182–204` implement them. Mesh/ring use registered staging buffers and poll completions; this is not a zero-copy path. |
| Missing/stub backends | `M/distributed/{ring/no_ring.cpp,jaccl/no_jaccl.cpp}` report unavailable and throw on strict initialization. The singleton `EmptyGroup` is not a transport fallback. Require an explicit available backend, strict initialization, and exactly ranks 0 and 1. |
| Built experiment | Pinned SwiftPM excludes real TCP ring by default. `experiments/cluster/inference/prepare_dependencies.py:21–25` enables it in an isolated generated overlay. `build.sh:21–31` checks actual ring/JACCL symbols; macOS 26.2 selects real JACCL. Availability alone does not establish a connected RDMA peer. |

Use the existing explicit `loopback-test` hostfile form `[["127.0.0.1:port0"],["127.0.0.1:port1"]]`, with distinct ports and `MLX_RANK=0|1`. JACCL later uses the existing strict device/coordinator configuration after a fresh live-link check. No automatic backend fallback.

## Evaluation, dtype, and ownership

- `M/distributed/ops.cpp:87–142` constructs **lazy** send/receive arrays. C return status zero only establishes graph construction. There are no message tags, remote shape/dtype negotiation, payload identity, or per-operation deadlines.
- `M/backend/cpu/distributed.cpp:73–97` makes a noncontiguous send input contiguous when necessary. The returned send array aliases the original input; it is a completion handle, not a new owned residual. Receive allocates a new buffer; `recv_like` uses only the reference shape/dtype and does not receive into it.
- Both implementations transfer `nbytes` through byte pointers. Preserve the source BF16/F16/F32 dtype and bytes; do not cast, serialize values as JSON, or substitute an all-sum for residual transfer.
- `M/backend/metal/distributed.cpp:25–30` throws for GPU send/receive. Both group implementations choose CPU only as the default communication device. An explicit GPU stream remains GPU (`M/utils.cpp:30–40`), so the wrapper must pass an explicit CPU stream.
- For the first correctness implementation, capture `let communication = StreamOrDevice.cpu`, pass its `.ctx`, evaluate each handle inside `MLX.withError`, call the error check, synchronize `communication.stream`, and check again before inspecting or acknowledging data. Retain the source, handle, and group through completion. Do not assume an unrelated default-stream synchronization completes this operation. Pinned `MLX/Stream.swift:55–56` currently ignores the argument of `StreamOrDevice.stream(_:)`; avoid that factory for a custom stream.
- The existing stage producer already evaluates hidden/state roots and commits before returning. Start with its explicit `ownedCopy(check:)`. After receive completion, enforce the existing compact/unique/zero-offset allocation checks and the **producer's** native-byte SHA256 before stage 1 consumes the array. The receive allocation must actually satisfy those checks; a fresh receiver-computed hash alone is not evidence of a correct transfer.

## Smallest worker prototype

Add a focused Cmlx point-to-point wrapper sharing strict group/loopback admission with `Collective.swift`. Its group is currently private and its only data operation is all-sum. Stage loading keeps full-width heads/FFNs and must not install TP reductions. An initial one-shot, serialized stage-pair mode is smaller and more honest than extending persistent serving immediately.

Reuse `runtime/bundle.py:snapshot`, `rank_worker.py:execute`, and `processes.py:run_cohort/stop_processes/request_cancel` for immutable artifacts, explicit environments, deadlines, cancel files, and native process-group reaping. Introduce a stage-specific rank configuration and result validator. Current worker protocol 5 (`WorkerSession.swift`, `runtime/persistent_protocol.py`) loads `partitionRank`, attaches TP reductions, and expects replicated token/result semantics. Current `PersistentCohort` therefore cannot run this stage pair unchanged. A persistent extension needs its own versioned stage identity and output contract; do not weaken version-5 validation.

Each process loads only its verified compact stage. Ready records bind the common artifact/configuration/plan/storage commitment, source conversion policy and activation dtype, backend, epoch, and ordered stage fingerprints/layout hashes; each record also binds its actual stage index and local receipt. Stage 0 owns token ingress, stage 1 owns residual ingress and the real final head. A separately run full baseline must be released before loading the pair.

One bounded request, one boundary credit, one rigid operation order:

1. Both ranks admit the same prompt, teachers, chunk schedule and canonical request hash before accepting work. Reuse the existing epoch/request agreement pattern; a small integer all-sum agreement is acceptable control, with no floating model reductions.
2. Stage 0 runs its next actual CBv2 frame, evaluates hidden plus state roots, checks errors, commits state, and creates the owned native boundary. It retains that buffer until transfer completion and waits for consumption acknowledgement before another frame.
3. Send a fixed Int32 header length followed by at most 16 KiB of canonical UTF-8 JSON as UInt8. The closed, versioned header carries epoch and all current `QwenLayerStageBoundary` identities: request, source configuration, artifact aggregate, storage commitment, plan, producer stage, frame sequence/phase/token offset/count/final-chunk bit, token IDs hash, and producer payload hash; add exact shape, dtype, and byte count. Stage 1 validates against its already admitted timeline **before** constructing a variable payload receive.
4. Stage 1 returns a fixed-size header-accepted acknowledgement bound to epoch/request/frame. Then stage 0 sends and stage 1 receives the residual with its exact native shape and dtype. Evaluate/synchronize each matched control operation. Never put two blocking sends opposite each other, and never overlap an all-sum or another request with this sequence.
5. Stage 1 verifies native bytes and owned storage, reconstructs the boundary, executes the actual stage-1 CBv2 path, evaluates output plus state roots, checks errors, and commits. It returns a consumption acknowledgement bound to the same frame/frontier. Local send completion by itself does not establish remote model consumption.
6. First tests use identical preset teacher IDs on both ranks. Only stage 1 produces complete logits. A later greedy extension must return the stage-1-selected token and bound decode step to stage 0 before its next forward; the existing rank-0-greedy TP convention is inapplicable.

A malformed identity, wrong order, hash mismatch, EOF, peer crash, or deadline permanently invalidates the entire request/epoch and retires both native groups. Stage 0 may already have committed when stage 1 fails; do not retry using either cache. Backend socket/RDMA completion waits have no request timeout or reliable Swift cancellation hook, so an independent parent deadline and process-group cleanup remain essential. The initial one-shot supervisor already supplies this; a persistent version also needs native startup/idle/request alarms.

## Bounded qualification sequence

1. Actual two-process TCP loopback tensor checks for native BF16/F16/F32 payloads, including signed zero and distinct bit patterns; verify raw bytes, shape, ownership, CPU completion and GPU consumption. Exercise small and maximum admitted residual sizes. No all-sum substitute.
2. Fail-closed checks for wrong epoch/plan/stage/frame/count/dtype/hash and peer loss while awaiting header, payload, or acknowledgement. Verify both owned process groups are reaped and no request resumes.
3. Existing tiny8 4+4 F32/BF16 model fixtures with the same prompt/teachers and chunk schedule: compare full output bytes and every committed KV/conv/SSM frontier against separately recorded ordinary full-model evidence. Record producer/receiver boundary hashes and exact local stage receipts.
4. Only after that, consider a separately admitted real9B two-process local check with the existing bounded workload and memory monitoring. Current TP `local_correctness` admission is not automatically a stage admission. When the peer/link returns, repeat tensor and stage checks with strict JACCL before claiming that path works.

This prototype deliberately adds control round trips, ownership copies, hashes, and synchronization. It tests the actual point-to-point path and exact stage semantics; it establishes no throughput, pipeline overlap, production scheduler, or RDMA performance result.
