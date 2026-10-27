# Expert partition projection policy correction

Source-only successor to the actual failed `synthetic-small` run. No compiler, fixture, GPU or remote execution by the author. No frozen source/result, MAIN or native backend is changed. Root's typed-loop correction is retained in the exact current `ExpertAxisCheckCases.swift` preimage.

The retained raw result is `gemma4-expert-execution-20260920/cases/small-1/solo/full/native/worker-0.stdout`, SHA `f52ab36a790c85ebb395d32317db5bcfcf51d4670d9c6c2363d8b0070cedff73`. All60 cases executed; eight balanced T8/9 cases differed in raw expert bytes. F32 weighted results also differed; BF16 weighted results were exact but raw equality remained required. That failed result stays failed.

The source identifies a concrete route mismatch:

- `SwitchGLU.projectExperts` sorts at64 total selected indices. The global reference has64/72 assignments, while local partitions have25–45 and previously did not sort.
- `GatherQMM::eval_gpu` selects sorted RHS only when M=1, B≥16, the hint is true, and integer B/E≥4. For example, merely sorting39 local assignments over10 experts still selects the other route.
- NAX sorted RHS selects BM32/BM64 by M/E<64 and specializes row alignment. These choices also need to stay consistent. A local density that cannot preserve the global tile is refused before constructing native tensors.

The private `SwitchGLU.callAsPartition` SPI reuses the exact existing projection, activation, inverse permutation and result squeeze. It accepts an explicit sort choice and sorted-projection hint derived from the authoritative unpartitioned route. Ordinary `callAsFunction`/weighted entry points retain their original default choices and operations. Neither native backend code nor normal mathematical policy is changed.

`ExpertAxisProjectionPolicy` derives those choices from global assignment/expert counts and actual owned counts. Where the global sorted RHS route requires it, local work repeats only the last genuine owned assignment until density and alignment match. Every selected bank is guarded `executedAssignments <= globalAssignments <=264`. Empty ranks execute nothing. The extra output rows are removed before original-slot reassembly, wire transmission and the unchanged `weightedExpertSum`; router values and all original top-k slots are untouched. Policies are reported alongside each actual comparison.

For the current real Gemma128-expert cases (at most33×8=264 assignments), the global sorted-RHS condition is false. The local hint therefore stays false even if a48-expert bank's local density would have selected that different kernel. No real128-expert case is padded to320/512 in this bounded successor. C64/C128 full-prefill support needs a separate increase in packet/execution limits, exact resource bounds and native cases; this correction does not silently admit those larger requests.

All native indices are prepared/evaluated in the existing dispatch initialization. Projection remains graph construction only, with no added eval, synchronization, CPU router readback or host I/O. Both local and RDMA paths call the same prepared projection. RDMA keeps its existing owned bank, transport completion/ACK, resource checks and264-row payload bound.

The existing resource owner now additionally reserves a complete maximum padded local graph for every selected rank, without subtracting any old term. Each allocation is rounded separately: four264×hidden F32 arrays (input gather, sorted input, down output, unsort), three264×intermediate F32 arrays (gate/up/activation), and six264-element UInt32 arrays (token/local IDs and sorting temporaries). CPU charges cover two full copies of padded six-Int assignment records, two UInt32 construction arrays, and64KiB policy bookkeeping. The existing reference/local graph,16MiB diagnostic overhead, native caches,4GiB workspace/loading headroom,2GiB allocator headroom and6GiB free floor remain. RDMA inherits the increased base reserve plus its original16MiB native/16MiB host transfer allowances. These are named conservative allowances, not a whole-process peak proof.

`integration.json` lists exact before/after bytes. Apply only to root's disposable `gemma4-execution-20260920/build/workspace`, after preserving the current binaries. The one library replacement is `libs/mlx-swift-lm/Libraries/MLXLMCommon/SwitchLayers.swift`; the remaining sources live in `DarkbloomClusterRuntime`. Applicable root AGENTS instructions were read; no nearer AGENTS file exists in the seven library/source ancestor paths checked. The new default-inverse assertion is recorded in the source integration metadata. No Package change is required.

Root's first qualification sequence remains:

1. Compile/run the13-group Foundation fixture using exact `ClusterRuntimeError.swift`, `ExpertIDOwnership.swift`, `ExpertDispatchPlan.swift`, new `ExpertAxisProjectionPolicy.swift` and `Tests/ProjectionPolicyControls.swift`, with Swift6/warnings-as-errors/jobs2. These controls cover all eight observed route geometries, unsorted/empty/global128-expert cases, padding removal and invalid/tile-mismatch refusal. They are staged, unexecuted.
2. Incrementally build `GemmaExpertAxisCheck` and `GemmaExpertRDMACheck` with root's existing bounded compiler wrapper and exact release flags. Preserve old source/build/failed physical evidence. Late-bind actual new binaries into fresh deployment/jobs; no future SHA is guessed here.
3. Rerun the unchanged60-case synthetic-small catalog under the existing6GiB/AC/zero-swap/canonical-owner supervisor. Every raw expert output and final weighted result must be byte exact. Padding must not enter original assignment counts or transport bytes. This is the concrete test of the proposed route diagnosis, not a claim the source alone proves identical floating point outputs.
4. Only after passing, run synthetic-Gemma and the mandatory actual checkpoint/layer cases (including postnorm equality), then both actual RDMA ownership maps through fresh jobs. The existing exact gate remains unchanged. No tolerance, token-only substitution, micro-TPS or whole-model correctness claim is introduced.

Example future Foundation command, within a fresh bounded root-owned runner:

```sh
/usr/bin/swiftc -swift-version 6 -warnings-as-errors -O -j 2 \
  "$runtime/ClusterRuntimeError.swift" "$runtime/ExpertIDOwnership.swift" \
  "$runtime/ExpertDispatchPlan.swift" "$draft/Runtime/ExpertAxisProjectionPolicy.swift" \
  "$draft/Tests/ProjectionPolicyControls.swift" -o "$fresh/ProjectionPolicyControls"
"$fresh/ProjectionPolicyControls"
```

`$runtime` is the disposable workspace's `libs/darkbloom-cluster/Sources/DarkbloomClusterRuntime`; `$draft` is this directory. No author-side test result is claimed.
