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
| SDK | mlx-swift-lm `48f1e000` (#314) on mlx-swift `cf921c05`, core `2bba342d`, mlx-c `2f1bcab9` |
| Metallib | `156f2624f9f1b1413dfabd8b6e16423121b0e5b18e2573c23c4e023b606a462d` (unchanged by this work) |
| Executables | final: `darkbloom` `593cd3d08748a75e118c2dc45976ccb33fc96340b2349df02b6a9e681c33ea86` (= #1516 `1216ffb84`, SDK `48f1e000`; refusal probes and confirmation soak); `8eee2c99…` (#1516 `23eb9d377`; admission checks and the 40-minute soak). Earlier builds of the same chain: `798b5562…` (port gate, endpoint, media, prefix checks), `529e6ab8…` (#1516 `e114fc348`; performance table, long context, video proof), DEBUG variant `3256e2c7…` (SSD restart check only). The SDK changes after the port gate (`0ceec3ab`… `48f1e000`) only gate a non-bitwise path off, change admission charges, video decoding and the step-refusal path; none changes text numerics |

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
| Long context | pass to 128K (listed) | Needle at 10/50/90 % depth: 6/6 at 32K and 60K tokens; 128K pass (1,661 tok/s prefill); 190K pass (1,539 tok/s, 2.7 GB free); 250K refused at ~220K on one 256 GB Mac. The catalog lists 131,072 |
| Continuous batching | pass with limit | c1/c2/c4 all complete; aggregate decode does not scale (see performance) |
| Admission when full | pass (after two fixes) | See "Memory admission" below |
| Retained faults | pass | `darkbloom_glm5_next_retained_*` 0 after every run |
| Soak | pass | 40 minutes, 1,464 mixed jobs at c1–c4 (text, images, cancels, sampled, long prefill, prefix reuse): no hang, no retained fault, idle at the end, memory pressure normal throughout; it found the in-band full-Mac refusal (fixed). 20-minute confirmation soak on the final executable: 865 jobs, 0 `server_error`, capacity refusals all 503 |

## Performance (one M5 Ultra 256 GB)

Final executable, 131,072-token selection (the listed context), SSD prefix tier on, default
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

## Memory admission

| Scenario (SSD prefix store on) | Before the fixes | Final build |
|---|---|---|
| 8 concurrent requests of ~30K prompt + 30K output tokens | 5 refusals rendered as 200 + `server_error` frames; the 2 running and 1 waiting request all failed together when the second finished prefill | 5 clean 503 "Provider capacity is temporarily unavailable." before headers; the 3 that fit are served (first tokens 17.6 / 32.5 / 63.4 s); idle again 0.26 s after |
| 3 concurrent requests of ~30K + 30K | all 3 failed at 32 s | requests 1 and 2 keep decoding, request 3 waits for capacity |
| One request at ~250K tokens | refused at ~220K (no OOM) | unchanged; the catalog advertises 131,072 |

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
- `reasoning.exclude: true` and thinking-off controls are refused: GLM-5.3-Flash
  always reasons.
- Video: inline MP4/QuickTime only at the provider (the coordinator inlines
  URLs); variable-frame-rate clips and clips past the shared 28,532-token
  visual cap are refused.
- M5 Max is not measured.

## Reproduction and related references

The native qualification procedures are in [the test guide](../developer/test.md).
See [inference](../architecture/inference.md) for the GLM serving mechanism,
[configuration](../reference/configuration.md#local-glm-qualification) for the
local selection and [the SSD cache reference](../reference/ssd-kv-cache.md).
