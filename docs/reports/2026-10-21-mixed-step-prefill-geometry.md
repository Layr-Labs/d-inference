# Mixed-step prefill geometry: load, engine and memory measurements

> Last updated: 2026-10-21

A 2,048-token plain prefill chunk with a 4,096-token step budget cut busy-engine
time to first token on GPT-OSS 20B, Qwen3.5-9B and Gemma 4 26B QAT under a
production-like load, and raised per-stream decode p50, on an M5 Ultra and an
M3 Ultra. At eight concurrent 32k-token prompts the KV-subtracted activation
peak rises by 0.1-1.3 GiB: Gemma stays well inside its floor, GPT-OSS moves from
its 3.5 GiB floor to 0.1 GiB above it, and Qwen3.5-9B, already above the 5.5 GiB
default under its existing 4,096-token solo stripe, rises another 0.3 GiB.
MoE Qwen, which keeps 512 / 2,048, rises 2.1 GiB. These results back the
[prompt geometry](../architecture/inference.md#prompt-geometry) defaults; they
are performance and memory evidence, not quality qualification.

## Mechanism

With one partial prefill, a busy engine prefills only its plain chunk beside
decode rows: the solo stripe disarms whenever an unpaused decode row exists.
Production therefore fed every mixed step 512 prompt tokens. On the M5 Ultra a
Gemma 4 `gather_qmm` reaches 26-31 TFLOPS at 512 rows, 57-68 at 2,048 and 85 at
4,096, and every step pays a fixed host and readback cost, so larger chunks
finish a prompt in a quarter of the mixed steps and leave decode rows more steps
without prompt work.

## Load test

Poisson arrivals; prompt lengths lognormal with median 4k and p90 16k tokens,
capped at 32k; 100-600 output tokens; temperature 0.7; a unique nonce per prompt
(no prefix reuse); the same seeded schedule (seed 7) for every arm; the
standalone server with MTP auto and paged KV. M5 Ultra: 0.3 requests/s for
240 s (78 requests), width pinned at 8, builds paused. M3 Ultra: 0.1 requests/s
for 300 s (32 requests); Qwen3.5-9B used the M3 default width of 4 and was
overloaded. Arm A set `DARKBLOOM_CBV2_PREFILL_CHUNK=2048` and
`DARKBLOOM_CBV2_STEP_TOKENS=4096` on an otherwise unchanged build; every other
setting stayed at production defaults. All 78 M5 Ultra requests and all 32
M3 Ultra Gemma requests completed in both arms; the M3 Ultra GPT-OSS and Qwen
rows are summary figures without retained per-request receipts.

| Mac | Model | TTFT p50 / p90 / p99 s, base | Arm A | Decode p50 tok/s, base → A | Decode p10, base → A |
|---|---|---|---|---:|---:|
| M5 Ultra | Qwen3.5-9B | 2.25 / 6.97 / 9.13 | 1.67 / 5.48 / 7.66 | 40.3 → 49.5 | 19.0 → 21.4 |
| M5 Ultra | Gemma 4 26B QAT | 1.34 / 3.87 / 5.91 | 0.56 / 2.47 / 4.46 | 51.3 → 58.8 | 25.7 → 34.9 |
| M5 Ultra | GPT-OSS 20B | 1.56 / 6.14 / 9.03 | 1.19 / 4.57 / 7.53 | 51.5 → 59.7 | 21.5 → 26.6 |
| M3 Ultra | Gemma 4 26B QAT | 5.15 / 10.62 / 16.94 | 4.15 / 8.96 / 14.51 | 46.1 → 54.6 | 14.3 → 16.4 |
| M3 Ultra | GPT-OSS 20B | 7.36 / 15.9 / 23.0 | 6.76 / 13.84 / 20.9 | 52.7 → 55.8 | — |
| M3 Ultra | Qwen3.5-9B, width 4 | 18.33 / 33.59 / 38.32 | 18.04 / 31.12 / 35.66 | 36.3 → 40.7 | — |

Aggregate output was arrival-bound and unchanged (about 118 tok/s on the
M5 Ultra, 37.8 tok/s for Gemma on the M3 Ultra). Solo cold prefill does not
change: the 2,048-token chunk equals the GPT-OSS and Gemma stripe, and an
M3 Ultra stripe sweep of 2,048 / 4,096 / 8,192 tokens moved solo TTFT by under
2%.

## Engine cells and inter-token latency

`darkbloom benchmark --sweep` on the production paged factory, M5 Ultra, eight
rows submitted together with 512 decode tokens each, so later rows prefill
beside up to seven decoding rows. The GPU was shared with other jobs; read the
arms as paired comparisons, not as absolute throughput.

| Model, 8 × 8,192-token prompts | Last first token s, 512 / 2,048 → 2,048 / 4,096 | Decode p50 tok/s | ITL p50 / p90 / p99 / max ms, 512 / 2,048 | ITL, 2,048 / 4,096 |
|---|---:|---:|---|---|
| Gemma 4 26B QAT | 12.13 → 7.90 | 34.2 → 40.0 | 20.4 / 90.6 / 112.7 / 198 | 18.8 / 21.0 / 255.7 / 495 |
| GPT-OSS 20B | 14.01 → 10.33 | 30.0 → 35.3 | 23.4 / 98.9 / 131.2 / 232 | 20.5 / 22.0 / 326.9 / 682 |
| Qwen3.5-9B | 15.06 → 12.50 | 33.0 → 36.4 | 19.3 / 111.2 / 135.8 / 244 | 17.5 / 19.2 / 400.9 / 779 |

The 2,048 / 4,096 geometry makes most inter-token gaps shorter because a quarter as many
decode tokens share a step with prompt work, but a token that does share one
waits for the whole 2,048-token chunk: the p99 and maximum gaps grow two to
three times. With 32 decode tokens per row at 32,768-token prompts, every decode
token lands in such a step and a stream decodes at 2.6 instead of 8.9 tok/s
(Gemma) and 1.5 instead of 8.2 tok/s (GPT-OSS) while the next prompt prefills.

## Activation memory

`ChunkGeometryActivationProbe` (a temporary provider test, not committed)
built the production paged engine through `EngineV2Factory.makeProductionBuild`
for each arm, submitted eight rows of the stated prompt length, and polled the
engine's segmented-pool committed bytes every 2 ms. It estimates the
activation term twice: the MLX peak above the pre-cell active bytes minus the
KV committed at the sample that observed the peak, and the largest sampled
active-minus-committed bytes. No MTP drafter was attached.

Values are the larger estimate, in GiB, for eight rows: 512 decode tokens per
row at 8,192-token prompts, 64 at 32,768. The 512 / 2,048 arm includes each
family's production stripe (4,096 for Qwen3.5-9B).

| Model, floor | Prompt tokens | 512 / 2,048 | 2,048 / 4,096 | 2,048 / 2,048 |
|---|---:|---:|---:|---:|
| Gemma 4 26B QAT, 5.5 | 8,192 | 1.62 | 2.00 | — |
| Gemma 4 26B QAT, 5.5 | 32,768 | 2.44 | 3.73 | 3.15 |
| GPT-OSS 20B, 3.5 | 8,192 | 2.37 | 2.49 | — |
| GPT-OSS 20B, 3.5 | 32,768 | 3.50 | 3.62 | 3.49 |
| Qwen3.5-9B, 5.5 | 8,192 | 4.04 | 4.07 | — |
| Qwen3.5-9B, 5.5 | 32,768 | 5.73 | 6.03 | 5.63 |
| Qwen3.5-35B-A3B, 5.5 | 8,192 | 2.85 | 4.72 | — |
| Qwen3.5-35B-A3B, 5.5 | 32,768 | 4.12 | 6.26 | 4.65 |

The 4,096-token budget, which lets a finishing prompt and its successor share a
step beside decode rows, accounts for the increase over 2,048 / 2,048. A
2,048-token budget keeps GPT-OSS and Qwen3.5-9B at their previous peaks, but
then every chunk beside decode rows is 2,048 minus the decode tokens long:
dense Qwen range ends never reach the 256-token recurrent checkpoint grid under
decode company, and contiguous GPT-OSS uniform-cap capture disarms. Both floors
were already reached by the previous geometry at this load, so they need a
long-context re-measurement either way. With the GPU shared, the 512 / 2,048 32k
arms for Gemma and GPT-OSS each lost rows to the 120 s admission lease; every
2,048 / 4,096 row completed, the last first token at 80 s and 100 s.

## Gemma 4 media

A Gemma 4 26B QAT paged request with one 280-token image span 768 tokens before
the end of the prompt, prefilled alone (`ChunkDefaultsVisionProbe`):

| Prompt tokens | Arm | Largest chunk | Peak above active GiB |
|---:|---|---:|---:|
| 8,192 | 512 / 2,048 | 512 | 1.097 |
| 8,192 | 2,048 / 4,096 without a media ceiling (earlier build) | 2,048 | 1.857 |
| 8,192 | production default (media ceiling 512) | 512 | 1.097 |
| 32,768 | 512 / 2,048 | 512 | 2.124 |
| 32,768 | 2,048 / 4,096 without a media ceiling (earlier build) | 2,048 | 3.967 |
| 32,768 | production default (media ceiling 512) | 512 | 2.124 |

A paged span-bearing chunk attends in one unblocked call whose score tensor
grows with the chunk length times the history, so the uncapped arm adds
1.84 GiB at 32k and would grow with longer histories. With the ceiling the
image request is chunked and peaks exactly as before. Text prompts peaked at
1.68-1.73 GiB at 8k and 3.464 GiB at 32k in both arms, because the 2,048-token
chunk equals Gemma's former stripe.

## Limitations

- Only GPT-OSS 20B, Qwen3.5-9B and Gemma 4 26B QAT were load-tested. MoE Qwen,
  Qwen3-VL, Qwen4, MiMo, Nemotron and Bonsai keep 512 / 2,048.
- The engine cells and probes ran on a shared GPU; their timings are paired
  comparisons. Memory counters are process-local and unaffected.
- No load arm used repeated prefixes. Dense Qwen donors prefilled beside decode
  rows now leave recurrent checkpoints every 2,048 tokens.
- Inter-token gap tails were measured only in the engine cells, on the
  M5 Ultra. Slower GPUs stretch each mixed step proportionally.
- The memory probes attached no MTP drafter and used eight rows on one
  M5 Ultra. Prompts beyond 32k tokens, four-row widths and 16-24 GB Macs were
  not measured; the floors are the same constants on every Mac.
