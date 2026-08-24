# 076 — Qwen frontier state river handoff

Date: 2026-08-24  
Status: **implemented as an ordered patch handoff; default off; M3 performance
and semantic quality pending**

## Scope

This advances the artifact-only Qwen text-prefill experiment from notes 050
and 054. The first full-layer prefix produces the last exact hidden rectangle.
Every later selected skipped layer then:

- passes historical hidden rows through unchanged;
- constructs its complete persistent history artifact from those rows
  (attention K/V or Gated DeltaNet convolution/FP32 SSM state);
- executes the terminal prompt row through that layer's complete attention/GDN,
  residual, and MLP path against the constructed history;
- passes the resulting frontier row to the next skipped layer.

The result is an approximate full-depth frontier with all ten attention caches
and all thirty recurrent states ready for ordinary decode. It is not equivalent
to native full-prompt Qwen and makes no quality claim.

## Execution contract

`Qwen35CBv2ForwardPhase` now separates:

- `prefillIntermediate`: skipped layers are artifact-only for every row;
- `prefillFrontier`: skipped layers build artifacts for all rows except the
  final row, then execute that row fully exactly once;
- `decode` and `mtp`: every layer keeps the complete checkpoint path.

Vision embedding prefill is explicitly assigned to the full `decode` phase, so
the text-only experiment cannot alter the vision path. With the experiment
unset or invalid, all phases select full layers.

Attention layers first commit history K/V, then invoke ordinary attention only
for the final query/K/V row. The final write therefore advances the cache by
one, not twice. GDN layers fold history into a private prefix state, consume the
final row once from that state, and stage only the post-frontier generation.

## Profiles and failure behavior

The enable flag remains mandatory:

```bash
export DARKBLOOM_QWEN35_PREFILL_ARTIFACT_ONLY=1
```

For the registered 40-layer target, no layer override selects the E=4 profile:

```text
full layers:     0-3
artifact river:  4-39
```

The E=8 target is explicit:

```bash
export DARKBLOOM_QWEN35_PREFILL_FULL_LAYERS=0-7
```

Explicit layer lists retain the strict parser from patch 053. An empty,
malformed, duplicate-invalid, or out-of-range configuration disables the
whole policy instead of partially applying it. The implicit E=4 profile is
registered only for the 40-layer geometry. An attention backend without the
cache-only commitment seam falls back to the complete layer before mutation.

## Regression coverage

The nested test handoff adds:

- direct attention comparison against a complete full-layer reference,
  including identical K/V and one exact logical offset advance;
- direct GDN comparison against both state-only history and complete full-layer
  references, including the post-frontier conv/SSM generation;
- phase isolation for intermediate, frontier, decode, MTP, and the default-off
  policy;
- explicit 40-layer E=4 and E=8 policy selection;
- B1/B2/B4 intermediate-plus-frontier transactions, exact cache offsets,
  recurrent commit/rollback, cancelled-row release, and survivor KV isolation.

B1 uses a one-row terminal chunk to cover the no-history frontier branch.
B2/B4 use a multi-row terminal chunk to cover history artifact construction.

## Ordered patch handoff

The root repository intentionally keeps the nested gitlink at
`ab73a827c9dde6f8802507003aa0be71605aab8e`. Apply:

1. `052-prefill-moe-topk.patch`
   (`sha256:8ceeb8599bab30969359041d20c149386d49443ec9fa9bf11c7b7fbe9cd9f50e`);
2. `053-cbv2-prefill-layer-skip.patch`
   (`sha256:4b0d739fc5daa0e52092d48dd3e5c2e430fd69561fe94909e73294e9715021a4`);
3. `054-cbv2-artifact-eight-state-cache-only.patch`
   (`sha256:52c29ff8291c1736939e1af2b90a1e59b7e3b87740700a1b18be8a265ab6502d`);
4. `055-cbv2-prefill-diagnostics-stderr.patch`
   (`sha256:c6ec5a4da275f8758474516ddf05ef0ba34f1501dbb8628ab3f4dfc010897945`);
5. `076-cbv2-frontier-state-river.patch`
   (`sha256:933d3e786b667215c07184d6e21a9277e602080231404ae4a2153d76bea11b83`).

Patches 052–055 produce local nested commit
`f45cadea2cf4a9257e667f03f367844f3d0da822` and tree
`b917a59270bca73560aefef2e16646c34176585a`. Patch 076 produces local nested
commits `4df7fc1f21a774f854d6319a2a0aba68f177093c`,
`98793a7a68586b7722731e913c5974fd75ac8815`, and
`420ece51556a45c3f0312f6e6dac4be45a318c1a`, with final tree
`6a0a3cede2f6032933450ac3556bc63ec464edd7`.

The parent agent owns the M3 throughput matrix and frozen semantic-quality
gate. This handoff records implementation, replay provenance, and regression
coverage only.
