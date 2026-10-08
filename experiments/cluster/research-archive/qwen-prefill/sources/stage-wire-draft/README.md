# Draft Cmlx point-to-point shim

This is an out-of-repository source draft. No source integration, compiler, native process, GPU operation, or transfer test has run. Copy the two Swift files into the experiment target and apply the small `CollectivePointToPoint.patch` only when root integrates it. Existing group admission/backend selection is unchanged.

API additions to `Collective`:

```swift
func sendCompleted(_ input: MLXArray, to peer: Int, maximumBytes: Int,
                   check: () throws -> Void) throws -> MLXArray
func receiveCompleted(shape: [Int], dtype: DType, from peer: Int, maximumBytes: Int,
                      check: () throws -> Void) throws -> MLXArray
```

Both require the other peer of an actual size-two group, preserve native bytes/dtype, and return only after checked C graph construction, checked evaluation, and checked CPU/GPU stream completion. Send's returned handle aliases its input; it does not represent a fresh residual or a remote-consumption acknowledgement. Receive returns the backend's actual allocation only after unique/row-contiguous/zero-offset/exact-elements/allocator-footprint checks. There is no alias fallback or implicit ownership copy. If those checks fail, integration must fail closed; any future copying fallback must be explicit in its API and receipt.

`maximumBytes` is mandatory and comes from local admission, not the remote header. The helper's hard logical-byte limit is 16 MiB; dimensions must be positive C Int values, rank 1–4, with checked element/byte multiplication. Allowed dtypes are UInt8, UInt32, Int32, Float16, BF16 and Float32. Scalars use shape `[1]`. The wire layer must impose tighter limits, such as four bytes for the UInt32 header length, its bounded UInt8 header size, fixed Int32 acknowledgement size, and exact `[1,M,H]` residual bytes. This cap is not total process memory admission or a claim about allocator/scratch bytes.

The shim serializes its own operations with a lock and directly calls C evaluation/synchronization so return statuses are checked. MLX's public Swift wrappers return Void and its eval lock is internal. Therefore the caller must own exclusive synchronous MLX execution: no concurrent model evaluation, MLX thread, recursive transfer, callback dispatch, or overlapping collective during these methods. This fits the proposed one-shot, serialized stage prototype. `check` may inspect/throw only. Do not use this draft as a concurrent serving API. The C calls do not add an independent timeout: the native request alarm and parent process-group deadline/cancellation remain mandatory.

Each call captures `StreamOrDevice.cpu` once and uses that exact `.ctx` for submission and synchronization; it also captures the normal model GPU stream for the conservative completion fence. Pinned `StreamOrDevice.stream(_:)` currently ignores its argument, so the draft never uses it. Custom producer GPU streams are outside this first contract. Stage producer output/state must already have been evaluated and committed; hold the returned boundary source through send completion. The receiver validates the producer's payload hash and frame identity before calling stage 1. Sending completed data is not proof that stage 1 consumed it; the wire protocol must carry a separate matched acknowledgement.

Pinned implementation references:

- `Source/Cmlx/include/mlx/c/distributed.h:51–71`: public C send/recv/recv_like signatures; `Source/MLX/DType.swift:64`: public `cmlxDtype` mapping.
- `Source/Cmlx/mlx/mlx/distributed/ops.cpp:87–142`: lazy Send/Recv, no remote tags/type negotiation.
- `Source/Cmlx/mlx/mlx/backend/cpu/distributed.cpp:73–97`: Send aliases input, Recv allocates, sender may make a contiguous temporary.
- `Source/Cmlx/mlx/mlx/backend/metal/distributed.cpp:25–30`: GPU Send/Recv throw. Both real backends transfer bytes on the CPU stream.
- `Source/MLX/Stream.swift:55–56`, `Transforms+Eval.swift:9–24`: custom stream factory caveat and private Swift evaluation lock.
- Existing `TensorSelection.swift` / `QwenLayerStageBoundary.swift`: post-completion ownership admission conventions.

Root's initial two-process native check should cover all six admitted dtypes, UInt32 `[1]` control, byte-exact BF16/F16 signed zeros, small and maximum residual geometry, a noncontiguous send view, and unique owned receives; send is deliberately not required to be unique. Reject peer=self/out-of-range, non-two-rank group, empty/zero/negative/overflowing shape, unsupported dtype, zero/oversized local cap and oversized payload before transport. After a transfer failure, do not reuse the group/state. Peer disappearance and deadline cleanup require separate whole-cohort process tests. No native correctness or throughput claim is made by this draft.
