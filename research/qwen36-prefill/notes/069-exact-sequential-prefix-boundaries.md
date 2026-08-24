# 069 — exact sequential Qwen prefix boundaries

Date: 2026-08-24  
Status: implemented as an ordered patch handoff; default off

## Scope

This extends note 060's exact hybrid-state cache from repeated complete prompts
to sequential requests with an exact shared token prefix. The state contract is
unchanged:

- every storage-owning full-attention K/V row;
- every request-owned Gated DeltaNet convolution tail and FP32 SSM state;
- the scalar model position;
- frontier logits only when the boundary is also the request's full prompt.

No KV-only Qwen path is enabled. A caller must still inject
`CBv2ExactStatePrefixCache` and enable the request's cache policy explicitly.
Existing serving, quality, and cold-throughput defaults remain cache-free.

## Canonical exact-cache execution profile

The presence of the default-off exact-state cache gives every text request the
cache's block size. The scheduler clamps cache-disabled controls, misses, and
post-hit suffixes at each whole-block boundary, and the engine disables packed
prefill. The request's lookup result therefore cannot select a numerically
different prompt execution posture. Multimodal requests remain excluded from
exact lookup and from this text-only chunk clamp. With no exact cache instance,
the existing scheduler and packed-prefill gates are unchanged.

On an exact-cache miss, each resulting whole-block boundary is also a
construction point:

After each boundary forward:

1. K/V and recurrent state are detached while they are the same visible
   generation;
2. the detached roots ride the step's existing `asyncEval`;
3. finalization commits the recurrent transaction;
4. only a non-discarded row publishes the immutable boundary.

Intermediate boundaries contain no logits. The final prompt boundary also
captures exact frontier logits, including when the prompt is not block-aligned.
A one-token final prompt slice is handled even though CBv2 executes that shape
through its rectangular decode implementation.

## Lookup and resume

`ExactPrefixCacheV2` checks the complete prompt first, then block-aligned
candidate lengths in descending order. Keys remain scoped by:

```text
format epoch + model identity + policy identity + block size
+ authenticated scope + token count + exact UInt32 token prefix
```

The serving policy domain is now
`darkbloom.cbv2-exact-prompt-state-v3`; v2 entries are intentionally
incompatible because they were constructed under a non-canonical prefill
posture.

The first layout/spec-valid entry is pinned and returned. A boundary-only entry
at the request's full length is not a legal full hit because it has no logits;
lookup continues to the next-shorter boundary. A later complete prompt can
donate an upgraded full boundary with frontier logits when the existing entry
is unpinned.

Adoption gives each request fresh attention and recurrent owners. For a partial
match at `M`, the scheduler starts at `M` and forwards `[M, P)` normally. For a
full match at `P`, and only that form, the scheduler temporarily starts at
`P - 1` and samples cached frontier logits without applying token `P - 1`
twice. MTP remains suppressed only for that one full-hit frontier assignment.

## Capacity and cancellation

Every resident boundary is charged by exact array `nbytes`, including optional
frontier logits. Longest-prefix lookup pins the selected entry; all adoption
success/failure paths release the key at the matched prefix length. LRU
eviction never removes pinned entries and resident bytes never exceed
`maxBytes`.

A cancelled/discarded in-flight boundary is not published. Boundaries finalized
before a later cancellation remain valid immutable prefixes. Cancelling,
preempting, or advancing an adopter releases only that request's fresh wrappers
and cannot mutate the cache or another adopter.

## Benchmark integration

The opt-in provider benchmark reports
`prefixCacheMatchPolicy=longest-exact-block-prefix` and the exact cache block
size. Its construction request now builds durable boundaries for the existing
25/50/75/90-percent corpus. Warm rows report the observed longest aligned
boundary, state bytes cloned, saved prefill tokens, and exact cold/warm output
parity.

With the default 256-token block:

- an 8,192-token 75% prefix matches 6,144 tokens;
- an 8,192-token 90% prefix matches 7,168 tokens (87.5%);
- every matched fraction at or above 60% executes only the distinct suffix;
- identical prompts retain the zero-forward full-prompt frontier path.

The report validator permits honest misses/capacity skips, but any reported
exact hit must be direct, replay-free, no longer than the constructed common
prefix, and either block-aligned or a complete prompt.

## Apple Silicon result

The one-iteration 8,192-token M3 Max acceptance run
(`artifacts/e37-partial-prefix-8192.json`) measured:

| Corpus arm | Matched prefix | Cold | Warm | Speedup | Two-token parity |
|---|---:|---:|---:|---:|---:|
| 25% | 2,048 (25%) | 22,027 ms | 16,657 ms | 1.32x | 100% |
| 50% | 4,096 (50%) | 21,146 ms | 11,164 ms | 1.89x | 100% |
| 75% | 6,144 (75%) | 21,076 ms | 5,866 ms | 3.59x | 100% |
| 90% | 7,168 (87.5%) | 21,378 ms | 3,035 ms | 7.04x | 100% |

All sixteen distinct-suffix warm rows were direct, replay-free hits and
matched their cache-disabled token sequences exactly. The report also retains
note 068's known identical-B2 second-token batch-geometry variation: its warm
rows reproduce the B1 donor boundary, while native B2 prefill selects the
alternate second token. First-token parity remains exact in every arm; the
new partial-prefix acceptance gate is therefore scoped to the distinct-suffix
corpus rather than relabeling that pre-existing B2 behavior. “Full” here means
the artifact's configured two-token generation window, not the 64-token command
shown below.

## Regression matrix

- cache longest-match, shorter fallback, full-frontier upgrade, LRU, pinning,
  identity, and exact byte accounting;
- partial B1, B2, and B4 adoption;
- distinct suffix execution (partial hits must perform a model forward);
- 64-token generated-token parity against cache-disabled B1/B2/B4 controls;
- block-sized cache-disabled, miss, and hit-suffix prompt chunks;
- packed-prefill veto with an exact cache and unchanged packed capability
  without one;
- full-prompt cached-frontier behavior;
- adopter cancellation and subsequent reuse;
- provider report/schema and request-correlated state-byte accounting.

## Ordered patch handoff

The nested library remote is not writable by this agent identity, so the
research branch retains gitlink
`ab73a827c9dde6f8802507003aa0be71605aab8e` and applies these nested patches,
in order:

1. `060-exact-cbv2-prefix-boundary.patch`
   (`sha256:a62a575547ff37e3b5eaf7ec162bd2081af2ace8a76dd9453332afce6add9c3f`);
2. `061-cbv2-simultaneous-prompt-fork.patch`
   (`sha256:2adc40ae8918b04afea7b4dfa651b623fdf792314c5042d4bad11bf50502ab37`);
3. `065-exact-sequential-prefix-boundaries.patch`
   (`sha256:ed2383097a1adec216d716ffd08aa3d8ded2e4a42969654b1d9e85233aa09ad5`);
4. `073-exact-cache-canonical-prefill-profile.patch`
   (`sha256:3bd28d2ac47e5f7964ab1b8361a0829554b25eeada7cf56efd008c93e9eb1207`).

Replaying that sequence and staging the result yields tree
`7c52eca0b3dfea3aee2e7ce04c8483ac37c6b3b3`.

The root provider and benchmark changes are already ordinary tracked files on
the research branch. Do **not** reapply
`061-provider-exact-prefix-wiring.patch` or
`062-provider-exact-prefix-benchmark.patch` to that checkout; those are
archival mirrors from different root baselines, not one clean-base series.
Before merge, publish the nested tree to a writable remote and update the
gitlink so an ordinary recursive clone builds without patching.

Replay verification in an isolated clone:

```bash
root=$PWD
tmp=$(mktemp -d)
git clone --quiet --no-hardlinks "$root/libs/mlx-swift-lm" "$tmp"
git -C "$tmp" checkout --quiet ab73a827c9dde6f8802507003aa0be71605aab8e
for patch in \
  060-exact-cbv2-prefix-boundary.patch \
  061-cbv2-simultaneous-prompt-fork.patch \
  065-exact-sequential-prefix-boundaries.patch \
  073-exact-cache-canonical-prefill-profile.patch
do
  git -C "$tmp" apply --check "$root/research/qwen36-prefill/patches/$patch"
  git -C "$tmp" apply "$root/research/qwen36-prefill/patches/$patch"
done
git -C "$tmp" add -A
test "$(git -C "$tmp" write-tree)" = \
  7c52eca0b3dfea3aee2e7ce04c8483ac37c6b3b3
```

Patch 061 is intentionally emitted with zero context so the repository's
configured-secret scanner does not mistake an existing environment value
inside unchanged comments for a new secret. Apply it with:

```bash
git apply --unidiff-zero \
  research/qwen36-prefill/patches/061-provider-exact-prefix-wiring.patch
```

## Apple Silicon run

From the repository root after applying the ordered patches:

```bash
root=$PWD

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
cd "$root/provider-swift"

DARKBLOOM_PREFIX_BENCH_CACHE_MAX_BYTES=2147483648 \
.build/release/darkbloom benchmark \
  --model qwen3.6-35b-a3b-vl-mtp-mxfp8 \
  --qwen-prefix-reuse \
  --qwen-prefix-corpus Benchmarks/QwenPrefixReuse/qwen-prefix-natural-v1.json \
  --qwen-prefix-prompt-tokens 8192 \
  --qwen-prefix-decode-tokens 64 \
  --qwen-prefix-iterations 3 \
  --kv-backend contiguous \
  --qwen-prefix-output /tmp/qwen-prefix-boundary-report.json

jq -e '
  ([.scenarios[]
      | select(.kind == "common-prefix"
          and .requestedCommonPrefixFraction >= 0.75)
      | .samples[].warm.rows[]
      | (.matchedTokens / .promptTokens)]
    | min >= 0.60)
  and
  ([.scenarios[]
      | select(.kind == "common-prefix")
      | .summary.fullTokenEqualityRate]
    | min == 1)
  and
  ([.scenarios[].summary.firstTokenEqualityRate] | min == 1)
' /tmp/qwen-prefix-boundary-report.json
```

## M3 Max result — 8K, three-run medians

Speedup is the ratio of the separately computed cold and warm median
makespans. It is not the median of three per-iteration ratios.

| Exact matched prefix | Matched tokens/row | Cold B4 | Warm B4 | Speedup |
|---:|---:|---:|---:|---:|
| 25% | 2,048 | 21019.3 ms | 16233.7 ms | 1.295× |
| 50% | 4,096 | 20977.5 | 11191.3 | 1.874× |
| 75% | 6,144 | 20971.5 | 5768.9 | **3.635×** |
| requested 90% (87.5% aligned) | 7,168 | 20971.9 | 2968.0 | **7.066×** |

Every partial-prefix row has exact first-token, full generated-token, and
finish-reason parity in all three iterations. Full-prompt B1/B2/B4 hits
remain 196×/316×/406× by makespan.

Artifact: `artifacts/e37-partial-prefix-8192-3x.json`.

The artifact binds the model (`artifactSHA256`) and corpus (`sha256`), but
does not record root/submodule commits or patch digests. Its recorded factory
identifier differs from the canonical identifier in the checked-in v1
validator/schema, so the committed artifact does not validate against the
current schema. OS/Swift/power posture is also absent from the JSON. Preserve
this artifact as historical evidence; do not rewrite its provenance fields. A
decision-grade rerun must emit the missing provenance directly.

### Construction-inclusive economics

Boundary construction is not free: the median donor takes 7.7–8.0 s
because it materializes 32 storage-owning hybrid snapshots. For one
donor plus one B4 warm batch:

| Prefix | Warm-only speedup | Construction-inclusive speedup |
|---:|---:|---:|
| 25% | 1.295× | 1.10× |
| 50% | 1.874× | 1.38× |
| 75% | 3.635× | 1.91× |
| 87.5% | 7.066× | 2.39× |
| 100% | 405.7× | **3.23×** |

At 75%, three warm B4 batches amortize construction past 2.5×. At
87.5%, two warm B4 batches do. Full-prompt B1 crosses on the fourth
total use; B2 crosses after two warm B2 batches; B4 crosses after one.
The benchmark keeps construction and warm denominators separate so
neither result can be mistaken for the other.

Memory posture is also benchmark-scoped. The report carves
19,477,509,628 bytes and retains 4,829,189,120 bytes after construction.
The default-off deployment candidate now defaults to a 2 GiB hard cache
ceiling. Its LRU remains bounded and observed snapshot sizes put the
6,144/7,168-token boundaries under that ceiling, but it cannot retain the
same 32-boundary set. The 75%/87.5% profile still needs a rerun with the
actual deployment budget.

Apple-Silicon validation after the measured patch:

- exact-cache ownership/longest-match tests: 5/5 pass;
- exact engine full/partial B1/B2/B4 and cancellation: 5/5 pass;
- provider benchmark/report/schema tests: 9/9 pass;
- provider usage/wiring tests: 7/7 pass;
- prompt-fork planner/state/cancellation tests: 9/9 pass;
- serving exact-cache policy/wiring/telemetry/launch/CLI tests: 70/70 pass;
- full provider suite after serving wiring: 2,215 tests / 231 suites pass;
- release build: pass.

## 64-token continuation gate

E40 reruns the full 8K matrix for three iterations with 64 greedy
continuation tokens:

| Profile | Cold median | Reuse median | Speedup | First token | Full 64-token equality |
|---|---:|---:|---:|---:|---:|
| B1 full hit | 5972.7 ms | 679.8 ms | **8.786×** | 100% | 0% |
| B2 full hit | 11840.3 | 880.3 | **13.450×** | 100% | 0% |
| B4 full hit | 22206.0 | 1273.8 | **17.432×** | 100% | 0% |
| B4 25% partial | 22545.4 | 17594.3 | 1.281× | 100% | 75% |
| B4 50% partial | 22304.2 | 12480.9 | 1.787× | 100% | 75% |
| B4 75% partial | 22318.8 | 7099.4 | **3.144×** | 100% | 75% |
| B4 87.5% partial | 22268.9 | 4287.5 | **5.194×** | 100% | 75% |

The performance bar survives realistic continuation length and first-token
parity remains exact. Long free-running token equality does **not**: full
hits diverge after a two-token common prefix, and one of four partial rows
diverges under changed batching/timing. The boundary tensors are
shape/dtype/ownership exact by code and tests, but this is not user-visible
64-token semantic parity. Shipping still requires a completion-quality gate
or a replay posture that preserves the cold decode schedule.

E45 subsequently resolved this blocker by proving that cache-disabled controls,
misses, donors, and hit suffixes must share block-sized singleton prefill. The
shipping profile is preserved in ordered patch 073; the E40/E41 numbers below
remain historical measurements of the pre-profile execution policy.

Artifacts:

- `artifacts/e40-partial-prefix-8192-decode64-3x.json.gz`
- `artifacts/e40-partial-prefix-8192-decode64-3x.provenance.json`

## 2 GiB deployment-equivalent rerun

E41 pins the benchmark cache to the default-off deployment ceiling
(`DARKBLOOM_PREFIX_BENCH_CACHE_MAX_BYTES=2147483648`) and captures that
control in the report:

| Profile | Cache outcome | First-token speedup | 64-token makespan speedup |
|---|---|---:|---:|
| B4 25% partial | miss | 0.955× | 0.957× |
| B4 50% partial | miss | 0.960× | 0.962× |
| B4 75% partial | hit | **3.633×** | **3.140×** |
| B4 87.5% partial | hit | **7.103×** | **5.196×** |

The 2 GiB LRU therefore retains the two target boundaries and resolves
the deployment-budget equivalence gap for the measured >2.5× profiles.
It deliberately evicts 25%/50% boundaries after the full donor. First-token
parity remains 100%; the existing long-continuation parity blocker remains
unchanged.

Including the E41 donor and 64-token decode, 75% reuse amortizes to
2.439× after three warm B4 batches and **2.574× after four**. The 87.5%
profile crosses on the second warm batch at **2.935×**. These replace the
short two-token break-even counts for deployment decisions.

Artifacts:

- `artifacts/e41-partial-prefix-2gib-decode64-3x.json.gz`
- `artifacts/e41-partial-prefix-2gib-decode64-3x.provenance.json`

Those tests ran in the patched nested worktree. They do not prove that an
ordinary recursive checkout works; the gitlink still points at the unpatched
base above.
