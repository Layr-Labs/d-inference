# 072 — E40/E41 exact-adoption divergence diagnostics

Status: **awaiting Apple Silicon rerun**

## Hypotheses

The diagnostic run tests these competing causes in parallel:

1. **A — adopted memory layout:** compact snapshot materialization changes K/V
   or recurrent-state strides/capacity, selecting a numerically different Metal
   reduction despite equal visible boundary values.
2. **B — decode scheduling:** cold and warm rows enter different mixed/chained
   paths or cohorts after the cached frontier, so batch geometry is the first
   source of different logits.
3. **C — recurrent restore:** restored convolution/SSM state is equal at
   adoption but aliases, lays out, or advances differently on the first decode.
4. **D — position/cursor:** `numComputedTokens`, K/V offsets, or effective
   position IDs are off by one after a full-prompt hit.
5. **E — frontier logits:** cached and native prompt-frontier logits have the
   same greedy token but differ numerically enough to seed later divergence.

E42 already makes E unlikely as the sole cause, but the probe retains it so the
first differing boundary is measured rather than inferred.

## Instrumentation

The temporary source and integration patch are:

```text
patches/072-DivergenceDiagnosticsV2.swift
patches/072-e40-e41-divergence-instrumentation.patch
```

The benchmark registers cold, construction, and warm request IDs. Four
environment-gated NDJSON log points capture:

- benchmark phase/scenario/row identity;
- scheduler assignments, path, cohort, pending samples, and input range;
- snapshot versus adopted K/V and recurrent layout;
- pre/post-forward K/V and conv/SSM checksums, offsets, shapes, strides,
  backing token capacity, effective position IDs, and logits top five.

All reductions ride the ordinary step evaluation and read back at the existing
finalization fence. The probe is disabled unless
`DARKBLOOM_PREFIX_DIVERGENCE_DEBUG=1`.

## Minimal Apple Silicon rerun

Start from root commit `a8415bfd` with the nested library reset to
`ab73a827c9dde6f8802507003aa0be71605aab8e`:

```bash
root=$PWD
git -C "$root/libs/mlx-swift-lm" checkout \
  ab73a827c9dde6f8802507003aa0be71605aab8e
for patch in \
  060-exact-cbv2-prefix-boundary.patch \
  061-cbv2-simultaneous-prompt-fork.patch \
  065-exact-sequential-prefix-boundaries.patch
do
  git -C "$root/libs/mlx-swift-lm" apply \
    "$root/research/qwen36-prefill/patches/$patch"
done
cp "$root/research/qwen36-prefill/patches/072-DivergenceDiagnosticsV2.swift" \
  "$root/libs/mlx-swift-lm/Libraries/MLXLMCommon/ContinuousBatchingV2/DivergenceDiagnosticsV2.swift"
git -C "$root/libs/mlx-swift-lm" apply \
  "$root/research/qwen36-prefill/patches/072-e40-e41-divergence-instrumentation.patch"

cd "$root/provider-swift"
swift build -c release --product darkbloom
```

Delete `/opt/cursor/logs/debug.log`, then run one 8K/64-token iteration:

```bash
DARKBLOOM_PREFIX_DIVERGENCE_DEBUG=1 \
DARKBLOOM_PREFIX_DIVERGENCE_MAX_DECODE_STEP=6 \
DARKBLOOM_PREFIX_BENCH_CACHE_MAX_BYTES=2147483648 \
.build/release/darkbloom benchmark \
  --model qwen3.6-35b-a3b-vl-mtp-mxfp8 \
  --qwen-prefix-reuse \
  --qwen-prefix-corpus Benchmarks/QwenPrefixReuse/qwen-prefix-natural-v1.json \
  --qwen-prefix-prompt-tokens 8192 \
  --qwen-prefix-decode-tokens 64 \
  --qwen-prefix-iterations 1 \
  --kv-backend contiguous \
  --qwen-prefix-output /tmp/e43-divergence.json
```

The debug run deliberately leaves instrumentation in place until its pre-fix
and post-fix logs are compared. It must be removed before the final fix ships.
