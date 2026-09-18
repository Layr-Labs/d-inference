# Radix prefix cache baseline on M5 Max

> Last updated: 2026-09-05 · commit `e928d395f`

This report measures the clean provider baseline before resident prefix caching.
The measurements below use **Qwen3.8-27B with MTP disabled**. They establish a
comparison point; they do not demonstrate an optimization gain.

## Artifact and model identity

| Item | Measured value |
|---|---|
| Provider commit | `e928d395fa4f97e736552a6de89b37876b2bc56b`, clean detached worktree |
| MLX-Swift-LM | `c4089870a24b082a9d70f31dc853380e9cff92ca` |
| MLX-Swift | `6b0505cc790f512ae49d740b21e13f80802946bd` |
| Compiled nested MLX | `734241bbff26467bb33eff8adc65b82d17b33578` |
| Provider binary SHA256 | `f226a57636d3796c51ac98ad1a338854cea4c77a3fd9bc47047c754499fc23b3` |
| Metal library SHA256 | `4ffbbac48a99b495916c3fa0921ce813eb554de1a09aff408d9b5a5a8053e6b0` |
| Build | Swift 6.3.2, release, four build jobs; source-matched Metal library |
| Hardware | Apple M5 Max, 128 GiB unified memory, macOS 26.5.2 |
| Model | `EigenLabs/Qwen3.8-27B-4bit-mtp` |
| Model revision | `06d517d395dfc5588090f7f534112bee331f7b4a` |

All 16 model files were hashed before the run. All five files whose Hugging Face
blob names are SHA256 hashes matched those names. The model and build manifests
are in [the evidence directory](evidence/2026-09-05-radix-prefix-cache/model-manifest.json).
The baseline used its pinned submodules, independently of the mutable candidate.

## Local HTTP baseline

The provider served only localhost. `mtp_mode = "off"`, one concurrent request,
greedy sampling, and `enable_thinking = false` were explicit.
`DARKBLOOM_PREFIX_CACHE=1` enabled cache construction, with an isolated test SSD
directory and ephemeral key.
Model loading and one eight-token warmup were recorded separately and excluded.

There were three repetitions of each six-request conversation: first request,
identical repeat, sibling branch, repeated branch, second turn, repeated second
turn. Each repetition changed the beginning of the conversation. The generated
assistant answer was retained when constructing the second turn. Later builds
replay the exact baseline request bodies, including that answer.

These are median client TTFT values in seconds. The lengths are actual provider
usage counts; the harness's nominal 512/2048/8192 lengths are approximate.

| First-request prompt tokens | First request | Identical repeat | Sibling branch | Second turn |
|---:|---:|---:|---:|---:|
| 381 | 0.4573 | 0.4581 | 0.4563 | 0.5736 |
| 1,411 | 1.5654 | 1.5690 | 1.5409 | 1.6723 |
| 5,523 | 6.5541 | 6.5643 | 6.5637 | 6.7046 |

Branches contained three fewer prompt tokens. Second turns contained 469,
1,499, and 5,611 prompt tokens respectively. Each of these requests generated
64 tokens. All 27 repeated pairs had equal full text, reasoning, prompt and
completion counts, and finish reasons.

The separate decode cases used 32 prompt tokens and generated 256 tokens.
Their median TTFT was **0.1167 seconds**, and the client decode-rate estimate
was **33.712 tokens/second**. The estimate uses the completion count and time
between first and last content chunks; a stream chunk can contain multiple
tokens, so it is not an engine token-timing measurement.

The run completed 57 measured requests, one excluded warmup, and a disconnect
followed by a recovery request. The provider reported zero errors. The recovery
completed successfully. Metrics confirmed `mtp_enabled = 0`, `mtp_active = 0`,
and zero MTP rounds.

The HTTP API at this commit does not expose generated token IDs or prefix cache
usage fields. These HTTP comparisons prove text/count equality only.

## Direct engine baseline

The companion executable replayed the same 57 requests through the production
factory, with greedy sampling, no drafter, a 16 GiB KV budget, and one concurrent
request. It resolved to the contiguous backend. **All 57 usage records reported
cache disabled and zero saved tokens.** All 27 repeated pairs matched actual
generated token IDs and finish reasons. Its separate decode median was
33.713 tokens/second.

The tenant A/A/B probes returned equal token IDs and no cache reuse. Cancellation
returned `cancelled`; the subsequent request produced the expected 64-token
completion. This establishes the cold oracle; it does not prove isolation of a
cache that was inactive. The raw engine report retains prompt and generated
token IDs, per-delta timestamps, terminal usage, and prefill geometry.

The engine run entered at 33.0°C, reached 92.2°C, and had a minimum loaded GPU
frequency of 1,133 MHz across 1,375 loaded samples. Its excluded warmup was eight
tokens. First-use compilation for a new prompt shape can still affect its first
measured request.

## Existing MTP-on control

A separate seven-request control replayed the first long conversation and one
256-token decode request with `mtp_mode = "on"`. Metrics confirmed MTP active,
251 rounds, 792 proposed tokens, and 397 accepted tokens. The decode request
had 0.0954-second TTFT and a client decode-rate estimate of 54.395 tokens/second.
This is one control request, not a three-repetition median.

Three of the seven MTP-on outputs differed in text from their serial references:
the sibling branch, its repeat, and the decode request. Counts and finish reasons
matched. All three repeated pairs within MTP-on matched full text and counts.
The harness deliberately returned nonzero for the cross-mode differences; all
requests completed and provider metrics reported zero errors. This is existing
baseline behavior. Candidate MTP-on validation must use this MTP-on oracle;
serial and MTP-on output equality is not an assumed invariant.

## Measurement limits

The entry GPU temperature was 24.1°C. Across the complete run, sampled GPU
temperature reached 92.0°C. Minimum loaded GPU frequency was 1,133 MHz over
1,197 loaded samples, above the prior 1,000 MHz measurement floor. The retained
telemetry includes model loading and warmup. Temperature and first-use kernel
compilation can affect small latency differences; this baseline alone supports
no cache speedup claim.

The direct engine companion calls `EngineV2Factory.makeProductionBuild`; it does
not exercise the slot's backend selection policy. Its results must accompany
the production HTTP path, not substitute for it. Normal Qwen serving with MTP
enabled requires a separate control before claiming default-serving gains.

## Reproduce

Create a detached worktree at `e928d395f`, initialize recursive submodules, and
verify the worktree is clean. Build from its `provider-swift` directory:

```sh
swift build -c release --product darkbloom --jobs 4
```

Run `scripts/fetch-metallib.sh` against that worktree's release binary directory.
Archive the binary, Metal library, resource bundles, recursive submodule pins,
and hashes before transferring them to the dedicated test machine. Verify
model and transferred artifact hashes before loading the model.

From the benchmark scripts directory on the dedicated Mac:

```sh
python3 run_radix_http.py --binary /path/to/baseline/darkbloom \
  --output /path/to/new-baseline-run --mtp off --cache on --repeats 3

python3 run_radix_http.py --binary /path/to/candidate/darkbloom \
  --output /path/to/new-candidate-run --mtp off --cache on \
  --replay /path/to/new-baseline-run/http/report.json
```

The runner refuses an existing provider, active ranked job, occupied port, high
entry temperature, or an existing retired shared cache. It owns its child
process groups and stops its work if a ranked job appears. PID, discovery, and
SSD test paths are isolated under the fresh output directory. It installs no
daemon or launch agent.

The exact measured HTTP client is retained compressed alongside the report;
`report.json` records its source hash. Run the client parser/equality tests with:

```sh
python3 -m unittest discover -s scripts/benchmarks -p 'test_radix_prefix_cache.py'
```

## Retained evidence

- [Provider artifact identity](evidence/2026-09-05-radix-prefix-cache/baseline-provider-artifact.json)
- [Raw requests, complete SSE events, outputs, and counts](evidence/2026-09-05-radix-prefix-cache/baseline-http-report.json.gz)
- [GPU telemetry](evidence/2026-09-05-radix-prefix-cache/baseline-http-telemetry.jsonl.gz)
- [Run metadata and explicit environment](evidence/2026-09-05-radix-prefix-cache/baseline-http-metadata.json)
- [Provider metrics after the run](evidence/2026-09-05-radix-prefix-cache/baseline-http-metrics-after.txt)
- [Disconnect and recovery evidence](evidence/2026-09-05-radix-prefix-cache/baseline-http-cancellation.json)
- [Raw engine tokens, cache usage, and timing](evidence/2026-09-05-radix-prefix-cache/baseline-engine-report.json.gz)
- [Engine artifact and compile define](evidence/2026-09-05-radix-prefix-cache/baseline-engine-artifact.json)
- [MTP-on request/output control](evidence/2026-09-05-radix-prefix-cache/baseline-mtp-http-report.json.gz)
- [MTP-on counters](evidence/2026-09-05-radix-prefix-cache/baseline-mtp-metrics-after.txt)
