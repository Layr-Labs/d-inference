# GLM-5.3-Flash single-Mac qualification record

> Last updated: 2026-10-21

This record summarizes the checks of GLM-5.3-Flash (`glm5_next`) served by one
M5 Ultra with 256 GB through the native paged CBv2 engine with its embedded MTP
layer. It contains no endpoint, credential, machine identifier or personal
workspace location. Passing these checks is not hosted-provider certification,
catalog activation or production deployment approval.

## Artifact, executables and policy

| Item | Value |
|---|---|
| Artifact | `EigenLabs/GLM-5.3-Flash-MLX-NVFP4-mtp` at Hugging Face revision `8841c52a1e8400bd7d3e7e631c916a6c4e6757b0` (`GLM5NextArtifactPin`) |
| Manifest aggregate | `3aae613ff188bb0f72e880774a84e4d8e9943ab20c929d8a302af9c57b97d5ac`, 42 files, 181,752,181,866 bytes |
| Config / index / inventory | config `949a3db1…`, index `b6cdec53…`, inventory `47687e80…`; 114,160 tensors in 35 shards |
| Hugging Face check | every manifest file present at `8841c52a` with matching LFS SHA-256; the catalog's earlier pin `8603f7fe` differs only in `README.md` |
| Selection | local qualification selection, `maximumContextLength` 65,536 |
| Policy | `GLM5NextExecutionPolicy.serving` (enforced by the managed load), paged KV, embedded MTP with adaptive rectangular verification up to depth 3 |
| SDK | mlx-swift-lm `main` `19634dd8` (#314 squash-merged: `ffb71842` plus #318, a Nemotron-only change no GLM path reaches) on mlx-swift `main` `67dc7528` (#58), core `main` `ad4745a2` (#37) and mlx-c `main` `5e9be4da` (#16). Those native merges have exactly the trees of the qualified `d80124e`, `ad596687` and `fa6565d4`; `d80124e` differs from the earlier `c2cbef34` only in its two submodule pins. The final executable compiled mlx-swift-lm `ffb71842` (see "Paged-attention speedups"). `ffb71842` takes the split-K paged decode attention of `12d00808`/`13fba500` out again; `46e4d0ba` is swift-format layout only. The previous final executable compiled `a630039b`; `77a0d1d9` changes only tests and one line break. Earlier checks ran on `97b2ca6d`/`48f1e000` and earlier native heads |
| Metallib | `156f2624f9f1b1413dfabd8b6e16423121b0e5b18e2573c23c4e023b606a462d` (unchanged by this work) |
| Executables | final: `darkbloom` `6b95747e49d50d32b16018a53bc5fb22a77bd7db2478933e3495b1e15a22db02` (#1516 with SDK `ffb71842`; see "Paged-attention speedups"). Before that: `344b39e3…` (SDK `13fba500`, evaluated with split-K paged decode, not shipped), `e31b5ba9…` (A/B build, SDK `12d00808`), `d9780e867576bf14208d15ff6e80037dd9a54438a6f9b15264eed7b901e74945` (#1516 with SDK `a630039b`; see "Final recheck after merging main"), DEBUG variant `d0974768…` (SSD restart only), `94a83e27…` (production footprint policy recheck), `593cd3d0…` (refusal probes and confirmation soak), `8eee2c99…` (admission checks and the 40-minute soak), `798b5562…` (port gate, endpoint, media, prefix checks), `529e6ab8…` (performance table, long context, video proof), DEBUG `3256e2c7…`/`4f7fd9df…` (SSD restart checks) |

The hardware is one Apple M5 Ultra with 256 GB on macOS 27.0.1. M5 Max is admitted by
`GLM5NextHardwareRequirement` but was not measured.

## Recorded checks

| Gate | Result | Evidence |
|---|---|---|
| Artifact and load | pass | Aggregate `3aae613f…` before and after load; template SHA accepted; `paged_kv_grant_bytes` 59,790,694,781 |
| Memory during load | pass | Uncached (`F_NOCACHE`) weight hashing: file cache flat at 25 GB, compressed memory 2.8 GB, pressure normal throughout, 36 GB free at ready. Cached hashing previously pushed ~150 GB of the loaded weights into the compressor (pressure warning) and stalled the first request for 17.5 s |
| MTP on by default | pass | `mtp_enabled 1`, `mtp_active 1` under the default `mtp_mode = "auto"`; greedy acceptance 0.49 and sampled acceptance 0.61 per proposed token on a 256-token request; SDK fixed-depth acceptance 0.79 (d1 serial), 0.69 (d2), 0.60 (d3) |
| Speedup port is bitwise | pass | SDK real-model MTP test, 6 prompts (9–3,000 tokens) × 256 tokens × target-only/serial/d1/d2/d3: 30/30 identical token sequences; provider endpoint (serial-target mode, 14 cases incl. 31.6K prompt, 3-turn chat, image, concurrent pair): 14/14 byte-identical in two runs |
| Quality | pass | Perplexity panel (`GLM5NextRealPerplexityTests`, `.serving`, 2,048-token chunks, 15,909 tokens in 4 documents): 7.313970 before and after the port, 15,901/15,901 top-1, 0 NLL differences |
| Endpoint correctness | pass with one limit | 391; streaming; stop strings (array; scalar is a 400); length; over-context 400 at the exact bound; client disconnect releases the request in 0.26 s; reasoning efforts minimal–max; thinking-off refused 400; tools `auto`; `required`/named refused 400; `/v1/responses` with `previous_response_id`. Omitted `max_tokens` gives 4,096. Seeded sampling is **not** run-to-run reproducible with adaptive MTP (see limits) |
| OpenRouter templates | pass (local emulation) | 12/12 templates, streaming and non-streaming, using the shapes that reach the provider after the coordinator inlines URLs: images, both video templates, max-tokens, multi-system, multi-turn, reasoning, reasoning-content-return, efforts high/low/max |
| Prefix cache (SSD tier) | pass | 10.6K-token repeat: 10,240 cached, TTFT 6.79 → 1.22 s; extended prompt hits on first send; 3-turn chat cached 0 → 6,144 → 8,192; media requests excluded and same-prefix text still hits |
| SSD tier across restart | pass (persistent key) | 20,022-token prompt: cold TTFT 10.70 s, after a server restart 18,432 cached and TTFT 2.15 s |
| Images | pass | 48/51 kit cases: exact media token counts at every size (16–8,000 tokens, 4000×3000 → 7,931), OCR, counting, five formats, 16 images, aggregate cap, all refusals (400/413/503). Three misses are a large slashed-zero bitmap glyph read as 9 |
| Video | pass | 15/15 clips: direction left/right with reversed controls, frame counter, colour sequences (MP4, QuickTime, NTSC timescales), 720p30 at 12,056 tokens (TTFT 7.5 s), 1080p near the cap at 21,612 tokens (TTFT 13.6 s), two videos, image plus video; over-cap, too-short and variable-frame-rate clips refused 400 |
| Long context | pass to 128K (listed) | Needle at 10/50/90 % depth: 6/6 at 32K and 60K tokens; 128K pass (1,661 tok/s prefill); 190K pass (1,539 tok/s, 2.7 GB free); 250K refused at ~220K on one 256 GB Mac. The catalog listed 131,072 during these checks; it now lists the model's full 262,144 and admission refuses what one Mac cannot fit |
| Continuous batching | pass with limit | c1/c2/c4 all complete; aggregate decode does not scale (see performance) |
| Admission when full | pass (after two fixes) | See "Memory admission" below |
| Retained faults | pass | `darkbloom_glm5_next_retained_*` 0 after every run |
| Soak | pass | 40 minutes, 1,464 mixed jobs at c1–c4 (text, images, cancels, sampled, long prefill, prefix reuse): no hang, no retained fault, idle at the end, memory pressure normal throughout; it found the in-band full-Mac refusal (fixed). 20-minute confirmation soak on the final executable: 865 jobs, 0 `server_error`, capacity refusals all 503 |

## Performance (one M5 Ultra 256 GB)

Final executable, 131,072-token selection (the context listed at the time), SSD prefix tier on, default
adaptive MTP, 5 repetitions (medians):

| Measure | Baseline (pre-port, 2026-10-20) | Final | Change |
|---|---|---|---|
| Prefill 2.7K / 10.5K / 31.5K tokens (tok/s) | 1,631 / 1,801 / 1,803 | 1,906 / 2,030 / 2,029 | +17 / +13 / +13 % |
| Prefill 64K / 125K tokens (tok/s) | — | 1,903 / 1,597 | — |
| Decode 256 / 1,024 tokens, adaptive MTP (tok/s) | 58.4 / 53.7 | 64.0 / 65.7 | +10 / +22 % |
| TTFT with a prefix-cache hit, 2.7K / 10.5K / 31.5K | — | 0.72 / 0.85 / 2.09 s (cold 1.41 / 5.21 / 15.55 s) | — |
| Aggregate decode c1 / c2 / c4 (tok/s) | — | 61.0 / 73.9 / 94.7 (per request 65.5 / 38.3 / 24.7) | — |
| Image TTFT-to-answer, 1,202 / 8,002 visual tokens | — | 1.32 / 6.35 s | — |
| Video TTFT, 1,270 / 12,056 / 21,612 tokens | — | 1.94 / 7.53 / 13.75 s | — |
| Same-day A/B, deterministic serial mode: prefill / decode | 1,692–1,820 / 40.4 | 1,904–2,053 / 47.6 | +12.5–12.8 % / +16–18 % |
| Prefill at 32K / 60K (needle prompts) | — | 2,019–2,031 / 1,895–1,925 | — |
| Same-day A/B, image TTFT, 1,202-token image | 0.93 s | 0.84 s | −10 % |

MTP speculates for one row at a time (`maxSpeculativeBatch` 1), so from two
concurrent requests on, rows decode without speculation and aggregate decode
grows slowly (c4 is 1.55× c1).

## Paged-attention speedups (SDK ffb71842)

GLM serves only through the paged CBv2 path; the contiguous forward is
deprecated. SDK `ffb71842` brings three speedups that previously reached only the
contiguous forward to paged serving, each bit-identical:

| Change | Steps | Bits |
|---|---|---|
| Shared all-true validity constant and one-launch packed-embedding streams (`GLM5NextPackedEmbedding`) | decode and verification (at most 8 tokens) | identical |
| `.serving` runs `PrefillProjections.nativeGEMM`: `GLM5NextPrefillGEMMKernel` for the KDA and DSA attention projections | Neural-Accelerator prefill | identical (MLX's NAX qmm) |
| `GLM5NextDSAPayloadKernel` stages a DSA layer's FP32 CBv2 rows in one launch instead of a validity cast, a concatenation and two FP32 casts | CBv2 DSA appends | identical |

The fourth, split-K `GLM5NextSparseDecodeKernel.attend` for paged decode and
MTP verification (SDK `12d00808`/`13fba500`), was evaluated and left off
(`ffb71842`): paged decode keeps the absorbed per-query attention of the
qualified build. Split-K gives a contiguous row's arithmetic but not the
qualified paged output: at 8-token steps perplexity is 0.0049 % higher and
top-1 agreement 97.60 %, below the 99.4 % lossless bar (rows below). Its gain
is given up: in a same-state endpoint A/B (default adaptive MTP, sessions
A-B-B-A, medians of 6) the build with it (`e31b5ba9…`) decoded 256 tokens after
10.5K- and 31.5K-token prompts 5.5 and 3.8 % faster than `d9780e86…` (43.3 /
31.3 vs 41.1 / 30.2 tok/s). Prefill in that A/B was 0–1 % faster.

| Check | Result |
|---|---|
| Perplexity panel (4 documents, 15,901 scored positions, `.serving`, 2,048-token chunks) against the previous SDK | bit-identical NLL and argmax at every position (`PrefillProjections.nativeGEMM`) |
| Same panel at 8-token steps (decode-sized; sparse past 2,048 tokens): split-K decode attention (`.serving` at SDK `13fba500`) against absorbed decode attention with the reference selection graph (`sparseDecode: .reference`) | perplexity 7.310244 vs 7.309884 (+0.0049 %); top-1 97.60 % |
| Each 8-token variant against `.serving` at 2,048-token chunks | split-K −0.051 % perplexity, 94.03 % top-1; absorbed −0.056 %, 93.98 % top-1. Both are equally close; the qualified policy agrees 94.0 % with itself across step sizes |

Final executable `darkbloom` `6b95747e49d50d32b16018a53bc5fb22a77bd7db2478933e3495b1e15a22db02` (#1516 with SDK `ffb71842`), metallib
`156f2624…` (unchanged):

| Check | Result |
|---|---|
| SDK real-model MTP tokens vs SDK `77a0d1d9` (6 prompts × 5 modes × 256) | **30/30 identical** token sequences, with identical MTP proposed/accepted counts in every mode |
| Endpoint serial-target mode vs `d9780e86…` (14 cases) | **14/14 identical** (391, 2.7K / 10.5K / 31.6K prompts, 256 / 1,024 decodes, 3-turn chat, image, concurrent pair, repeats). In the first run the concurrent pair's requests arrived 0.28 s apart and one differed; three reruns of the pair with simultaneous arrival are identical, both requests |

The earlier qualification of `d9780e86…` therefore applies unchanged. The
evaluated build with the split-K path (`344b39e3…`, 128K selection) passed the
endpoint checks as `d9780e86…` did, the OpenRouter templates, needles at 64K
and 125K tokens (6/6), images 45/51 (the same misses as `d9780e86…`) and video
15/15.

## Final recheck after merging main

All five native and SDK pull requests merged their base branches, which now
carry the Nemotron 3.5 Super stack (command-buffer limits, custom-kernel math
modes, and engine changes shared by every model: non-finite logit flags and
the durable prefix-checkpoint gate). GLM's declared MTP charge is unchanged
(4,054,826,930 bytes fixed, 33,900 bytes per token). Final executable
`d9780e86…`, metallib `156f2624…`:

| Check | Result |
|---|---|
| Tokens, serial-target mode | 14/14 cases byte-identical to the previous final build, image included; run to run 14/14 |
| Endpoint | 18 of 23 pass; the others are two informational checks, the known seeded-sampling limit, the harness's 64K-selection `over_context` probe (the listed 131,072-token bound is exact: 131,000 output tokens accepted, 131,072 refused) and OpenRouter's `reasoning.exclude: true` / thinking-off shapes, refused with 400 by design; every other OpenRouter reasoning shape returns 200 |
| OpenRouter templates | none failed, streaming and non-streaming |
| Images / video | images 45/51 (the three known slashed-zero glyph misreads and three harness cases written before video was served or needing a special restart); video 15/15 |
| Prefix cache | 10.6K repeat 10,240 cached, TTFT 5.36 → 1.21 s; extended, multi-turn and media cases pass |
| SSD tier across restart (DEBUG, persistent key) | 20,015-token prompt: 18,432 cached after the restart, TTFT 1.99 s |
| Long context | needles at 64K and 125K (125,494 tokens, TTFT 80.0 s) pass |
| Admission flood, 8 × (~30K + 30K) | 3 served, 5 clean 503, idle 0.26 s after, faults 0 |
| Soak, 20 minutes (seed 5301) | 466 ok, 34 intended cancels, 93 capacity 503, 0 other errors, faults 0, idle at the end; memory pressure normal in every sample of the whole recheck |
| Performance | same-state A/B against the previous final build: prefill 1,904 / 1,935 / 2,019 vs 1,679 / 1,981 / 2,008 tok/s, decode 59.1 / 59.8 vs 60.1 / 60.6 tok/s: equal within run-to-run variation |

## Recheck after restoring production footprint charges

The first chain (core `2bba342d`) included a one-page minimum in the Metal
footprint policy. With it, the SDK's estimates for MTP drafters that declare no
buffer layout grow from kilobytes to 37–671 MB per token (Qwen4 inline MTP,
NemotronH35 MTP), so their requests could never be admitted. This release must
not change how other models are charged, so the core reverts it (`4a355746`,
mlx#37) and the policy equals the current provider release again. The SDK also
merged main (#316: provider-staged checkpoint imports from host zeros). GLM's
serving MTP charge is now 4.05 GB per request (4.89 GB with the minimum).

Final executable `94a83e27…`, metallib `156f2624…`:

| Check | Result |
|---|---|
| Tokens, serial-target mode | 13/13 text cases identical to the pre-port and port builds (incl. 31.6K prompt, 3-turn chat, concurrent pair); image case identical to the previous final build; two runs 14/14 identical |
| Admission flood, 8 × (~30K + 30K) | unchanged: 3 served (first tokens 16.5 / 32.7 / 62.3 s), 5 clean 503 before headers, idle 0.26 s after, faults 0 |
| Performance | prefill 1,899 / 2,023 / 2,009 tok/s (2.7K / 10.5K / 31.5K); decode 62.2 / 67.7 tok/s (256 / 1,024, adaptive MTP); c1 / c2 / c4 complete |
| Prefix cache | 10.6K repeat 10,240 cached, TTFT 1.13 s; extended, multi-turn and media cases pass |
| SSD tier across restart (DEBUG, persistent key) | 20,015-token prompt: same process 18,432 cached (1.87 s); after a restart 18,432 cached, TTFT 2.31 s |
| Long context | needle 64K and 125K (125,266 tokens, TTFT 77.6 s) pass |
| Soak, 20 minutes (seed 5301) | 559 jobs: 471 ok, 33 intended cancels, 55 capacity 503, 0 other errors, faults 0, idle at the end; up to 4 requests active; memory pressure normal in every sample, at least 23 GB free, no swap growth |

## Memory admission

| Scenario (SSD prefix store on) | Before the fixes | Final build |
|---|---|---|
| 8 concurrent requests of ~30K prompt + 30K output tokens | 5 refusals rendered as 200 + `server_error` frames; the 2 running and 1 waiting request all failed together when the second finished prefill | 5 clean 503 "Provider capacity is temporarily unavailable." before headers; the 3 that fit are served (first tokens 17.6 / 32.5 / 63.4 s); idle again 0.26 s after |
| 3 concurrent requests of ~30K + 30K | all 3 failed at 32 s | requests 1 and 2 keep decoding, request 3 waits for capacity |
| One request at ~250K tokens | refused at ~220K (no OOM) | unchanged; the catalog then advertised 131,072 (now 262,144) |

The first fix throws the GLM slot refusal before the stream starts. The second
defers a step whose scratch reservation is refused instead of failing every
row of that step: rows roll back exactly, the newcomers wait, and new
admissions pause until a running request leaves (`EngineLoopV2.engineStep`,
`deferStepAfterScratchRefusal`, `CBv2StepScratchRefusal`). No run produced an
OOM, a GPU hang or a retained GLM fault, and memory pressure stayed normal.

## Known limits and open issues

- Default adaptive MTP chooses its depth from measured cost, and verify windows
  round differently from one-token steps, so greedy and seeded sampled output
  is not run-to-run reproducible. `DARKBLOOM_GLM_RECTANGULAR_VERIFY=0` gives
  reproducible output at lower decode speed.
- Aggregate decode barely scales with concurrency because MTP speculates for
  one row only.
- The SSD tier needs the keychain-wrapped persistent key of a signed app; an
  ad hoc build serves without a prefix cache and reports
  `prefix_cache_status{state="error",reason="cache_init_failed",detail="key_unavailable"}`.
- `reasoning.exclude: true` and `include_reasoning: false` are refused: the
  provider returns the reasoning it generates. Thinking-off controls were
  refused during these checks; they are now served with a closed
  `<think></think>` block (`GLM5NextThinkingTokenizer`), checked by unit tests
  and the platform sidecar render tests, not by this hardware record.
- Video: inline MP4/QuickTime only at the provider (the coordinator inlines
  URLs); variable-frame-rate clips and clips past the shared 28,532-token
  visual cap are refused.
- M5 Max is not measured.

## Reproduction and related references

The native qualification procedures are in [the test guide](../developer/test.md).
See [inference](../architecture/inference.md) for the GLM serving mechanism,
[configuration](../reference/configuration.md#local-glm-qualification) for the
local selection and [the SSD cache reference](../reference/ssd-kv-cache.md).
