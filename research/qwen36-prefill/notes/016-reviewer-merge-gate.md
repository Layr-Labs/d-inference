# 016 — Reviewer merge gate: no kernel gets a free pass

Status: binding gate  
Owner: reviewer  
Applies to: every Qwen 3.6 prefill experiment proposed for `keep=yes` or merge

This gate is conjunctive. A prefill win does not buy correctness, decode, memory,
or uptime debt. One failed item means **veto**. There is no weighted score and no
"follow up after merge."

## Immediate blocker: the harness does not yet measure B=2

`darkbloom benchmark --arrival-invariance` currently hard-codes four request
rows. `--scheduler-prefill` measures B=1. `--sweep --batch-sizes` measures the
decode batch axis; its prefill samples are isolated single forwards, not
continuous-batching burst prefill.

Therefore the current harness cannot produce the required B=2 aggregate
continuous-batching prefill result. A B=2 number inferred from a microbenchmark,
two provider processes, `--sweep`, or half of a B=4 run is invalid.

Before any optimization can receive `keep=yes`, a harness-only change must make
the serving `EngineV2Factory.makeServingBuild` arrival benchmark accept
exactly:

```text
--arrival-batch-size 1
--arrival-batch-size 2
--arrival-batch-size 4
```

Its JSON must record `batchSize`, every row's submitted/first-token/completion
timestamps, `prefillMakespanMs`, and
`aggregatePrefillTokensPerSecond`. The aggregate must be computed by the
harness, not reconstructed from rounded console output:

```text
prefill_tokens_per_row = prompt_tokens_per_request - 1
prefill_makespan = max(first_token_time) - min(submission_time)
aggregate_prefill_tps =
    batch_size * prefill_tokens_per_row / prefill_makespan
```

The `L - 1` denominator matches the shipping scheduler-prefill benchmark's
engine work accounting. Reports may additionally show `B * L / makespan`, but
that number must be labeled requested-prompt throughput and must not be mixed
with the acceptance metric.

The harness change is not an optimization and gets its own red/green tests. It
must prove that B=2 really submits two rows to one serving CBv2 engine, B=4
submits four, all rows participate in the measured burst, and a failed/missing
row poisons the cell instead of producing a flattering partial result.
`--scheduler-prefill` must also add the first emitted token's checksum to every
sample so B=1 baseline/candidate parity is machine-checkable.

## Automatic vetoes

Any one of these ends the review:

- Any crash, signal, hang, timeout, missing row, missing sample, request error,
  `fatalError`, Metal allocation refusal, command-buffer failure, NaN, or
  infinity.
- Any runtime-derived shape reaches a new `fatalError`, `precondition`, `try!`,
  force-cast, force-unwrap, or unchecked integer multiplication path.
- Any requested Metal buffer can exceed `MTLDevice.maxBufferLength`, including
  overflow before the comparison.
- Any new allocation bypasses `UnifiedMemoryCap`, lowers the flat 5.5 GiB
  activation reserve, lowers the 1 GiB minimum KV headroom, violates the
  0.90-physical-memory cap / 2 GiB OS floor, or disagrees with coordinator
  admission.
- Any greedy token/checksum mismatch, attention/KV semantic change, MoE top-8
  routing change, GDN-state violation, chat-template change, or tool/vision
  fence regression.
- Candidate median decode throughput below `0.98 * baseline` at **any** required
  B=1, B=2, or B=4 cell, at either 512- or 8,192-token context.
- Any decode or uptime cell that did not run. Zero, omitted, skipped,
  "unavailable", and fallback-to-another-path are failures, not data.
- Any decision run not on AC + High Power (`powermode=2`) for its entire
  duration, or with host/GPU contention or a thermal warning.
- Baseline control cannot reproduce within 8% before the candidate comparison.
- Different host, model bytes, KV backend, prompt set, binary family, config, or
  environment posture between arms.
- Only a microbenchmark, direct model forward, capability flag, kernel counter,
  profiler estimate, compile result, or synthetic model is supplied.
- The implementation has no automated regression test that fails on the old
  implementation for the intended reason and passes on the candidate.
- A wire or telemetry change is not mirrored and symmetry-tested in every
  canonical language location.
- Either required independent quality-gate reviewer returns fail.

The 2% decode allowance is a measurement-noise ceiling, not a budget. A result
inside that band is "no demonstrated regression"; it is not permission to spend
2% deliberately. A repeated directional loss, even under 2%, is a reviewer
veto until the run count or mechanism resolves it.

## Darkbloom-integrable checklist

### 1. Scope and provenance

- [ ] One conceptual optimization only. Harness, tests, and instrumentation may
      be separate commits; unrelated cleanup is absent.
- [ ] Baseline and candidate Git SHAs, all recursive submodule SHAs, release
      binary SHA-256s, model-file SHA-256s, config SHA-256, macOS/Swift/Xcode
      versions, and all relevant env knobs are in the artifact set.
- [ ] Both arms use the M3 Max `m3-max-128gb-2` (`Mac15,9`, 40-core GPU,
      128 GiB), the exact
      `qwen3.6-35b-a3b-vl-mtp-mxfp8` local snapshot, contiguous KV, prefix cache
      off, text-only prompts, and greedy temperature 0.
- [ ] A current-baseline control cell lands within 8% of its previously
      accepted median before candidate data is considered.
- [ ] Raw JSON and stderr logs are retained. Tables are derived views, not the
      evidence.

### 2. A test that fails without the change

- [ ] The test drives the serving-relevant path and exact changed contract.
      A selector test must prove the route executes; a shape test must use the
      boundary shape; an allocation test must prove refusal and process reuse.
- [ ] The test-only commit on the old implementation fails by the named
      assertion. A compile failure, missing symbol, crash, timeout, or skipped
      test does not count as red.
- [ ] The same test passes on the candidate.
- [ ] Full tests pass in every changed package. Dependency tests are run
      explicitly; `provider-swift swift test` does not run
      `libs/mlx-swift-lm` or `libs/mlx-swift` tests.
- [ ] Real-model Qwen serving canary passes for text, concurrent text,
      image, tool call, MTP token parity, cancellation, and post-cancel state
      reclamation.

### 3. Numeric contract

- [ ] Greedy/temp=0 emitted token IDs and per-row checksums are exact between
      baseline and candidate for B=1/2/4 at 512, 2,048, and 8,192 prompt
      tokens.
- [ ] Attention outputs and KV writes obey the existing exactness tests. No
      tolerance is introduced where the incumbent contract is bitwise.
- [ ] MoE expert IDs and top-8 ordering are exact. Router weights and reduced
      outputs stay within the existing operation's checked tolerance; the PR
      may not loosen that tolerance to make the candidate pass.
- [ ] GDN state remains FP32 across chunk boundaries and multi-chunk versus
      single-chunk max absolute error remains `< 1e-2`, the existing
      `GatedDeltaTests` contract.
- [ ] A scan-class rewrite may use a documented tolerance only if the old and
      new algorithms are mathematically equivalent, the tolerance is declared
      before timing, adversarial/random/full-shape tests pass, and greedy token
      IDs remain exact. "Looks coherent" is not a numeric contract.
- [ ] Chat template, last-position logits, tool behavior, MTP target tokens,
      multimodal spans, and request-owned recurrent/mRoPE state remain
      unchanged.

### 4. No fatal Metal or memory path

- [ ] Every runtime-derived dimension/product uses checked arithmetic before
      allocation or dispatch.
- [ ] Every individual requested buffer is checked against the live device's
      `maxBufferLength`; aggregate resident/scratch demand is checked against
      `UnifiedMemoryCap`.
- [ ] Fallible MLX evaluation is under `MLX.withError`, and every `eval` site
      checks `throwIfMLXFaulted` immediately. A block-exit-only check is a
      failure because MLX's handler records and returns.
- [ ] Oversize and overflow tests prove a typed refusal and then successfully
      run another request in the same process.
- [ ] The Qwen vision tower remains one image at a time. No text-prefill patch
      may re-batch images or weaken `VisionTowerBudget`.
- [ ] The prior 164,783,923,200-byte allocation shape is rejected before Metal;
      it must never be used as an on-device crash probe.
- [ ] B=4 8K soak completes without increasing retained request/KV state after
      drain.
- [ ] If persistent, activation, KV, or scratch accounting changes, provider
      `UnifiedMemoryCap` and coordinator servability/admission are updated
      together and tested. The coordinator's version-sensitive 5.5/3 GiB
      mirror is not silently retuned.

### 5. Prefill performance matrix

- [ ] B=1 TTFT and prefill tok/s: L=512, 2,048, 8,192.
- [ ] B=2 aggregate prefill tok/s and per-row TTFT: L=512, 2,048, 8,192.
- [ ] B=4 aggregate prefill tok/s and per-row TTFT: L=512, 2,048, 8,192.
- [ ] Each cell has at least three measured repetitions after warm-up; the
      median is reported, with every raw sample retained.
- [ ] Primary ratchet cell is B=4 equal-length 8K burst:
      `sum(prefill tokens) / burst makespan`.
- [ ] `keep=yes` requires a real primary-cell improvement and no destructive
      B=1/B=2/short-prompt trade. A policy-only mean-TTFT win at unchanged
      aggregate is not a throughput keep.
- [ ] Every non-primary prefill cell is at least 0.98x baseline. As with decode,
      2% is a noise ceiling, not a deliberate regression allowance.
- [ ] The project may claim the 2.5x objective only when the M3 Max B=4 8K
      median is at least 2.50x its valid baseline. B=1 and B=2 numbers must
      still be published; no result is extrapolated across batch sizes.

### 6. Decode non-regression

- [ ] Serving CBv2 decode is measured at B=1/2/4 after 512-token and
      8,192-token prompts, 256 generated tokens per row, five repetitions.
- [ ] Compare medians for both aggregate and per-sequence decode TPS.
- [ ] Every candidate cell is at least 0.98x baseline and has the same number
      of completed rows/tokens.
- [ ] Arrival benchmark token checksums are stable across repetitions and match
      the baseline arm.
- [ ] No prefill optimization remains active during M=1 decode unless that
      exact decode route passed the matrix. Shape guards are behavior, not
      comments.

### 7. Uptime and recovery

- [ ] One engine completes ten B=2 and ten B=4 arrival iterations at 8K/256
      without restart. Because the benchmark includes four arrival patterns,
      every pattern must pass, not only burst.
- [ ] No request timeout, dropped row, stalled stream, process restart, Metal
      error, or missing terminal event.
- [ ] Cancellation drains active requests, active tokens, KV bytes in use, and
      KV bytes reserved to zero; a subsequent request succeeds.
- [ ] Failure injection for an oversize/unsupported shape returns a typed error
      and leaves the process reusable.

### 8. Integration and review

- [ ] No hidden env-only posture is presented as shippable behavior. Any
      default-on risky path has a durable, operator-usable rollback control or
      a narrowly proven fail-closed selector.
- [ ] Provider-visible behavior, capacity, and coordinator admission agree. No
      coordinator-invisible semantic drift.
- [ ] Protocol changes are mirrored in
      `provider-swift/Sources/ProviderCore/Protocol/` and
      `coordinator/protocol/messages.go`, with symmetry tests.
- [ ] Telemetry changes are mirrored in Go, Swift, TypeScript, and the privacy
      allowlist. No prompt/completion content is added.
- [ ] Memory-policy changes preserve the provider/coordinator
      `UnifiedMemoryCap` contract.
- [ ] PR description includes before/after Mermaid diagrams for both behavior
      and code flow.
- [ ] Codex rescue and Claude Code independently inspect the whole diff, run
      affected builds/tests, and both return pass. Either reviewer has veto.

## Why v0.8.8 was a mandatory reject

v0.8.8 had attractive prefill-local evidence:

- GDN 4-in-1 input projection: about 6–10% TTFT reduction.
- Direct expert reduction: 1.79x in its primitive benchmark.

That evidence did not qualify the serving release. The combined default reduced
real Qwen decode throughput and triggered client timeouts; v0.8.9 rolled Qwen
execution back to the v0.8.7 MLX-Swift-LM pin.

Under this gate, v0.8.8 fails independently three ways:

1. The primitive result is not a full-model CBv2 result.
2. A decode regression beyond the non-regression band is an automatic veto.
3. A client timeout is a zero-tolerance uptime veto regardless of its measured
   prefill gain or the exact decode percentage.

The correct verdict would have been **reject before default-on merge**. "Ship
the prefill win and inspect decode later" is forbidden. Re-enabling either idea
requires a guarded selector plus the entire decode and uptime matrix on this
M3 Max. Prior prefill numbers do not grandfather it.

## Evidence that is not acceptable

The following cannot support `keep=yes`:

- A Metal/GEMM/MoE/GDN microbenchmark without full-model serving CBv2
  numbers.
- `--sweep`'s isolated prefill forward presented as scheduler aggregate.
- A capability flag such as `supportsPackedPrefill = true` without executed
  path evidence and full-model timing.
- Low Power Mode or `powermode=0` numbers. LPM changes the machine; it does not
  establish a High Power serving win.
- Any M4, M2, cloud VM, simulator, or other M3 Max result.
- The right M3 Max with different model bytes, quantization, snapshot, KV
  backend, prompt set, or runtime configuration.
- A warm candidate compared with a cold baseline, best-of-N candidate compared
  with median baseline, or a result that discards slow/error samples.
- A B=4 number divided by two and called B=2.
- Two separate model processes called a continuous batch.
- A mean-TTFT scheduling-policy win called aggregate throughput.
- A profiler's theoretical roof, GPU occupancy, kernel count, or bytes-saved
  estimate without wall-clock serving evidence.
- "It compiled", "tests pass", "the output looks right", a screenshot, a prose
  summary without raw artifacts, or an unreviewable env-only patch.
- A test that passes on both old and new code, fails only to compile on old
  code, skips because weights are absent, or asserts an implementation detail
  without driving the changed path.

## Exact M3 Max command gate

These commands run while logged into `m3-max-128gb-2`. They intentionally stop
at the current B=2 harness blocker. No placeholder may remain in a submitted
artifact: the reviewer fills `BASE_SHA`, `CANDIDATE_SHA`, `TEST_SHA`,
`TEST_PACKAGE_REL`, `TEST_FILTER`, and `EXPECTED_RED_ASSERTION` with the
reviewed values before execution.

### 0. Pin identities and create immutable worktrees

```bash
set -euo pipefail

export ROOT=/Users/gaj/work/qwen36-prefill
export BASE_SHA=REPLACE_WITH_HARNESS_ONLY_PRE_KERNEL_COMMIT
export CANDIDATE_SHA="$(git -C "$ROOT" rev-parse HEAD)"
export BASE_ROOT=/Users/gaj/work/qwen36-prefill-gate-base
export CAND_ROOT=/Users/gaj/work/qwen36-prefill-gate-candidate
export MODEL_ID=qwen3.6-35b-a3b-vl-mtp-mxfp8
export MODEL_PATH=/Users/gaj/.cache/huggingface/hub/models--qwen3.6-35b-a3b-vl-mtp-mxfp8/snapshots/local
export CONFIG="$HOME/.darkbloom/provider.toml"
export QWEN_IMAGE=/var/folders/hv/5779vnmn5c564l3tdknlf4x80000gp/T/opencode/qwen36-vlm-proof.png
export OUT="/Users/gaj/qwen36-prefill-gate-artifacts/$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$OUT"

test "$(sysctl -n hw.model)" = "Mac15,9"
test "$(sysctl -n hw.memsize)" = "137438953472"
test -d "$MODEL_PATH"
test -f "$CONFIG"
test -f "$QWEN_IMAGE"

git -C "$ROOT" diff --check
git -C "$ROOT" worktree add --detach "$BASE_ROOT" "$BASE_SHA"
git -C "$ROOT" worktree add --detach "$CAND_ROOT" "$CANDIDATE_SHA"
git -C "$BASE_ROOT" submodule update --init --recursive
git -C "$CAND_ROOT" submodule update --init --recursive

{
  scutil --get ComputerName
  scutil --get LocalHostName
  sw_vers
  system_profiler SPHardwareDataType
  system_profiler SPDisplaysDataType
  xcodebuild -version
  swift --version
  git -C "$BASE_ROOT" rev-parse HEAD
  git -C "$BASE_ROOT" submodule status --recursive
  git -C "$CAND_ROOT" rev-parse HEAD
  git -C "$CAND_ROOT" submodule status --recursive
  shasum -a 256 "$CONFIG"
  shasum -a 256 "$MODEL_PATH"/config.json
  shasum -a 256 "$MODEL_PATH"/tokenizer_config.json
  shasum -a 256 "$MODEL_PATH"/model.safetensors.index.json
  shasum -a 256 "$MODEL_PATH"/*.safetensors
} | tee "$OUT/provenance.log"
```

`BASE_SHA` is the harness-only, pre-kernel tree. The current pre-kernel tree is
`1d926959c4afe575e350c384cba2271612c24ab7`, but it cannot be used because it
lacks B=2. The harness prerequisite lands first; that resulting commit becomes
the immutable baseline. It is never silently moved after candidate results are
seen.

### 1. Enforce AC + High Power and a quiet host

```bash
sudo pmset -a powermode 2

power_gate() {
  pmset -g batt
  pmset -g custom
  pmset -g therm
  pmset -g batt | grep -q "AC Power"
  test "$(pmset -g custom | awk '
    /AC Power/ { in_ac=1; next }
    /^[^ ]/ && !/AC Power/ { in_ac=0 }
    in_ac && /powermode/ { print $2; exit }
  ')" = "2"
}

power_gate | tee "$OUT/power-before.log"
~/.darkbloom/bin/darkbloom status | tee "$OUT/provider-status.log"
test -z "$(pgrep -x darkbloom || true)"
ps -axo pid,pcpu,pmem,command | sort -k2 -nr | sed -n '1,20p' \
  | tee "$OUT/processes-before.log"
```

The provider daemon must be stopped and no compile, benchmark, or other GPU
process may overlap a measured cell. If that is not true, stop here; do not
massage the data afterward.

### 2. Prove red/green, then run all affected tests

The candidate must place the failing regression test in a test-only commit
before the implementation commit.

```bash
export TEST_SHA=REPLACE_WITH_TEST_ONLY_COMMIT
export TEST_PACKAGE_REL=REPLACE_WITH_PACKAGE_PATH
export TEST_FILTER=REPLACE_WITH_EXACT_SWIFT_TEST_FILTER
export EXPECTED_RED_ASSERTION=REPLACE_WITH_EXACT_ASSERTION_TEXT
export RED_ROOT=/Users/gaj/work/qwen36-prefill-gate-red

git -C "$ROOT" worktree add --detach "$RED_ROOT" "$TEST_SHA"
git -C "$RED_ROOT" submodule update --init --recursive

set +e
(cd "$RED_ROOT/$TEST_PACKAGE_REL" && swift test --filter "$TEST_FILTER") \
  >"$OUT/red-test.log" 2>&1
red_rc=$?
set -e
test "$red_rc" -ne 0
grep -F "$EXPECTED_RED_ASSERTION" "$OUT/red-test.log"

(cd "$CAND_ROOT/$TEST_PACKAGE_REL" && swift test --filter "$TEST_FILTER") \
  2>&1 | tee "$OUT/green-test.log"

(cd "$CAND_ROOT/libs/mlx-swift" && swift test) \
  2>&1 | tee "$OUT/mlx-swift-test.log"
(cd "$CAND_ROOT/libs/mlx-swift-lm" && swift test) \
  2>&1 | tee "$OUT/mlx-swift-lm-test.log"
(cd "$CAND_ROOT/provider-swift" && swift test) \
  2>&1 | tee "$OUT/provider-test.log"
```

If coordinator, protocol, telemetry, or admission code changed, also run:

```bash
(cd "$CAND_ROOT/coordinator" && go test ./...) \
  2>&1 | tee "$OUT/coordinator-test.log"
```

Run the real Qwen serving canary on the exact snapshot:

```bash
(
  cd "$CAND_ROOT/provider-swift"
  DARKBLOOM_LIVE_MLX_TESTS=1 \
  DARKBLOOM_LIVE_MLX_QWEN36=1 \
  DARKBLOOM_LIVE_MLX_QWEN36_MODEL_PATH="$MODEL_PATH" \
  DARKBLOOM_LIVE_MLX_QWEN36_IMAGE_PATH="$QWEN_IMAGE" \
  swift test --filter Qwen36ServingCanaryTests
) 2>&1 | tee "$OUT/qwen36-serving-canary.log"
```

Missing model/image fixtures are a blocker, not a skip accepted as pass.

### 3. Build and hash the exact release binaries

```bash
(cd "$BASE_ROOT/provider-swift" && swift build -c release --product darkbloom)
(cd "$CAND_ROOT/provider-swift" && swift build -c release --product darkbloom)

export BASE_BIN="$(cd "$BASE_ROOT/provider-swift" && swift build -c release --show-bin-path)/darkbloom"
export CAND_BIN="$(cd "$CAND_ROOT/provider-swift" && swift build -c release --show-bin-path)/darkbloom"

test -x "$BASE_BIN"
test -x "$CAND_BIN"
shasum -a 256 "$BASE_BIN" "$CAND_BIN" | tee "$OUT/binaries.sha256"
```

No unrecorded `DARKBLOOM_*` or `MLX_*` performance knob may leak into the
benchmark shell:

```bash
env | awk -F= '/^(DARKBLOOM|MLX)_/ { print $1 }' | sort -u \
  | tee "$OUT/performance-env-keys.log"
test ! -s "$OUT/performance-env-keys.log"
```

### 4. B=1 serving scheduler prefill, ABBA order

```bash
run_b1() {
  arm="$1"
  bin="$2"
  repetition="$3"
  power_gate >"$OUT/power-b1-${arm}-${repetition}.log"
  "$bin" benchmark \
    --config "$CONFIG" \
    --model "$MODEL_ID" \
    --scheduler-prefill \
    --prefill-lengths 512,2048,8192 \
    --prefill-iterations 3 \
    --kv-backend contiguous \
    >"$OUT/b1-${arm}-${repetition}.json" \
    2>"$OUT/b1-${arm}-${repetition}.stderr"
  power_gate >"$OUT/power-b1-${arm}-${repetition}-after.log"
}

run_b1 base "$BASE_BIN" 1
run_b1 candidate "$CAND_BIN" 1
run_b1 candidate "$CAND_BIN" 2
run_b1 base "$BASE_BIN" 2

for f in "$OUT"/b1-*.json; do
  jq -e '
    .schemaVersion >= 4 and
    .modelID == "qwen3.6-35b-a3b-vl-mtp-mxfp8" and
    .promptLengths == [512,2048,8192] and
    .iterations == 3 and
    .kvBackend.selection == "contiguous" and
    ([.samples[].tokenChecksum | type == "string" and length > 0] | all) and
    ([.samples[].resolvedKVBackend | startswith("contiguous")] | all)
  ' "$f" >/dev/null
done
```

### 5. B=2/B=4 aggregate prefill matrix, ABBA order

This exact command is required after the harness prerequisite lands. It fails
against the current CLI by design; that failure is the present merge blocker.

```bash
run_arrival_matrix() {
  arm="$1"
  bin="$2"
  repetition="$3"
  for batch in 2 4; do
    for length in 512 2048 8192; do
      power_gate >"$OUT/power-arrival-${arm}-${repetition}-b${batch}-l${length}.log"
      "$bin" benchmark \
        --config "$CONFIG" \
        --model "$MODEL_ID" \
        --arrival-invariance \
        --arrival-batch-size "$batch" \
        --arrival-prompt-tokens "$length" \
        --arrival-decode-tokens 64 \
        --arrival-iterations 3 \
        --kv-backend contiguous \
        >"$OUT/arrival-${arm}-${repetition}-b${batch}-l${length}.json" \
        2>"$OUT/arrival-${arm}-${repetition}-b${batch}-l${length}.stderr"
      power_gate \
        >"$OUT/power-arrival-${arm}-${repetition}-b${batch}-l${length}-after.log"
    done
  done
}

run_arrival_matrix base "$BASE_BIN" 1
run_arrival_matrix candidate "$CAND_BIN" 1
run_arrival_matrix candidate "$CAND_BIN" 2
run_arrival_matrix base "$BASE_BIN" 2

for f in "$OUT"/arrival-*.json; do
  jq -e '
    .batchSize as $batch |
    .schemaVersion >= 5 and
    .batchSize == (.patterns[0].samples[0].rows | length) and
    (.batchSize == 2 or .batchSize == 4) and
    .iterations == 3 and
    .kvBackend.selection == "contiguous" and
    ([.kvBackend.resolved[] | startswith("contiguous")] | all) and
    ([.patterns[].outputsStableAcrossIterations] | all) and
    ([.patterns[].outputsMatchBurst] | all) and
    ([.patterns[].arrivalWithinTolerance] | all) and
    ([.patterns[].samples[].rows | length == $batch] | all) and
    ([.patterns[].samples[].aggregatePrefillTokensPerSecond > 0] | all) and
    ([.patterns[].samples[].prefillMakespanMs > 0] | all)
  ' "$f" >/dev/null
done
```

The acceptance table reports medians across the six raw samples per arm/cell
(two ABBA process positions times three measured iterations), not the fastest
process.

### 6. Decode matrix

Run 512- and 8,192-token contexts separately so a short-context result cannot
hide a long-context regression:

```bash
run_decode() {
  arm="$1"
  bin="$2"
  repetition="$3"
  for length in 512 8192; do
    power_gate >"$OUT/power-decode-${arm}-${repetition}-l${length}.log"
    "$bin" benchmark \
      --config "$CONFIG" \
      --model "$MODEL_ID" \
      --sweep \
      --prefill-lengths "$length" \
      --batch-sizes 1,2,4 \
      --decode-prompt-tokens "$length" \
      --decode-tokens 256 \
      --decode-iterations 5 \
      --kv-backend contiguous \
      >"$OUT/decode-${arm}-${repetition}-l${length}.json" \
      2>"$OUT/decode-${arm}-${repetition}-l${length}.stderr"
    power_gate >"$OUT/power-decode-${arm}-${repetition}-l${length}-after.log"
  done
}

run_decode base "$BASE_BIN" 1
run_decode candidate "$CAND_BIN" 1
run_decode candidate "$CAND_BIN" 2
run_decode base "$BASE_BIN" 2

for f in "$OUT"/decode-*.json; do
  jq -e '
    .kvBackend.selection == "contiguous" and
    .decodeCoverage.requestedBatchSizes == [1,2,4] and
    (.decodeCoverage.unmeasured | length) == 0 and
    ([.decode[].resolvedKVBackend | startswith("contiguous")] | all) and
    ([1,2,4] - [.decode[].batchSize] | length) == 0 and
    ([.decode[].aggregateTokensPerSecond > 0] | all) and
    ([.decode[].perSequenceTokensPerSecond > 0] | all)
  ' "$f" >/dev/null
done
```

For every `(context, B)`, take the median of all ten samples per arm. The
automatic check is:

```text
candidate_aggregate_decode_tps / baseline_aggregate_decode_tps >= 0.98
candidate_per_sequence_decode_tps / baseline_per_sequence_decode_tps >= 0.98
```

One failed cell vetoes the change. Averaging B=1, B=2, and B=4 together is
forbidden.

### 7. Uptime soak

```bash
run_soak() {
  batch="$1"
  power_gate >"$OUT/power-soak-b${batch}-before.log"
  "$CAND_BIN" benchmark \
    --config "$CONFIG" \
    --model "$MODEL_ID" \
    --arrival-invariance \
    --arrival-batch-size "$batch" \
    --arrival-prompt-tokens 8192 \
    --arrival-decode-tokens 256 \
    --arrival-iterations 10 \
    --kv-backend contiguous \
    >"$OUT/soak-b${batch}.json" \
    2>"$OUT/soak-b${batch}.stderr"
  power_gate >"$OUT/power-soak-b${batch}-after.log"
}

run_soak 2
run_soak 4

jq -e '
  .batchSize as $batch |
  .iterations == 10 and
  ([.patterns[].samples | length == 10] | all) and
  ([.patterns[].samples[].rows | length == $batch] | all) and
  ([.patterns[].outputsStableAcrossIterations] | all) and
  ([.patterns[].outputsMatchBurst] | all) and
  ([.patterns[].arrivalWithinTolerance] | all)
' "$OUT/soak-b2.json" "$OUT/soak-b4.json" >/dev/null

if rg -n -i \
  'fatal error|fatalError|metal::malloc|maximum allowed buffer|maxBufferLength|command buffer.*error|nan|infinity' \
  "$OUT"; then
  exit 1
fi
if rg -n -i 'timed out|request (failed|error)' "$OUT"/*.stderr; then
  exit 1
fi
```

### 8. Machine-check the medians and parity

```bash
python3 - "$OUT" <<'PY'
import collections
import json
import pathlib
import re
import statistics
import sys

out = pathlib.Path(sys.argv[1])

def read(path):
    with path.open() as handle:
        return json.load(handle)

def median(values):
    if not values:
        raise SystemExit("missing samples")
    return statistics.median(values)

prefill = collections.defaultdict(list)
ttft = collections.defaultdict(list)
checksums = collections.defaultdict(list)

for path in sorted(out.glob("b1-*.json")):
    match = re.fullmatch(r"b1-(base|candidate)-\d+\.json", path.name)
    if not match:
        continue
    arm = match.group(1)
    report = read(path)
    for sample in report["samples"]:
        length = sample["promptTokens"]
        prefill[(arm, 1, length)].append(1000.0 / sample["msPerPrefillToken"])
        ttft[(arm, 1, length)].append(sample["ttftMs"])
        checksums[(arm, 1, length, "scheduler")].append(sample["tokenChecksum"])

for path in sorted(out.glob("arrival-*.json")):
    match = re.fullmatch(
        r"arrival-(base|candidate)-\d+-b(2|4)-l(512|2048|8192)\.json",
        path.name,
    )
    if not match:
        continue
    arm, batch, length = match.group(1), int(match.group(2)), int(match.group(3))
    report = read(path)
    for pattern in report["patterns"]:
        for sample in pattern["samples"]:
            if pattern["name"] == "burst":
                prefill[(arm, batch, length)].append(
                    sample["aggregatePrefillTokensPerSecond"]
                )
                ttft[(arm, batch, length)].extend(
                    row["ttftMs"] for row in sample["rows"]
                )
            checksums[(arm, batch, length, pattern["name"])].append(
                tuple(sorted(row["tokenChecksum"] for row in sample["rows"]))
            )

rows = ["metric\tB\tL\tbaseline\tcandidate\tratio"]
for batch in (1, 2, 4):
    for length in (512, 2048, 8192):
        base_values = prefill[("base", batch, length)]
        cand_values = prefill[("candidate", batch, length)]
        if len(base_values) != 6 or len(cand_values) != 6:
            raise SystemExit(
                f"wrong prefill sample count B={batch} L={length}: "
                f"base={len(base_values)} candidate={len(cand_values)}"
            )
        base = median(base_values)
        cand = median(cand_values)
        ratio = cand / base
        primary = (batch, length) == (4, 8192)
        if (primary and ratio <= 1.0) or (not primary and ratio < 0.98):
            raise SystemExit(
                f"prefill veto B={batch} L={length}: {ratio:.4f}x"
            )
        rows.append(
            f"prefill_tps\t{batch}\t{length}\t"
            f"{base:.6f}\t{cand:.6f}\t{ratio:.6f}"
        )
        base_ttft = median(ttft[("base", batch, length)])
        cand_ttft = median(ttft[("candidate", batch, length)])
        rows.append(
            f"ttft_ms\t{batch}\t{length}\t"
            f"{base_ttft:.6f}\t{cand_ttft:.6f}\t{cand_ttft / base_ttft:.6f}"
        )

for key in sorted({key[1:] for key in checksums}):
    base = collections.Counter(checksums[("base",) + key])
    candidate = collections.Counter(checksums[("candidate",) + key])
    if not base or base != candidate:
        raise SystemExit(f"token-checksum veto: {key}")

decode = collections.defaultdict(lambda: collections.defaultdict(list))
for path in sorted(out.glob("decode-*.json")):
    match = re.fullmatch(
        r"decode-(base|candidate)-\d+-l(512|8192)\.json", path.name
    )
    if not match:
        continue
    arm, length = match.group(1), int(match.group(2))
    report = read(path)
    for sample in report["decode"]:
        if sample["decodeTokensPerSequence"] != 256:
            raise SystemExit(f"wrong decode token count in {path}")
        key = (length, sample["batchSize"])
        decode[(arm, key)]["aggregate"].append(
            sample["aggregateTokensPerSecond"]
        )
        decode[(arm, key)]["per_sequence"].append(
            sample["perSequenceTokensPerSecond"]
        )

for length in (512, 8192):
    for batch in (1, 2, 4):
        key = (length, batch)
        for metric in ("aggregate", "per_sequence"):
            base_values = decode[("base", key)][metric]
            cand_values = decode[("candidate", key)][metric]
            if len(base_values) != 10 or len(cand_values) != 10:
                raise SystemExit(
                    f"wrong decode sample count L={length} B={batch} "
                    f"{metric}: base={len(base_values)} candidate={len(cand_values)}"
                )
            base = median(base_values)
            cand = median(cand_values)
            ratio = cand / base
            if ratio < 0.98:
                raise SystemExit(
                    f"decode veto L={length} B={batch} {metric}: {ratio:.4f}x"
                )
            rows.append(
                f"decode_{metric}_tps\t{batch}\t{length}\t"
                f"{base:.6f}\t{cand:.6f}\t{ratio:.6f}"
            )

(out / "gate-summary.tsv").write_text("\n".join(rows) + "\n")
print("\n".join(rows))
PY
```

The B=4 8K primary ratio must be strictly greater than 1.0 for an incremental
ratchet keep and at least 2.50 before claiming the research objective is met.
Every other prefill cell and every decode cell has the automatic 0.98 floor.

### 9. Final posture and diff review

```bash
power_gate | tee "$OUT/power-after.log"
ps -axo pid,pcpu,pmem,command | sort -k2 -nr | sed -n '1,20p' \
  | tee "$OUT/processes-after.log"

git -C "$CAND_ROOT" diff --check "$BASE_SHA..$CANDIDATE_SHA"
git -C "$CAND_ROOT" diff --submodule=diff --stat "$BASE_SHA..$CANDIDATE_SHA" \
  | tee "$OUT/diff-stat.log"
git -C "$CAND_ROOT" diff --submodule=diff -U0 "$BASE_SHA..$CANDIDATE_SHA" \
  | rg '^\+.*(fatalError|precondition|try!|as!|[A-Za-z0-9_]!)' \
  | tee "$OUT/new-trap-lines.log" || true
test ! -s "$OUT/new-trap-lines.log"
```

Then both independent quality-gate reviewers inspect the diff and this complete
artifact directory. `keep=yes` requires every checklist item, every automatic
check, and both reviewer verdicts to pass. A missing artifact is a failed gate.
