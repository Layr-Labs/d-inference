# Pending value and native checks

No parser, compiler, fixture or native operation has run for this draft.

The staged `Tests/LayoutCheck.swift` uses the retained, pinned Gemma config to enumerate all 29 partitions. It verifies exact per-layer and conservative backend charges, full-ring allocation for short requests, logical chronology at 0/1/1023/1024/1025/8192/8319/8320, complete global coverage, same-width different-type fingerprints, and malformed identity/geometry/context refusals. Compile only these actual Foundation sources after a slot grant: `LayerAttentionStateLayout.swift`, current `ClusterMetadataHashing.swift`, current `ClusterRuntimeError.swift` and the test. Use the existing unreaped-process runner with 60-second compile/10-second execution bounds and before/after pins. No new runner is introduced.

Next, a native synthetic fixture must use the actual `CBv2OwnedRequestState`, contiguous backend and cache bank. Supply two real caches: a small full layer and a small sliding layer with distinct head geometry and observed BF16/FP32 types. Obtain the native observation through the existing probe (or its frozen throwing callback extension), not a fabricated Result. Run cache-updating forwards through the actual state `run`, preserving the existing native-error/eval/commit/retire sequence. Cover:

1. Below, at and beyond wrap; chunks larger than the window; several complete wraps. Compare chronological snapshot bytes with an independently maintained small CPU token ledger.
2. Metadata inspection across a wrapped ring without calling snapshot, evaluating or retaining MLX roots; confirm existing storage/frontier is unchanged. Healthy validation may read the one-element position only.
3. Wrong row identity, wrong device position, wrong native dtype/shape, wrong window, incomplete retained history and pending speculative ring writes must fail and retire through the existing owner.
4. Empty recurrent specification must complete repeated runs and snapshots with no recurrent arrays; a nonempty but missing recurrent generation must retain the old refusal.
5. Explicit snapshots must retain CPU bytes across the next native mutation. Equal retained bytes at different absolute ranges, global indices or layouts must have different new fingerprints.
6. Existing tiny Qwen Session/proposal/target-transaction checks must pass unchanged. The old all-full/nonempty-recurrent snapshot fingerprint must be byte-exact; the new metadata accessor must not change old row math or callback ordering.

Finally, before any Gemma readiness claim, use the actual native stage constructor, verified tensor assignment and paired residual probe. Recheck prefill/decode K/V types and boundary types, and compare full versus split results across a 1024-token wrap. The native constructor's original global geometry and optimized policy gates remain intact. A synthetic cache fixture cannot prove Gemma numerical equality or memory admission.

The outer loaded-model/request resource owner must charge `conservativeKVCapacityBytes` plus `windowTemporaryBytes`, position arrays and its existing attention/activation/snapshot allocations before a real request. The transient term bounds retained chunk views and an old ring backing, not all attention scratch or allocator rounding. This draft does not connect that outer admission or authorize a model run.
