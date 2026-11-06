# Qwen27B convolution backing: source-only decision

The local MLX `contiguous()` operation is a suitable candidate for compacting the ordinary Qwen27B convolution tail. The ordinary `copy` primitive is not: it shares the original buffer. No runtime patch or numerical/memory qualification is included in this audit.

The exact source pins and line anchors are in `source-review.json`. The inspected workspace also contains the qualified phase-memory successor; the receipt distinguishes matches to the original phase snapshot and its successor. Qwen35, recurrent transaction, indexing, and copy implementation ancestry are checked individually, not inferred from the directory name.

## Why the backing is retained

`Qwen35.processChunk` concatenates the previous convolution state and the current QKV chunk, then returns its final three positions as a slice. Ordinary `cbv2Forward` stages a further row slice. The slice backend calls `copy_shared_buffer`; the array descriptor retains the original allocation, even after its graph inputs are detached.

For BF16, 10,240 convolution channels and twelve recurrent layers on rank 0:

| Quantity | C256 | C512 |
|---|---:|---:|
| One layer's concatenation, logical bytes | 5,304,320 | 10,547,200 |
| Twelve retained concatenations, logical bytes | 63,651,840 | 126,566,400 |
| Twelve logical three-position tails | 737,280 | 737,280 |

These parent figures describe the known logical backing, not an exact whole-process allocation peak.

## Copy and evaluation semantics

The C API `mlx_copy` constructs `Copy`; its CPU/GPU implementation calls `copy_shared_buffer`. Swift `copyContext()` also copies a descriptor reference. Neither releases an oversized allocation.

The pinned CPU and Metal `Contiguous` implementations share a row-contiguous input only when `input.buffer_size() <= output.nbytes() + 16,384`. Otherwise they use `CopyType::General`. Both C256 and C512 convolution tails exceed that threshold. General copy always allocates `output.nbytes()` and never takes the donation path. It preserves shape and dtype and performs same-type element assignments, without arithmetic or an intermediate F32 conversion. Bitwise equality on the actual backend remains a required check.

Each tail requests 61,440 bytes. With the observed 16,384-byte allocator page policy, the request rounds to 65,536 bytes; the pinned cache-reuse ceiling is 98,303 bytes. Thus twelve compact tails retain at most 1,179,636 bytes under this policy, versus the 63,651,840/126,566,400 logical parent backings. The implementation must derive the bound from the admitted allocator policy, rather than assume that page size on every host.

`contiguous()` constructs a lazy graph. It does not evaluate or synchronize. The existing joint `eval([output] + recurrentRoots + cacheRoots)` can realize all compact roots. MLX retains input buffers until the GPU command completes, then detaches graph inputs. The old transaction also holds its input states until finalization and release. The reduction therefore concerns retained state after normal evaluation/commit lifetime; it is not a promise that memory is released at graph construction.

The allocator normally moves released buffers from active memory to its cache. Reduced active backing is not a guaranteed increase in OS actual-free memory, nor a guaranteed decrease in active-plus-cache. This candidate alone does not justify a new cut, floor change, or long-prompt placement.

## Transaction and Swift object identity proof

The exact plain Qwen35 producer stages `newConvState[row ..< row + 1]`. A one-range subscript takes `getItem(.slice)` and always returns a newly initialized final-class `MLXArray`, including the B=1 full-row case. Old input/committed wrappers are only read into `convRows`. The newly staged wrapper is not one of them.

`stageRaw` stores that new wrapper in a value-type layer-state record. `evaluate()` copies these records into the pending generation and returns the same new wrappers as roots. The first assignment of these records to `committed` is the ordinary `commit`. Rollback removes pending; it does not rewrite committed wrappers. Output computation consumes the concatenation graph, not this newly allocated Swift row-wrapper object.

`contiguous()` captures the old C++ array descriptor as its input. `_updateInternal` replaces the destination wrapper's C++ array reference with the new descriptor; it does not mutate the captured descriptor or its bytes. There is no self-cycle. Updating the fresh pending wrapper therefore also updates the roots array, while leaving committed/input wrappers unchanged.

This proof is specific to the pinned ordinary Qwen35 path. The generic public `stage` API accepts arbitrary wrappers and does not itself guarantee fresh object identity. There is no existing public API for replacing only a pending entry. Do not apply `_updateInternal` generically to arbitrary model, captured, replay, or chained transactions.

## Narrow runtime-only candidate and required guards

The insertion point is `CBv2OwnedRequestState.run`, after `evaluation.evaluate()` has staged pending roots and before the existing joint `eval`. An explicit private registered-Qwen27B validation option may select it; the default remains disabled. No vendor source edit is necessary.

Before changing any wrapper, validate all of the following:

1. The admitted model/stage is the exact registered Qwen27B definition and owned 16/48 plan, with one request row; the transaction is plain (`isCaptured == false`) with the existing serial bind/evaluate/commit lifecycle.
2. The complete expected local layer set is present. Each convolution tail has the admitted shape `[1, 3, 10240]` and BF16 dtype; every state/component matches its existing geometry. No nil, missing, extra, or duplicate pending convolution wrapper is accepted.
3. Every pending convolution wrapper differs by Swift object identity from **all** input and confirmed conv/SSM wrappers, from pending SSM wrappers, and from other pending convolution wrappers. These checks enforce the source proof if a producer changes later.
4. Derive compact-buffer bounds from the actual allocator policy. Preserve all existing live resource checks, floors and full-model state allowances. Do not claim the existing ledger covers unknown workspaces. The existing three-generation F32 convolution allowance is larger than the compact BF16 arrays, but the implementation must explicitly show the added live copy fits that named allowance or charge it separately; no silent reuse of unrelated headroom.

After all semantic checks pass, construct all lazy compact arrays while retaining the original pending wrappers; check MLX construction errors before mutation. Replace only the validated fresh pending convolution wrappers, preserve SSM and KV, and use the one existing eval. Check errors before validation/commit. No added forward, device-to-host read, file I/O, `eval`, stream selection, or synchronization belongs in this change.

If validation or copy construction fails before mutation, no pending wrapper has changed. If a later context update/evaluation/check fails, mark the owner failed through the existing catch path and let existing retirement synchronize and roll back the pending generation. Never commit, retry the partially changed transaction, or restore speculative values into committed state. Because the committed/input wrappers are excluded by identity, this failure cannot rewrite their state. Existing error and absolute-deadline precedence remains authoritative.

## Required qualification before use

- Actual local CPU and Metal copy controls: large offset tail versus compact result, allocation identity and policy-bound buffer size, raw BF16 equality, unchanged shape/dtype, ordinary copy's alias control, and small-contiguous alias behavior. Include signed zero and representative BF16 bit patterns; do not replace a device test with a formula-only fixture.
- The actual transaction path across multiple chunks: old wrapper/context/digest remains unchanged before commit; new pending root is compact; commit advances once; an injected pre-mutation refusal and a post-staging failure preserve rollback/retirement. Negative shared-wrapper, wrong geometry, captured/replay, and wrong-model controls must refuse.
- Source inverse and existing eval observations must show no added eval/synchronization or forward. Keep the exact default path unchanged.
- Short ordinary/full-reference versus two-stage numerical comparison, followed by the chosen C256/C512 workload: every selected ID, final full BF16 row, and all named state components/frontiers. Tokens alone are insufficient.
- At matched existing phase boundaries, compare actual buffer footprints plus MLX active/cache/peak and raw OS resources after normal retirement. Measure copy overhead. Retain failed runs and distinguish cache movement from actual-free improvement.

No compiler, fixture, model, GPU, remote operation, vendor edit, MAIN edit, or frozen-source edit was performed for this audit.
