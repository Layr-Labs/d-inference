# Additive state lifetime ledger

The same ordinary owner holds its original full/window rows and original
`windowTemporaryBytes`. No discount is taken for buffers that might alias or
be released early. The new terms are separate K/V allocations, so the resource
owner must apply allocator rounding to each term individually.

| Term | Lifetime | Logical bound per layer, both K and V |
| --- | --- | --- |
| Existing row storage | Request lifetime | Full: maximumTokens; window: W |
| Existing window temporary | Ordinary request allowance, kept during verification | W + (W - 1 + maximumChunkTokens) |
| Additional staged tensor | Forward construction through commit | k + 1 |
| Additional chronological view | `stageSpeculativeUpdate.snapshot()` through eval | W + k + 1 (conservative; first snapshot is at most W) |
| Additional commit backing | Ring commit and completion | W |
| Captured backing, selected rows only | Before writes through reconciliation completion | Full: maximumTokens; window: W |
| Captured chronology, selected window only | Before writes through reconciliation completion | W |

Multiply each token count by `2 × actualKVHeads × actualHeadDimension ×
observedElementBytes`. `additionalArrays` splits the leading factor 2 into
separate names. The ordinary window temporary carries the old ring version and
the borrowed `W - 1 + maximumChunkTokens` concat; verification does not replace
or subtract it. The extra chronological term also accounts for the pre-write
snapshot feeding the staged update. Ring commit performs at most two slice
updates; the ordinary old-ring term plus the extra commit-backing term remain
charged while the new ring is evaluated. Stage keeps no growing round history:
one stage only, then reconciliation or whole-owner retirement.

Only `stagedWindowBytes` raises the backend's *row-accounting* ceiling, because
that backend counts rings/full storage plus staged K/V, but not borrowed
views, captures or graph temporaries. All additional terms still must be
charged by the outer resource owner. The backend ceiling is not a process
allocation limit and is restored only after actual commit writes complete.

For 25 windows (8×256, W=1024), five full rows (2×512), maxTokens=4224,
maxChunk=64, width=4, captures [28,29], BF16:

- Ordinary row logical capacity: 296,222,720 B.
- Ordinary window temporary retained unchanged: 432,332,800 B.
- Additional staged K/V: 819,200 B.
- Additional chronological views: 210,534,400 B.
- Additional commit backing: 209,715,200 B.
- Two captures including window chronology: 34,078,720 B.
- Total additional logical state: **455,147,520 B**, before per-array rounding.
- Temporary backend row-accounting ceiling: 297,041,920 B.

The F32 homogeneous case is exactly twice these logical bytes; mixed dtypes
use each actual observed layer type and the existing widest-dtype backend
reservation. This is an additive conservative finite-buffer ledger, not a
claimed minimal allocation or a measured native/physical peak. It remains
constant across P4096/O128 frontiers while a full width fits; near the end the
caller must taper the width without extending maxTokens.

The following are **not** covered by this state-only value: width-4 transformer
activations/workspaces; four full-vocabulary logits and optional softcap/head
intermediates; preNorm hidden; selected parameter cast caches; assistant model
and caches; assistant history/finalization; copies or transport staging for
full29/window28 seeds; old external assistant captures overlapping new seeds;
host encoding; export/snapshot bytes. The existing Gemma owner must derive and
admit those terms from the real adapter's lifetimes. External assistant views
cannot outlive their separately accounted lease merely because reconciliation
has released this transaction's internal captures. Real measurements remain
necessary and must preserve allocator/native-error/OS gates and retirement.
