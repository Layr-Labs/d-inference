# Segmented paged KV foundation validation

> Last updated: 2026-09-05 · commit `28c2635c`

The explicit segmented-storage prototype passes six native test functions with 19 parameterized cases after correcting two GPU dependency hazards and a small-metadata binding error. This milestone validates storage mechanics and exact fixture outputs. It does not change the production backend default or establish five-model paged serving, capacity, or throughput.

## Implemented mechanics

`PagedKVPoolConfig.segmentSizeBytes` is an explicit opt-in; `nil` retains the fixed-slab path. The segmented path allocates stable combined K/V buffers in the configured BF16, FP16, or FP32 dtype, with each buffer bounded by both its segment target and Metal's maximum buffer length. A poison page in each segment is charged inside the byte grant and excluded from usable capacity. Total segment count is not constrained by a dispatch's binding limit.

Admission prepares every required segment privately across all geometry groups, then publishes backing and free-list changes together. A failed allocation unwinds without exposing partial growth; the admission reservation is refunded. Free segments retire after row/reservation release while preserving generation fencing against stale page handles. Segment growth preserves the identities and bytes of existing native buffers.

Attention uses the same softmax partition arithmetic as the fixed-slab reference. Host work records resolve physical pages into buckets with at most 17 segment bindings and 28 total buffers per dispatch. The whole numerical partition remains intact across physical segment boundaries. The tests compare output bits across multiple buckets, sliding-window wrap, softcap, sinks, and small head counts.

Transfers write directly into segment backing or one final native gather destination. The returned K/V slices share that destination through the pinned MLX slice implementation; there is no whole-prefix concatenation or second native gather buffer. Private admission allocations still require evaluation, but the transfer/attention changes add no host synchronization to the steady inference step.

## Failures found and corrected

The initial gather returned zero data when only its keys view was evaluated. MLX's `Depends` creates a buffer alias but does not encode a GPU read. A four-byte completion witness now consumes the transfer fence through a real Metal kernel, forcing the encoder's buffer barrier before host-visible completion. Partition merge now explicitly binds the final bucket fence for the same reason. These barriers protect writes made through stable input buffers that MLX cannot otherwise recognize as outputs.

The original one-/two-head merge fixture also reached a Metal address-space error: MLX bound metadata smaller than eight elements as a constant pointer, while the merge expected a device pointer. Both direct and segmented metadata are now padded to at least eight elements. Final tests restore those small-head cases; they are not excluded from the passing set.

| Attempt | Result |
|---|---|
| Run 1 | Gather failures and the small direct-merge metadata trap; retained |
| Run 2 | Diagnostic transfer/window snapshot failures, 56 issues; retained |
| Run 3 | Gather witness correction: six functions / 12 cases passed |
| Run 4 | Final merge barrier, small-head padding, and second-group failure injection: six functions / 19 cases passed in 7.239 s |

The final semantic build passed in 85.46 seconds. Cases include geometry and binding limits; allocation failure within the first group and after the first group's candidates were complete; exact transfer/growth/release/ABA checks in three dtypes; four-row decode across multiple buckets; and 18 sliding-window steps for every combination of BF16/FP16/FP32 and one/two/four query heads.

## Scope and remaining gates

The allocation-failure assertions compare existing backing identities, free queues, generations, and reservation counters before retry. Independent code review confirmed the private all-group publication boundary, native dtype preservation, bounded bindings, and the actual MLX encoder/slice behavior behind the dependency fix.

The prototype still derives its address range from an initial grant, and dispatch metadata is rebuilt for each decode. Dynamic grant resizing, smaller-machine/co-resident capacity, production recurrent paged restore, end-to-end SSD adoption, B1/B2/B4 model latency, and the final default switch remain separate work. The passing fixtures do not establish production memory capacity or a decode speed improvement. No KV quantization is included.

The [evidence manifest](evidence/paged-segment-foundation-2026-09-05/manifest.json) retains all four attempts' complete logs and source hashes. All 431 source/test hashes in the final snapshot were captured; the 13 owned files matched that tested snapshot. Every stored and decompressed evidence digest was rechecked. The native foundation is based on `b5d6c922bd7eec682eb1997c4868befe4efd02ee`; the final owned-source manifest records the exact delta used by run 4. Native commit `28c2635c801a80ca6721142dd2eb2428de764ece` banks that implementation. One blank EOF line in `PagedKVGroup.swift` was removed after testing; the retained overlay records both hashes, and executable content is unchanged.

Reproduce with the pinned local MLX dependency and regular pinned metallib, following [native test setup](../developer/test.md):

```sh
cd libs/mlx-swift-lm
swift package --scratch-path ../../provider-swift/.build --skip-update \
  edit --path ../mlx-swift mlx-swift
swift build --scratch-path ../../provider-swift/.build --build-tests \
  --jobs 4 --disable-automatic-resolution
MLX_METALLIB_PATH="$PWD/../../provider-swift/.build/arm64-apple-macosx/debug/mlx.metallib" \
  ../../scripts/run-nested-suite.sh CBv2PagedSegmentTests \
  --scratch-path ../../provider-swift/.build
```
