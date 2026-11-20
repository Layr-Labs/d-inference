# Expert-ID dispatch contract — source only

This adds two pure Foundation Swift files and sixteen executable Foundation checks. It changes no MAIN, vendor, model, owner, native worker, numerical policy or existing frozen research source. No compiler, test process, GPU, remote command or model read has been run for this draft.

`ExpertIDOwnership` validates complete, disjoint expert IDs across nonempty ranks, including unequal and noncontiguous ownership. Increasing global-ID order defines each local expert bank. `expertRanges(rank:)` plugs directly into the existing `TensorSelection.axis(0, ranges)` representation; the existing two-rank `makePartitionStorage` can independently prove exact coverage and both layout/byte commitments. The pure contract also handles more than two ranks, but the existing storage/transport integration remains two-rank.

`ExpertDispatchPlan` preserves each original token/top-k slot while deriving rank and local expert ID. Its per-rank queues preserve slot order; returned queues may be sorted by local expert, but `reassemblyIndices` refuses missing, duplicate, changed, wrong-rank or out-of-range bindings before producing the original-order permutation. No routing weight is recomputed or normalized. Per-expert/per-rank assignment counts are factual inputs for later measured placement, not a cost model.

This is a CPU reference/control contract. It is not connected to generation. A device implementation must reproduce it without CPU readback of router tensors, host dispatch allocation per forward, or an uncharged recording path. `maxAssignments` bounds record count only. Native integration must separately charge both original and rank-array copies of assignment records, ownership maps and arrays, histogram, return-validation/permutation storage, temporary duplicate-detection sets, encoding buffers, device index/activation/return buffers, and transport/codec staging using checked arithmetic and the existing resource owner. Parse limits must bound rank count, expert count, tokens, top-K, assignment count and encoded bytes before allocation. This helper receives an already bounded metadata packet; it is not that parser or admission authority.

`selectedStoredShape` verifies only rank-three shape and the expert axis. The native adapter must still validate every weight/scale/bias name, source dtype, affine W4/G64 policy, packed columns, complete projection triplets, source bytes, compact owned materialization and loaded model layout against actual metadata. It must retain full input/inner widths and replicate the router with its original global expert count/scales. Changing the whole model's `num_experts` would incorrectly shrink the router.

## Root-only Foundation qualification

After source review, from this directory:

```
python3 -B run_checks.py 1
```

The runner verifies all frozen local members, imports the separately pinned existing `owned_process.py`, creates `checks-1` exclusively, compiles only these three Swift files with Swift 6 and maximum two driver jobs (90 seconds), then executes only the Foundation binary (15 seconds). Each child has its own process group, regular stdout/stderr/PID logs, retained receipt, actual reap and absent-group gate. The expected result is exactly the sixteen named groups in `expected-checks.json`; all native/numerical/hardware qualification flags remain false. No MLX, weights, coordinator, installed owner or network code is linked. Unknown attempts or reused output directories refuse. The compiler and test have not yet run; future failures must be retained and corrected separately.

The smallest subsequent native task is in `REPORT.md`. It reuses existing SwitchGLU, selected loading, actual Gemma decoder boundaries and collective/owner APIs; it does not add another inference engine. There is no current binary, build grant, native implementation or deployment in this draft.
