# 072 — E40/E41 exact-adoption divergence diagnostics

Status: **E43 reproduced; causal prefill-posture verification pending**

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

The benchmark registers cold, construction, and warm request IDs. Five
environment-gated NDJSON log points capture:

- benchmark phase/scenario/row identity;
- scheduler assignments, path, cohort, pending samples, and input range;
- snapshot versus adopted K/V and recurrent layout;
- pre/post-forward K/V and conv/SSM checksums, offsets, shapes, strides,
  backing token capacity, effective position IDs, and logits top five.
- activation of the diagnostic chunk-size/unpacked-prefill intervention.

All reductions ride the ordinary step evaluation and read back at the existing
finalization fence. The probe is disabled unless
`DARKBLOOM_PREFIX_DIVERGENCE_DEBUG=1`.

## E43 findings

The 8K/64-token, one-iteration M3 Max run produced 2,148 NDJSON events. The
evidence moves the root cause before adoption:

- Native B1 prefill used four 2,048-token forwards (log lines 2–5). Exact-cache
  construction used thirty-two 256-token forwards (lines 78–109), because
  every cache block must become a finalized recurrent boundary.
- The resulting cold and construction frontiers already differed in 79 of 80
  state probes and in logits (lines 7 and 111), before any cached state was
  adopted. Both logits still selected token 11.
- Adoption preserved the donor values. The construction frontier and warm
  exact frontier had identical state checksums and logits (lines 111, 182,
  and 185). Their only visible layout difference was compact convolution-tail
  stride; the first decode canonicalized it without changing a value.
- B1 donor and warm decode used the same path, cohort, cursor, input positions,
  state checksums, and logits for every captured step (lines 113–123 versus
  187–197). Their complete 64-token continuations were identical.
- B2 and B4 warm continuations also matched the solo construction donor for all
  64 tokens despite different decode cohort widths. Decode batching therefore
  does not explain the reported mismatch.
- Native B2 and B4 used the same 512-token chunk schedule but produced
  different frontier state/logit checksums (lines 274 and 557). Rectangular
  prefill cohort width is a second numerical-posture dimension.

Hypothesis verdicts:

1. **A — rejected as causal.** Adoption changes storage/view strides, but B1
   state and logits remain exact after the first decode.
2. **B — rejected for decode; confirmed for prefill.** Decode paths preserve
   the donor trajectory. Prefill chunk/cohort geometry is the first difference.
3. **C — rejected.** Restored recurrent shapes, dtypes, bytes, and values match
   the donor and advance identically.
4. **D — rejected.** Cursors, offsets, and effective positions match.
5. **E — observed, not causal by itself.** Frontier logits differ between
   native and donor postures, but so does persistent state; cached logits match
   the donor exactly.
6. **F — confirmed.** A 2,048-token solo forward and eight 256-token forwards
   are numerically different executions of the same prompt prefix.
7. **G — confirmed.** Packed prefill width changes finite-precision state even
   when token content and 512-token chunk sizes are identical.

The current `cold == warm` report compares two legal but numerically different
prefill execution postures. It does not demonstrate cache corruption: every
warm full hit reproduces its donor exactly.

## Causal verification control

Two temporary, diagnostics-gated controls can canonicalize the native arm to
the donor posture:

```text
DARKBLOOM_PREFIX_DIVERGENCE_FORCE_CHUNK_TOKENS=256
DARKBLOOM_PREFIX_DIVERGENCE_FORCE_UNPACKED_PREFILL=1
```

They are not a shipping fix: forcing all prefill through solo 256-token
forwards would discard the measured packed/large-stripe throughput. The next
run should verify that this intervention restores complete token equality; the
shipping decision can then separate donor-fidelity correctness from
scheduler-posture numerical invariance and apply the fixed quality gate.

## Minimal Apple Silicon rerun

Start from this diagnostic branch head with the nested library reset to
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
DARKBLOOM_PREFIX_DIVERGENCE_FORCE_CHUNK_TOKENS=256 \
DARKBLOOM_PREFIX_DIVERGENCE_FORCE_UNPACKED_PREFILL=1 \
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
