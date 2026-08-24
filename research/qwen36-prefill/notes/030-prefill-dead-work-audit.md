# 030 — Exact Qwen 3.6 TEXT prefill dead-work audit

Status: **kept; one exact integer-work deletion captured as a named patch**

Scope: the exact Qwen 3.6 35B-A3B TEXT path measured by
`ArrivalInvarianceBenchmark`, from `benchmarkServingModel` through the first
sampled token. This is a dependency audit, not a throughput result. No M3 Max
runtime was available for this pass, so every time number below is either an
inherited measurement from notes 011/027 or an explicitly labelled upper
bound. No speedup is claimed.

## Verdict

There is no large removable floating-point block in the current graph that
meets the strict checksum contract.

One small deletion is exact:

- `gatherSort` computed `inverseOrder = argSort(order)`, sorting a permutation
  a second time only to invert it.
- `patches/030-inverse-permutation.patch` constructs the same integer tensor directly with
  `inverse[order[i]] = i` via `putAlong`.
- The patch changes no floating-point operation, shape, routing decision,
  expert order, reduction order, cache write, or eval dependency.
- A regression test compares the new result **exactly** against the removed
  `argSort(order)` implementation at 64, 136, and the target 16,384
  assignments, then verifies exact sorted-row round-trip.

The largest genuinely dead floating work is the last decoder layer's
non-frontier output. It is not changed here. Exploiting it would narrow Qwen's
final MoE from thousands of rows to one row, crossing `SwitchGLU`'s sorted
dispatch threshold and changing QMM geometry. That is mathematically
equivalent but not an arithmetic-identical execution, and E2 already proved
that shape changes can flip greedy checksums. Its generous whole-model ceiling
is only 2.42% at a 2,048-token pass and 3.10% at 8,192 tokens.

## 1. Numerical rule used by this audit

`GOAL.md` requires the current greedy/temp=0 token checksum, top-8 routing,
attention, KV writes, and GDN state. This audit therefore uses three classes:

1. **Exact deletion:** removes work while every surviving integer and
   floating-point operation and its order remain unchanged.
2. **Mathematical rewrite:** same real-number function, but changes a
   finite-precision operation order or kernel geometry. Rejected unless the
   exact checkpoint passes the Mac checksum gate.
3. **Semantic deletion:** removes a value that contributes to the sampled
   token or future cache/state. Rejected unconditionally.

E2 is the concrete warning: changing only chunk/batch geometry changed two of
four greedy checksums. “Same formula” is not enough.

## 2. Exact serving call graph

### 2.1 Benchmark to extracted target

`ArrivalInvarianceBenchmark.makeEngine` calls:

```text
EngineV2Factory.benchmarkServingModel(
    model: context.model,
    isVLM: true,
    modelDirectory: modelDirectory)
EngineV2Factory.makeProductionBuild(model: servingModel, ...) <!-- pragma: allowlist secret -->
```

For this checkpoint the loaded wrapper is `MLXVLM.Qwen35MoE`.
`benchmarkServingModel` calls
`EngineV2VLMTextExtraction.extractTextModel` and returns its
`MLXLLM.Qwen35MoEModel` target.

Extraction makes two exclusions before serving:

- `decodeQwenConfiguration` sets `mtp_num_hidden_layers = 0`, so the target
  skeleton has no inline MTP module.
- `reKeyedQwenTargetWeights` retains only keys beginning with
  `language_model.`. Top-level `mtp.*` and `vision_tower.*` arrays are not in
  the serving target.

The benchmark does not pass `mtpDrafter` or `mtpConfig` to
`makeProductionBuild`, so their defaults are `nil` and <!-- pragma: allowlist secret -->
`CBv2MTPConfig(enabled: false)`. MTP execution is unreachable from this
benchmark even though the combined artifact contains MTP weights.

### 2.2 Scheduler to narrowed prompt forward

For each planned prompt assignment, `EngineLoopV2.executeMixed` sets:

```text
samples = numComputedTokens == effectiveTokenCount
requirement = samples ? lastPositionLogits : evaluationOnly
```

Equal-length TEXT rows may be packed into `[B,L]`; a singleton uses `[1,L]`.
TEXT has no multimodal span and no request position state, so Qwen reaches:

```text
executeMixed
  -> targetForward(requirement:)
  -> CBv2SteppableLanguageModelAdapter.recurrentPrefill
  -> Qwen35Model.cbv2RecurrentPrefill
  -> Qwen35TextModel.cbv2RecurrentPrefill
  -> Qwen35TextModelInner.cbv2Forward
```

`targetForward` first binds one request-owned recurrent transaction per row.
After the lazy model graph is built, it calls `evaluation.evaluate()` for
every row and returns those roots to the step.

### 2.3 Every Qwen layer

`Qwen35TextModelInner.cbv2Forward` embeds every input token, then traverses all
40 layers:

- layers 0–2, 4–6, ..., 36–38: 30 `Qwen35GatedDeltaNet` layers;
- layers 3, 7, ..., 39: 10 `Qwen35Attention` layers;
- every layer then executes `Qwen35SparseMoeBlock`.

Each decoder layer is:

```text
r = GDN-or-full-attention(inputLayerNorm(x))
h = x + r
out = h + MoE(postAttentionLayerNorm(h))
```

After layer 39, prompt narrowing is:

```text
evaluationOnly:
    hidden[..., -1, 0..<1]
lastPositionLogits:
    lmHead(model.norm(hidden[..., -1, :]))
```

Finally `executeMixed` submits one `asyncEval` containing the sampled token or
evaluation handle, all full-attention cache inner state, and all staged GDN
roots. The next `finalize` boundary commits or rolls back the recurrent
transaction.

## 3. Dependency proof by requested component

### MTP blocks — already absent

The extracted target forces zero MTP layers, excludes `mtp.*` weights, and the
benchmark engine has no drafter and disabled MTP config.

- Runtime work in this TEXT prefill graph: **0 FLOP, 0 kernels**.
- Removable critical-path upper bound: **0 ms, 1.000x**.
- Action: none. Deleting MTP code would affect other serving modes, not this
  graph.

### Vision tower — already absent

The target receives only `language_model.*` weights. TEXT rows have no
`multimodalByID` span, so neither `visionFeatures` nor embedding-splice
forwarding is called.

- Runtime work: **0 FLOP, 0 kernels**.
- Removable critical-path upper bound: **0 ms, 1.000x**.
- The original VLM wrapper remains resident in its model container, but
  residency is not prefill graph work on this 128 GiB machine.

### LM-head rows — already narrowed to the minimum

For an intermediate chunk, Qwen performs no final RMSNorm and no LM head. For
the frontier chunk it normalizes and projects exactly one row per request.

One required row costs:

```text
2 * hidden * vocab
= 2 * 2,048 * 248,320
= 1,017,118,720 FLOP
```

Every vocabulary row is needed to determine exact greedy argmax. A fused
projection+argmax could reduce storage, not arithmetic, and would change the
reduction implementation.

The already-shipped narrowing deletes `(N-1) * 1.017 GFLOP` versus a full
`[B,L,vocab]` projection: about 2.08 TFLOP at `N=2,048` and 8.33 TFLOP at
`N=8,192`. Note 011 bounds the latter at about 0.95 s. There are no remaining
dead LM-head rows.

### Shared expert and shared gate — required

Every layer computes:

```text
sharedY = sharedExpert(x)
sharedY = sigmoid(sharedExpertGate(x)) * sharedY
return routedCombined + sharedY
```

This sum enters the next layer, including for the frontier row. The shared
branch is not a router fallback or training auxiliary.

- Cost: `6,295,552 FLOP/token/layer`, about
  **0.252 GFLOP/token across 40 layers**.
- Note 011's wall allocation is about **4%** of a 2,048-token pass.
- Deletion class: semantic; checksum must change in general. Rejected.

### Router logits, precise softmax, top-8, and renormalization — required

Each MoE layer does:

```text
gate(x) -> precise softmax over 256
        -> argPartition top 8
        -> takeAlong
        -> divide selected scores by their selected sum
```

Router logits determine expert IDs; selected probabilities determine the
weighted residual. Both affect every following layer.

The tempting rewrite “top-8 raw logits, then softmax only those 8” is equal in
real arithmetic because softmax is monotone and the full denominator cancels.
It is not the same finite-precision graph: it removes 248 exponentials and
changes two sums/divisions per token per layer.

- Candidate deletion: about **9,920 exponentials/token** plus full-width
  elementwise passes across 40 layers.
- Inherited component-model ceiling: the entire router/top-8 bucket is only
  **<0.8%**, or
  **<9.8 ms** of note 011's measured 1,225 ms pass. The softmax-only fraction
  is smaller.
- Deletion class: mathematical rewrite, not exact arithmetic. Rejected.

### GDN recurrent state — all 30 layers are live

For each token, `processChunk` updates the convolution tail and fp32 SSM state.
That state is the initial condition for later prompt chunks and decode.
`cbv2Forward` stages each row's final state into its recurrent transaction.

The GDN output at every prompt position is also input to the next decoder
layer. Dropping intermediate positions would change later full-attention K/V
and the final token.

- Recurrent scan cost: **0.110 GFLOP/token** across 30 layers, about
  **225 GFLOP** at 2,048 tokens.
- Even making the whole scan free is only about **2.14% / 1.022x** by note
  026's FLOP bound, roughly **26 ms** at the inherited pass rate.
- Chunkwise or associative scans change fp32 operation order. Rejected by the
  exact contract even before considering that the state itself is required.

### Attention masks — no duplicate text mask

Qwen's CBv2 branch does not build the legacy `createAttentionMask`. Each cache
owns causal attention and row-local history. Queries use the cache's
pre-update absolute offsets; `updateAndAttend` then writes K/V and advances the
offset.

For layers 3–35 every query result feeds the next layer, so the causal mask is
semantic. For final layer 39, earlier query outputs are dead, and the newest
query can see every key in history plus the current chunk. That one query is
mask-free; `CBv2LastQueryPrefillLayerCache` already expresses this for
eligible models.

This final-layer opportunity is quantified under “intermediate outputs”
below. No mask array or mask pass exists separately to delete on the current
TEXT path.

### KV writes — all are required

Only the 10 full-attention layers own KV. Every prompt token's K and V are
needed by later prompt chunks and decode, including all layer-39 K/V even
though non-frontier layer-39 outputs are discarded.

- Storage: `2 KV heads * 256 dim * K/V * 2 bytes * 10 layers`
  = **20,480 bytes/token**, or about **42 MB** at 2,048 tokens.
- Ideal 400 GB/s copy floor: about **0.1 ms**; note 011 allocates the complete
  cache machinery about 0.3% of the pass.
- Deletion class: semantic. Any missing write changes later attention.

### Intermediate outputs — one real but unqualified tail

Layers 0–38 must emit all positions: layer `i+1` computes K/V or recurrent
state from them. Layer 39 is different. Once its full K/V rectangle is
committed, only:

- no layer-39 output row for `.evaluationOnly`, or
- the newest layer-39 output row for `.lastPositionLogits`

can affect first-token generation or future state.

For a fresh 2,048-token pass, a generous deletion ceiling removes layer 39's
non-frontier Q/gate projection, attention, O projection, and MoE:

```text
Q + O                       = 50,331,648 FLOP/token
MoE                         = 57,675,776 FLOP/token
dead causal attention      = 34,342,961,152 FLOP/pass
dead final-layer total     = 255,434,158,080 FLOP/pass
whole pass                 = 10,553,344,000,000 FLOP
fraction                   = 2.420%
free-work speedup ceiling  = 1.0248x
rate-calibrated time       = 29.7 ms at 8.61 TFLOP/s
```

At 8,192 tokens the same upper-bound calculation is **1.434 TFLOP**, 3.096%
of the note-011 pass model, or about **163 ms** at 8.8 TFLOP/s
(`1.0319x` if free).

Why it is not implemented:

1. The cache primitive can preserve full K/V and exact newest-query
   visibility.
2. But Qwen layer-39 MoE narrowing changes assignments from `N*8 >= 64`
   (sorted gathered QMM) to 8 (unsorted small-row dispatch).
3. Projecting Q only for the last row also changes linear-kernel M geometry.
4. Those are different finite-precision executions. Existing Gemma tests use
   logit tolerance plus greedy equality, not bit-identical logits.
5. E2 showed that Qwen greedy checksums can flip solely from shape changes.

Therefore this is proven dead in the dependency graph but not proven safe
under the required arithmetic/checksum contract. It needs a separately
pre-registered M3 full-checkpoint experiment, not an audit patch.

### Duplicate sorting and unsorting

`gatherSort` performs:

```text
order        = argSort(expertIndices)
inverseOrder = argSort(order)
```

The first sort is live: it groups assignments for
`gatherQuantizedMM(sortedIndices: true)`. The inverse tensor is also live:
`scatterUnsort` must restore original `[token, topK]` assignment order before
weights are reduced.

The **second sorting algorithm** is unnecessary. `order` is a permutation, so
its inverse is exactly:

```text
inverseOrder[order[i]] = i
```

The implemented `putAlong(zeros, order, arange)` computes that identity with
integer scatter. There are no duplicate destinations and no floating values.

At the target pass shape:

```text
assignments A                   = 2,048 * 8 = 16,384
removed inverse sorts/pass      = 40
comparison-sort envelope        = 40 * A * ceil(log2 A)
                                = 9,175,040 key comparisons
B=4, P=2,048 (four passes)      = 160 sorts / 36,700,160 comparisons
floating-point FLOP changed     = 0
```

MLX may use radix rather than comparison sort, so that comparison count is an
algorithmic envelope, not a measured kernel count. A conservative wall-time
ceiling is the **entire** note-011 `gatherSort` bucket: about **2%**, 24.5 ms
per 2,048-token pass, 98.7 ms for the B=4 burst, at most `1.020x`. The second
sort is only a subset of that bucket, so actual gain must be smaller.

The later `scatterUnsort` is not dead. A direct weighted unsort could avoid
about 11 GB of activation traffic per pass, but it changes the BF16 reduction
implementation and Qwen does not call the existing Gemma-only primitive.

- Entire unsort+reduce upper bound: **3%**, about **36.8 ms / 1.031x** if
  made free.
- Deletion class: mathematical/kernel rewrite with prior decode/uptime
  regression history. Rejected here.

### Eval barriers and roots — no duplicate execution

Qwen's layer loop contains no `eval`. One `asyncEval` is issued per engine
step. Its several roots overlap transitively, but MLX evaluates the shared
lazy graph once; listing cache, recurrent, and sampled/output roots does not
re-run their common ancestors.

The roots have distinct obligations:

- output handle or sampled token: force the requested terminal;
- cache inner state: materialize K/V and collapse lazy offset chains;
- recurrent roots: materialize staged conv/SSM state before commit.

`finalize` is the transaction boundary that decides commit versus rollback.
Removing it would let the scheduler observe uncommitted state.

For context, note 026's intentionally loose B=4 8K ceiling assigned less than
0.79 s (<4%) to deleting 12 step boundaries, but the 66.2 ms fitted intercept
also includes a weight stream and launches. It is not an eval-barrier
measurement. At B=1/P=2,048 there is only one required prefill submission.
There is no duplicate barrier that can be deleted exactly.

## 4. Exact deletion artifact and test

The implementation and regression test are preserved in:

- `research/qwen36-prefill/patches/030-inverse-permutation.patch`

It applies inside `libs/mlx-swift-lm` to:

- `Libraries/MLXLMCommon/SwitchLayers.swift`;
- `Tests/MLXLMTests/SwitchGLUTests.swift`.

The dependency commit was created locally as `c553e80`, but the authenticated
cloud bot has read-only access to `Layr-Labs/mlx-swift-lm`; its push was
rejected with HTTP 403. The parent repository therefore deliberately retains
the fetchable `ab73a82` gitlink instead of recording a dangling submodule
commit. `program.md` explicitly permits a named patch for this state.

The test preserves the old implementation as its oracle:

```text
legacyInverse = argSort(argSort(indices))
newInverse    = gatherSort(...).inverseOrder
assert newInverse == legacyInverse exactly
assert sortedRows[newInverse] == originalRows exactly
```

It covers:

- 64 assignments: `SwitchGLU`'s sorted-dispatch threshold;
- 136 assignments: duplicates plus an irregular, non-power-of-two count;
- 16,384 assignments: exact target pass geometry.

Because the inverse arrays are exactly equal, every downstream gather,
quantized projection, scatter, BF16 multiply, and reduction receives the same
indices in the same order. This is stronger than a token-checksum test: the
floating graph is unchanged.

## 5. Final candidate ledger

| Candidate | Maximum removable work | Strict status |
|---|---:|---|
| MTP target/assistant in benchmark prefill | 0 FLOP / 0 ms | already absent |
| vision tower in TEXT prefill | 0 FLOP / 0 ms | already absent |
| intermediate LM-head rows | 2.08 TFLOP at N=2K; already removed | already optimal |
| frontier LM-head vocabulary columns | none | all needed for exact argmax |
| shared expert/gate | 0.252 GFLOP/token | semantic, reject |
| full-256 router softmax | <0.8% whole router bucket | operation order changes, reject |
| GDN recurrent scan/state | 225 GFLOP at N=2K; <=2.14% | state is semantic, reject |
| text attention mask | no separate mask pass | semantic except final query |
| KV writes | 42 MB at N=2K | semantic, reject |
| layer-39 non-frontier output | 255 GFLOP / 29.7 ms / 2.42% at N=2K | dead but kernel geometry changes; reject |
| first expert-index sort | part of <=2% gather bucket | required by sorted QMM route |
| second sort used only to invert permutation | 40 sorts/pass; <=2% absolute ceiling | **exact deletion captured in named patch** |
| scatter + weighted reduction | <=3% / 36.8 ms | reduction/kernel changes, reject |
| step eval/finalize | <4% loose B4-8K envelope | transaction/state boundary, reject |

## Conclusion

The current TEXT graph has already removed the two large obvious islands:
vision/MTP execution and unused LM-head rows. All 39 pre-final layers, all GDN
state, all 10 layers' KV writes, every shared expert, and router probabilities
are on a dependency path to the first token or its required future state.

The final decoder layer contains about 2–3% mathematically dead token-local
work, but exploiting it changes Qwen kernel geometry and is not checksum-safe
by proof. The only deletion that meets the stronger “same arithmetic” rule is
the redundant inverse-permutation sort. Its named patch is deliberately
small, exact, and test-covered; its full-pass speedup cannot exceed the
inherited 2% gather-bucket estimate and is expected to be well below that.
