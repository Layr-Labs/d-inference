# 072 — E40/E41 exact-adoption divergence diagnostics

Status: **E45 confirmed prefill posture as causal; shipping profile implemented**

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

The temporary source and integration patch were:

```text
patches/072-DivergenceDiagnosticsV2.swift
patches/072-e40-e41-divergence-instrumentation.patch
```

They were deleted after E45 established causality. No NDJSON logging, diagnostic
environment override, tensor readback, or benchmark registration remains in the
shipping handoff.

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

## E44 findings

E44 did not execute either causal control, so its unchanged equality rates do
not test whether chunk/packed posture is sufficient:

- The branch commit that introduced the controls was created at 16:45 UTC, but
  the Mac binary was built at 16:28 UTC. The report was produced at 16:53 UTC.
- The exact Mac sources used by that binary contain the E43 probes but contain
  neither `forcedPrefillChunkTokens` nor `forcesUnpackedPrefill`.
- No `diagnostic prefill posture override` event exists in the 2,148-line log.
- Cold B1 still ran four 2,048-token forwards while its construction donor ran
  thirty-two 256-token forwards (lines 2-5 versus 78 onward).
- Cold B2 and B4 still ran packed 512-token forwards (lines 256 and 537);
  B4's frontier explicitly reports `packed-prefill-frontier` (line 554).

Hypothesis verdicts for the E44 fork:

1. **H1 — stale binary/source: confirmed.** The executable predates the
   control commit and its source lacks both hooks.
2. **H2 — environment values absent or malformed: inconclusive.** The stale
   executable could not read or report those controls regardless of the
   launching environment.
3. **H3 — parsed controls failed only for cache-disabled records: not
   exercised.** Their scheduler records never received the new override code.
4. **H4 — 256-token unpacked posture is insufficient: inconclusive.** No E44
   cold arm used that posture.

The revised probe logs
`instrumentationRevision=e45-prefill-control-proof-v1` and the raw and parsed
environment values unconditionally for every registered phase. Every scheduler
event now also records the row's effective `exactSnapshotBlockSize` and the
engine's effective `packedPrefillSupported` value. This makes a stale binary,
missing environment, cache-disabled override failure, and a genuinely
insufficient posture distinguishable in the first few NDJSON lines.

## E45 findings

The rebuilt control executed with a 256-token boundary and packed prefill
disabled in every cold, construction, and warm arm. It restored 100% first-token
and complete 64-token equality for every B1/B2/B4 full-hit and partial-prefix
scenario. The intervention is therefore causal, not merely correlated.

The combined verdict is:

1. **Adopted state/layout — rejected.** Warm rows reproduce their donor.
2. **Decode scheduling — rejected.** Donor and warm trajectories stay equal
   across B1/B2/B4.
3. **Chunk geometry — confirmed.** Native large-stripe and block-sized donor
   prefills differ before adoption; equalizing them restores full parity.
4. **Packed prefill geometry — confirmed.** Singleton and rectangular prompt
   cohorts differ; disabling packing under the exact-cache profile restores
   full parity.

The canonical E45 cold controls are slower than the former native cold arms.
The 75%, 87.5%, and full-hit cache paths still retain their measured timing
advantage, but that comparison must use the canonical cold baseline selected by
the same exact-cache instance.

## Shipping profile

E45's two temporary controls are now represented by one default-off execution
policy selected by an active exact-state cache:

```text
text prefill boundary = ExactPrefixCacheV2.exactSnapshotBlockSize
packed prefill = disabled
```

The profile is engine-instance scoped, not lookup-result scoped. It applies to
cache-disabled controls, misses, and partial-hit suffixes, so changing
`prefixCacheEnabled` or moving from miss to hit cannot change prompt execution.
No exact cache means the old chunking and packed-prefill gates execute
unchanged. The provider policy identity is bumped to
`darkbloom.cbv2-exact-prompt-state-v3`.

## Apple Silicon shipping verification

Start from the fetchable nested base, apply all four ordered patches, then
compile the focused regressions and release binary:

```bash
root=$PWD
git -C "$root/libs/mlx-swift-lm" checkout \
  ab73a827c9dde6f8802507003aa0be71605aab8e
for patch in \
  060-exact-cbv2-prefix-boundary.patch \
  061-cbv2-simultaneous-prompt-fork.patch \
  065-exact-sequential-prefix-boundaries.patch \
  073-exact-cache-canonical-prefill-profile.patch \
  075-exact-cache-donation-reservations.patch
do
  git -C "$root/libs/mlx-swift-lm" apply \
    "$root/research/qwen36-prefill/patches/$patch"
done

git -C "$root/libs/mlx-swift-lm" diff --check
cd "$root/libs/mlx-swift-lm"
swift build --build-tests
cd "$root"
./scripts/fetch-metallib.sh "$root/libs/mlx-swift-lm/.build/debug"
cp "$root/libs/mlx-swift-lm/.build/debug/mlx.metallib" \
  "$root/libs/mlx-swift-lm/.build/debug/mlx-swift-lmPackageTests.xctest/Contents/MacOS/"
cd "$root/libs/mlx-swift-lm"
swift test --skip-build --filter CBv2ExactPrefixCacheTests
swift test --skip-build --filter CBv2ExactPrefixEngineTests

cd "$root/provider-swift"
swift build --build-tests
cd "$root"
./scripts/fetch-metallib.sh debug
cp "$root/provider-swift/.build/debug/mlx.metallib" \
  "$root/provider-swift/.build/debug/DarkbloomProviderPackageTests.xctest/Contents/MacOS/"
cd "$root/provider-swift"
swift test --skip-build --filter EngineV2ExactPrefixCacheTests
swift test --skip-build --filter QwenPrefixReuseTests
swift test --skip-build --filter EngineV2PrefixCacheUsageTests
swift build -c release --product darkbloom
cd "$root"
./scripts/fetch-metallib.sh release
```

Run the shipping profile without any divergence environment overrides:

```bash
DARKBLOOM_PREFIX_BENCH_CACHE_MAX_BYTES=2147483648 \
.build/release/darkbloom benchmark \
  --model qwen3.6-35b-a3b-vl-mtp-mxfp8 \
  --qwen-prefix-reuse \
  --qwen-prefix-corpus Benchmarks/QwenPrefixReuse/qwen-prefix-natural-v1.json \
  --qwen-prefix-prompt-tokens 8192 \
  --qwen-prefix-decode-tokens 64 \
  --qwen-prefix-iterations 3 \
  --kv-backend contiguous \
  --qwen-prefix-output /tmp/e46-exact-cache-profile.json

jq -e '
  ([.scenarios[].summary.firstTokenEqualityRate] | min) == 1
  and ([.scenarios[].summary.fullTokenEqualityRate] | min) == 1
  and ([.scenarios[].samples[].warm.rows[]
        | select(.cacheOutcome == "hit")
        | .replayTokens] | max) == 0
' /tmp/e46-exact-cache-profile.json
```

E46 executes that clean workflow for three 8K/64-token iterations. Every
scenario passes first/full-token equality. Against the locked native baseline,
the 75%/87.5% partial-prefix cells retain **2.629×/5.076×** first-token
speedups; full B1/B2/B4 hits retain **337.8×/531.0×/697.2×**.
