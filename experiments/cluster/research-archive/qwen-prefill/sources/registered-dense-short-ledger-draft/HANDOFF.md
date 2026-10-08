# Registered short request memory ledger

Prepared 2026-09-14 outside Git. Source and synthetic CPU arithmetic only. Swift
compilation, native allocator evaluation, model work and runtime integration are
root-owned and have not been performed by this author.

The five new Foundation-only sources implement
`QwenDenseShortRequestLedger.derive(profile:plan:request:scope:allocationFootprintUpperBound:)`.
The callback has type `(Int) throws -> Int`; the private native owner must supply
`Memory.allocationFootprintUpperBound(byteCount:)` and retain its actual allocator
source/resource evidence. The ledger cannot verify callback provenance or grant
permission. It stores scalar results, never the closure or an MLX object.

The actual recorded request binds exactly 3 prompt IDs, chunk 2, one supplied
teacher ID and output count 2, batch one. Frontiers are 2/3/4. CBv2 reserves
prompt+output = **5** slots. Exact profile/config/manifest/artifact/inventory and
**default** 16/16 or 32/32 Plan identities remain bound. A different legal 9B cut
is refused here. Invalid Plan/history is refused before allocator callbacks.
Raw prompt/teacher file pins remain the new owner admission's responsibility.

The closed scopes are `.fullReference` and `.sequentialStagePair`. The pair has
two simultaneously resident stage owners with disjoint state ownership, even
though its computation is sequential. The full model is released before either
stage leg. The two scopes have distinct fingerprints and neither includes the
resident weight or loader-host terms supplied by the materializer's `R/H` ledger.

`forwardReserveBytes` is a named operational allowance `Q`:

- State: per-array F32 KV capacity plus offsets and three recurrent generations,
  matching the existing checked named formula at 5/2. Logical snapshots instead
  retain actual BF16 KV/conv and F32 SSM at each frontier. The existing 512 MiB
  named-state ceiling is retained independently of total Q.
- Fusion: concatenate the actual four GDN projection triplets along row zero.
  Each layer's weight/scales/biases buffer is rounded independently. Their logical
  sum must equal the registered storage identity's fusion term. This permits all
  fused banks to overlap old parameter/cache storage; it does not assert a
  permanent duplicate model. The 8K storage type is used only for this identity,
  never for its request/state/partial-ledger values.
- Named workspace allowance: each covered layer's six hidden-shape expressions,
  four dense MLP gate/SiLU/up/product expressions, Q+gate and K/V projections,
  GDN fused projection and convolution input. All are widened to F32. Dense score
  and softmax shapes are charged as a fallback allowance, not a kernel dispatch
  assertion. Counting all layers is an allowance rather than measured liveness.
- Native final BF16 row and F32 diagnostic cast, current input tokens, and for
  the pair two widened residual arrays. State generation and workspace terms
  can overlap; they are deliberately not credited against each other.
- CPU logical copies: two retained baseline BF16 rows plus two F32 value arrays;
  the pair additionally retains two candidate F32 arrays and one transient raw
  candidate row. One maximum state-component copy is charged. Pair boundary
  comparison adds two widened CPU copies. `includeBytes:false` keeps no raw
  multi-frame state history; metadata object overhead is still unknown.

Every named native array calls the supplied bound before multiplication by its
instance allowance. Products, sums, under-bounds, maximum 256 entries and repeated
owner/name pairs are checked. Errors propagate unchanged; no partial ledger is
returned. The callback must be stable for the current allocator and must not run
model operations. Returned booleans keep execution and allocator provenance false.

**Q is not a whole-process peak.** Kernel/quantized matmul scratch, additional
GDN/attention intermediates, graph/view retention, allocator cache behavior,
Foundation/JSON buffers and OS/framework overhead remain unmeasured. The separate
live owner policy is expected to require actual free
`max(6 GiB, R + 2H + Q + 4 GiB)` and allocator headroom
`active + cache + R + H + Q + 2 GiB`, plus pressure/zero-swap/deadline/max-buffer
checks. Its 4/2 GiB headroom is operational policy, not a proven scratch bound.
No allocator calculation qualifies M3 or admits 27B arithmetic/provider support.

The independent Python substitution in `vectors.json` uses the deliberately
invented identity allocator, **not a device bound or admission threshold**:

| Metadata | 9B | 27B |
|---|---:|---:|
| Final logical state at frontier 4 | 51,642,400 B | 154,206,272 B |
| Logical native capacity-5 state | 51,675,168 B | 154,271,808 B |
| F32 named state/snapshot/two-boundary formula | 160,563,232 B | 474,562,624 B |
| Full fusion logical allowance | 683,016,192 B | 2,278,195,200 B |
| Full Q, invented identity allocator | 873,827,368 B | 2,826,550,344 B |
| Pair Q, invented identity allocator | 876,441,640 B | 2,829,197,384 B |

The root compile list is `compile-inputs.json`: 21 actual Swift sources including
five new core files, two new fixture files and the existing shared TestSupport.
Use the sole existing `Tests/RegisteredDenseProfiles/retained-inputs.json` on stdin;
no metadata copy is included. The prospective fixture expects **31 positive / 42
rejection checks**, with invented allocation bounds, wrong Plan/history refusal
before callbacks, capacity/frontier distinctions, byte vectors, scope conservation,
per-buffer padding, shape/product/sum overflow and original callback errors.
These Swift fixtures are unexecuted here. The separate Python/source receipt
records only the checks this author actually performed.
