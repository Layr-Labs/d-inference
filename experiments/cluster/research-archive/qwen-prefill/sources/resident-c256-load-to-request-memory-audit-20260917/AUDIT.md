# C256 load-to-request memory interval

The existing evidence does **not establish a new 1.4 GB host allocation after loading**. The closest numerical match is the preceding final weight-loading increment appearing later in the system-wide VM counters. This is a supported hypothesis, not process attribution or proof of a particular kernel counter implementation.

`source-review.json` retains the actual four relevant rank0 samples from both accepted sidecars, replays the differences, and verifies 26 selected runtime/JACCL files against the actual 3,053-member memory-worker source snapshot. It does not traverse or hash the full workspace or binaries. The worker build identity remains `379b413d6791b8116c889a27b01f6a890d43df31f227eb8b714f71f16a300230`.

| Same-process interval or difference | Serial | Lookahead |
| --- | ---: | ---: |
| Last periodic load → loadComplete | 0.535594 s | 0.535172 s |
| MLX active increase in that preceding interval | 1,396,944,820 B | 1,396,944,820 B |
| OS actual-free loss in that preceding interval | 2,801,664 B | 0 B |
| loadComplete → requestBegin | 3.064977 s | 3.065352 s |
| OS actual-free loss in this interval | 1,399,668,736 B | 1,412,415,488 B |
| Anonymous-page increase in this interval | 1,397,080,064 B | 1,401,192,448 B |
| Anonymous increase minus preceding MLX increase | 135,244 B | 4,247,628 B |
| MLX active / cache / cumulative peak changes | 0 / 0 / +252 B | 0 / 0 / +252 B |

The loadedRequestGuard VM counters equal loadComplete's counters in both runs. The serial final active increment explains 99.9903% of the later anonymous increase; the lookahead increment explains 99.6969%. These ratios do not establish that the page counters belong to this PID. No per-process footprint is present in these sidecars.

## Exact executed path

Paths below are relative to the qualified source workspace, `resident-generation-phase-native-draft-20260916/Build/workspace`, except the controller.

1. `Runtime/QwenResidentLoading.swift:114` calls `gate.finish()` after `materializeVerifiedQwenLayerStage` returns. Its `loadComplete` observation is **not** before outstanding checkpoint reads. `Runtime/VerifiedQwenLayerStageLoading.swift:68` loads each tensor inside an autorelease pool, evaluates it and synchronizes the GPU before assigning it. `SafeTensorReader.swift:15` creates temporary host Data and copies it into MLX storage; `CheckpointAlignedReader.swift:63` unmaps its bounded anonymous scratch before return. No checkpoint payload read remains in the traced interval.
2. `Runtime/QwenResidentRuntime+Load.swift:70` derives scalar maximum-request allowances, calls `prepareReady` (GPU and CPU synchronization, cache clear), computes the scalar lookahead allowance, and records loadedRequestGuard at line 89. The reservation values are accounting ceilings, not allocations of those byte amounts. The unchanged guard snapshot still has the earlier VM counters.
3. The same load function constructs a small commitment and calls `requireQwenLongPrefillReadinessDigest(.residentLoaded)` at line 93. This exchanges a 64-element Int32 digest, 256 logical bytes each way. `CollectivePointToPoint.swift:104` evaluates the transfer and fences CPU/GPU completion. This is already the **second** identical-shape digest exchange: load-intent completed before the first weight read. Guard completion to local Ready consumes 2.621 s serial / 2.637 s lookahead; the available anchors do not split that interval further.
4. `WorkerCoordinator.swift:49` publishes Ready and starts its bounded control reader. The qualified local controller (`resident-generation-phase-physical-draft-20260916/Controller/Controller.swift:108`) waits for the pair, reserves the request, then sends start. The remaining Ready-to-request sample interval is 0.427 s / 0.411 s. `QwenResidentRuntime.reserve` derives allowances, validates bounded prompt/control data and stores a reservation; it does not allocate the charged state/fusion tensors.
5. `QwenResidentPhaseResources.swift:73` records requestBegin before the generation driver. `QwenLayerStageGenerationDriver.swift:81–93` then emits its request/readiness events and constructs `QwenLayerStageSession` only at stateBegin. KV/recurrent state allocation, projection fusion and the first residual are therefore later than the disputed sample.

`Runtime/` above abbreviates `libs/darkbloom-cluster/Sources/DarkbloomClusterRuntime/`. WorkerCoordinator is in `libs/darkbloom-cluster-worker/Sources/DarkbloomClusterWorker/`.

## JACCL and interpretation limits

The native files are `libs/mlx-swift/Source/Cmlx/mlx/mlx/distributed/jaccl/lib/jaccl/{mesh.cpp,mesh_impl.h,rdma.h,rdma.cpp}`. Mesh is mandatory; ring environment overrides are refused. `MeshGroup` calls `allocate_buffers()` during Collective initialization, before load-intent and all memory samples. For two ranks the source allocates `4096 × (1+…+128) × 2 × (2+4) = 12,533,760` payload-buffer bytes, plus allocator/driver metadata. The fixed buffers are reused by send/receive; there is no payload-buffer resize or large allocation on the later 256-byte digest. This arithmetic is not a bound on opaque driver memory.

`QwenDenseStageLoadResources.swift:18` reads system-wide `HOST_VM_INFO64`; its timestamps bracket the call, not the freshness of the kernel's underlying counters. MLX's sample is an allocator snapshot. Neither identifies all allocations of the native PID, other host processes, or kernel/driver ownership. This audit has not inspected the exact testbed kernel implementation and does not assert a specific cache/rate-limit mechanism. The source rules out the named state/fusion and mesh initialization sites as new allocations in this interval; it cannot exclude opaque runtime behavior or host-wide activity.

## Smallest useful next observation

Reuse the existing `CollectiveAllocationFootprint.read()` implementation from `collective-native-allocation-probe-draft-20260916`: `proc_pid_rusage(getpid(), RUSAGE_INFO_V4)` gives current physical footprint and lifetime maximum. Add these two scalar values, PID and a bracketed read interval to the existing bounded memory samples, without an extra timer, eval, synchronization, peak reset, sleep or hot-path file write. Derive the increased recorder charge from actual `MemoryLayout` and the existing host allocation bound; do not silently retain the old byte charge. Add one same-thread sample immediately after loaded-readiness returns to locate any change on each side of that wait.

If the native footprint already includes the final increment at loadComplete and stays flat through requestBegin, the later host-wide delta is not evidence of a new native-process footprint. If it rises, that attributes a footprint change to the PID, but still does not distinguish delayed residency of existing allocations from a separate host allocation. Retain the OS and MLX series independently. No current admission/headroom threshold should be reduced from this correlation.

No compiler, tests, GPU, remote operation, MAIN/vendor edit, binary hash or model read was performed for this audit.
