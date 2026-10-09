# Two-Mac baseline, load generator and catalog model matrix

> Last updated: 2026-10-09

One night of measurement on the two Macs used for the cluster work: "Mac A"
(M3 Ultra, 256 GB, macOS 27.2) and "Mac B" (M5 Max, 128 GB, macOS 27.0),
provider 0.9.19 built in release configuration from `f93e4cf7f`
(`kimi/cluster-foundation-20261007`). It records the single-Mac "before" for
the two-Mac cluster through the product's own serving path, the state of every
catalog model on each Mac, and the tooling added to take the measurements. It
does **not** contain a two-Mac "after": the Thunderbolt port on Mac B had lost
its address and no pair run could be made that night.

Every time below is on the client's monotonic clock on the serving Mac over
loopback, from just before the request is written; token counts are the
server's `usage`. The provider reports no timings over HTTP. "Prefill tok/s" is
prompt tokens divided by time to first token (it includes HTTP, templating,
tokenization and queueing); "decode tok/s" is (output tokens - 1) over the time
between the first and last streamed token. Greedy sampling, thinking disabled,
128 output tokens, each prompt unique unless a row says "cached".

## What was added

`scripts/benchmarks/cluster/` (standard library only, Python 3.9+):

| File | Purpose |
|---|---|
| `loadgen.py`, `test_loadgen.py` | Streamed chat completions from one fixed text, sized by the server's own token count, closed loop at a chosen concurrency, one record per request, nearest-rank p50/p95, soak with per-minute buckets; self-test against a stub server |
| `serve_bench.py`, `remote_bench.sh` | Start an isolated `darkbloom start --local`, wait on `/health`, run the load, stop with SIGTERM, record memory and leftovers; the same on a second Mac over SSH |
| `fetch_catalog_model.sh`, `verify_artifact.py` | Fetch one catalog model with the product downloader under a disk floor; check a directory against a catalog manifest file by file |
| `pair_sweep.py` | Drive the existing pair driver and reference tool over cuts, schedules and prompt sizes; **written and not exercised against a pair** |
| `with_lane.sh`, `redact.py`, `tables.py` | Shared-lane wrapper, identifier scrubbing, Markdown tables |

Isolation matters for anyone repeating this: `-c` moves only the provider's
configuration file. `start --local` derives every other path from the
Foundation home directory, so the harness sets `CFFIXED_USER_HOME` (setting
`HOME` alone does not redirect it), the per-file state variables, and an
ephemeral prefix-cache root; `darkbloom stop` has no `-c` and is never used.

## Catalog (11 ids, 10 artifacts)

| Model id | Version | Type / family | Quantization | Size GB | Files | Min RAM GB | Needs | Artifact aggregate SHA-256 |
|---|---|---|---|---:|---:|---:|---|---|
| `gpt-oss-20b` | 2026-05-25-r1 | text / gpt-oss | fp8 | 12.1 | 10 | 24 | — | `61bfc04e4016a7fa…` |
| `Qwen3.5-9B` | 2026-09-03-r1 | text / Qwen3.5 | fp4 | 6.1 | 12 | 24 | — | `127de76b4ef82b7a…` |
| `ternary-bonsai-2-27b` | 2026-09-17-r1 | text / Bonsai 2 | 2bit | 8.6 | 8 | 24 | — | `ea1e901e4946c0ba…` |
| `qwen3.6-35b-a3b-vl-mtp-mxfp8` | 2026-08-11-r1 | text / Qwen3.6 | fp4 | 21.3 | 13 | 32 | — | `d932e96b00404b05…` |
| `EigenLabs/Qwen3.8-27B-4bit-mtp` | 2026-09-03-r1 | text / Qwen3.8 | fp4 | 16.3 | 14 | 36 | apple_m5, mlx_nax | `bbd0e0adcfe74e09…` |
| `gemma-4-26b` | 2026-05-25-r1 | text / gemma | 8bit | 28.0 | 13 | 36 | — | `a4722b6020adb189…` |
| `gemma-4-26b-qat-4bit` | 2026-06-08-r1 | text / — | 4bit | 15.6 | 10 | 36 | — | `2468a0cb3049a871…` |
| `qwen3.5-35b-a3b` | 2026-08-25-r1 | text / Qwen3.5 | fp4 | 20.9 | 14 | 36 | — | `95811153b3bb2ed7…` |
| `nvidia-nemotron-3.5-lightning` | 2026-09-30-r1 | text / nemotron | 4bit | 19.1 | 10 | 48 | — | `366d9285ec367633…` |
| `gemma-4-26b-8bit` | 2026-05-25-r1 | text / — | 8bit | 28.0 | 13 | 64 | — | `a4722b6020adb189…` |
| `mimo-v2.6-flash-mopd` | 2026-09-28-r1 | text / mimo-v2.6 | mxfp4 | 172.9 | 53 | 256 | — | `2334547d8acc9898…` |

## Qwen3.5 9B on each Mac alone (product path)

Warm, one request at a time:

| Prompt tok | Mac A first content s | Mac A prefill tok/s | Mac A decode tok/s | Mac B first content s | Mac B prefill tok/s | Mac B decode tok/s |
|---:|---:|---:|---:|---:|---:|---:|
| 65 | 0.114 | 572 | 83.9 | 0.057 | 1,150 | 122.6 |
| 1,023 | 1.025 | 998 | 116.1 | 0.392 | 2,452 | 135.9 |
| 4,097 | 4.227 | 969 | 98.9 | 2.115 | 1,895 | 117.3 |
| 8,186 | 8.580 | 954 | 88.6 | 4.453 | 1,833 | 99.3 |

Concurrency at about 1k prompt tokens, aggregate output tok/s: Mac A 59.8,
66.4, 78.0 at 1, 2 and 4 clients (83.4 at 8 with the engine width set to 8);
Mac B 70.8, 82.8, 102.6 (117.9). Ten-minute mixed-size soak at 4 clients:
Mac A 144 of 144 requests, 30.3 output and 790 prompt tok/s; Mac B 227 of 227,
47.8 and 1,249.

Findings:

- The product decodes at 84-136 tok/s for one stream because MTP speculation
  is active (48-60% of proposed tokens accepted). It switches off as soon as
  two requests are active (387-520 MTP rounds per 1k-token cell at one client,
  25-29 at two, none at four), and per-stream decode falls to 46-52 tok/s.
- Eight clients against the default engine width of 4: 44 of 48 requests were
  refused within 10-50 ms as HTTP 200 with an SSE error frame, on both Macs.
  They are not queued.
- Mac B's first request after a load prefills at 2,460-2,730 tok/s; across ten
  back-to-back 4k requests it fell steadily to about 1,890. macOS recorded no
  thermal warning; the cause was not established. Mac A does not drift.
- In the mixed soak a 64-token prompt's p95 time to first content was 7.9 s on
  Mac A and 4.9 s on Mac B, against 0.11 s and 0.06 s alone.
- The prefix cache reuses in 4,096-token blocks: a repeated 4k prompt is
  answered in 0.10 s, a repeated 8k prompt in half the time, a repeated 1k
  prompt gets nothing.
- Every server stopped within 0.3 s of SIGTERM with status 0; no process and
  no wired memory was left after any session.

## Before and after for the pair: what exists

The pair columns are **not from this night**. They are the earlier single runs
of the same day (cut 4, recording mode, first request of a fresh session, Mac B
rested, 64 outputs at 1k and 4k), shown for scale. The pair is the driver's
clock from its start command to rank 0's first committed token.

| Prompt tok | Metric | Mac A alone (product, warm) | Mac B alone (product, first request / warm sustained) | Pair, cut 4 serial (earlier run) | Pair, cut 4 lookahead (earlier run) | Best pair ÷ faster Mac | Best pair ÷ slower Mac |
|---:|---|---:|---:|---:|---:|---:|---:|
| 1,024 | First content / first token s | 1.025 | 0.375 / 0.392 | 0.52 | not run | 0.72–0.75× as fast | 1.97× |
| 1,024 | Prefill tok/s | 998 | 2,728 / 2,452 | 1,956 | not run | 0.72–0.80× | 1.96× |
| 1,024 | Decode tok/s | 116.1 | 132.9 / 135.9 | 62.8 | not run | 0.46–0.47× | 0.54× |
| 4,096 | First content / first token s | 4.227 | 1.624 / 2.115 | 1.87 | 1.40 | 1.16–1.51× as fast | 3.02× |
| 4,096 | Prefill tok/s | 969 | 2,523 / 1,895 | 2,185 | 2,931 | 1.16–1.55× | 3.02× |
| 4,096 | Decode tok/s | 98.9 | 133.8 / 117.3 | 62.5 | 60.2 | 0.47–0.53× | 0.63× |
| 8,192 | First content / first token s | 8.580 | 3.323 / 4.453 | 3.79 | 2.67 | 1.24–1.67× as fast | 3.21× |
| 8,192 | Prefill tok/s | 954 | 2,464 / 1,833 | 2,160 | 3,069 | 1.25–1.67× | 3.22× |
| 8,192 | Decode tok/s | 88.6 | 119.4 / 99.3 | 61.6 | 61.1 | 0.52–0.62× | 0.70× |
| 8,192 | Total s for 128 output tokens | 10.10 | 4.47 / 5.76 | 5.85 (computed) | 4.75 (computed) | 0.94–1.21× as fast | 2.13× |

On a model that fits either Mac, the pair helps time to first token on long
prompts (1.2-1.7x the faster Mac, 3x the slower) and nothing else: it decodes
at 60-63 tok/s, about half of what either Mac serves alone with speculation,
has no prefix cache and serves one request at a time. An 8k prompt with 128
outputs is a wash against Mac B alone; beyond roughly 80-280 output tokens
Mac B alone finishes first.

The same hardware as two independent providers (output tok/s):

| Load | Mac A | Mac B | Two independent providers | The pair |
|---|---:|---:|---:|---:|
| 1k prompts, 1 client per Mac | 59.8 | 70.8–98.8 | 131–159 | about 50 (one request at a time: 0.52 s + 127/62.8 s per 128 tokens; computed, session start-up not counted) |
| 1k prompts, 4 clients per Mac | 78.0 | 102.6 | 180.6 | no concurrency |
| 1k prompts, 8 clients per Mac (width set to 8) | 83.4 | 117.9 | 201.3 | no concurrency |
| Mixed 64–8k soak, 4 clients per Mac | 30.3 (790 prompt tok/s) | 47.8 (1,249 prompt tok/s) | 78.1 (2,039 prompt tok/s) | not run |

Expected pair prefill by cut, from tonight's single-Mac rates (arithmetic for
32 equal layers and a pipelined prefill, not a measurement):

| Cut | Mac A stage tok/s (a = 960) | Mac B stage tok/s, first request (b = 2,500) | Mac B stage tok/s, sustained (b = 1,850) | Pipeline bound, first request / sustained |
|---:|---:|---:|---:|---:|
| 4 | 7,680 | 2,857 | 2,114 | 2,857 / 2,114 |
| 8 | 3,840 | 3,333 | 2,467 | 3,333 / 2,467 |
| 12 | 2,560 | 4,000 | 2,960 | 2,560 / 2,560 |
| 16 | 1,920 | 5,000 | 3,700 | 1,920 / 1,920 |

Cut 8 is the best cut only while Mac B is at its first-request speed; at its
sustained speed cuts 8 and 12 are within 4% and the bound is about 2,500
tok/s. The sweep that would test this was not run.

## Catalog model matrix

Status of every catalog id on each Mac through `start --local` with product
defaults (64 and 4k prompts, 1 and 4 clients, a 3-minute soak):

| Catalog model | Mac A (M3 Ultra, 256 GB) | Mac B (M5 Max, 128 GB) | Two-Mac cluster |
|---|---|---|---|
| `Qwen3.5-9B` | **passed** (392 requests; the only failures are the 44 refusals at 8 clients against the default width) | **passed** (475 requests; same 44 refusals) | the one model the cluster runtime admits; **pair blocked tonight** (link) |
| `gpt-oss-20b` | **passed** (142 requests, 0 failed) | **passed** (160, 0) | not supported by the cluster runtime yet |
| `ternary-bonsai-2-27b` | **passed** (53, 0) — slowest in the catalog | **passed** (59, 0) | not supported by the cluster runtime yet |
| `qwen3.6-35b-a3b-vl-mtp-mxfp8` | **passed** (132, 0) | **passed** (150, 0) | not supported by the cluster runtime yet |
| `EigenLabs/Qwen3.8-27B-4bit-mtp` | **unsupported**: the provider's catalog view says "requires: Apple M5, NAX runtime — not eligible on this machine (missing: apple_m5, mlx_nax)"; not fetched here (also stopped by the disk floor) | **passed** (67, 0); fetched on Mac B with the product downloader, 14/14 files verified | not supported by the cluster runtime yet |
| `gemma-4-26b` | **passed** (132, 0) | **passed** (138, 0) | not supported by the cluster runtime yet |
| `gemma-4-26b-8bit` | **passed** (132, 0) — the same artifact as `gemma-4-26b` under its second id | **untested** under this id (the identical artifact passed as `gemma-4-26b`) | not supported by the cluster runtime yet |
| `gemma-4-26b-qat-4bit` | **passed** (142, 0), without its MTP assistant (see notes) | **passed** (170, 0), same | not supported by the cluster runtime yet |
| `qwen3.5-35b-a3b` | **passed** (132, 0) | **passed** (162, 0) | not supported by the cluster runtime yet |
| `nvidia-nemotron-3.5-lightning` | **failed** with product defaults: the model loads, then every request returns HTTP 200 + SSE error "Response generation failed" (6 of 6 in a five-shape diagnostic, plus the first run); rerun with MTP off still queued for the lane when this was written | **failed** the same way with product defaults (every request); **passes with `mtp_mode = "off"`** (163 requests, 0 failed) | not supported by the cluster runtime yet |
| `mimo-v2.6-flash-mopd` | **blocked**: artifact verified (53/53, 172.9 GB) and listed by the provider, but the provider would not load it: ready in 32.5 s without the model, then HTTP 503 "Provider capacity is temporarily unavailable." for every request | **unsupported**: 172.9 GB of weights, minimum RAM 256 GB, Mac B has 128 GB | not supported by the cluster runtime yet — and the model that most needs it |

| Model | Mac | Ready s | Footprint GiB loaded / peak seen | 64-tok prompt: first token s, decode tok/s | 4k prompt: first token s, prefill tok/s, decode tok/s | 4 clients: output tok/s at 64 / 4k | Soak ok/all, output tok/s | Requests failed | Stop s, left over | Session failures |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---|
| `gpt-oss-20b` | A | 8.0 | 12.0 / 14.0 | 0.082, 134.6 | 2.13, 1,922, 119.7 | 225.1 / 45.0 | 107/107, 75.3 | 0 | 0.18, 0 | none |
| `gpt-oss-20b` | B | 6.5 | 12.0 / 14.0 | 0.051, 139.0 | 1.14, 3,600, 113.3 | 221.3 / 63.2 | 125/125, 88.0 | 0 | 0.14, 0 | none |
| `ternary-bonsai-2-27b` | A | 10.0 | 8.2 / 14.0 | 0.393, 43.1 | 14.78, 277, 41.0 | 39.3 / 7.1 | 18/18, 11.9 | 0 | 0.18, 0 | none |
| `ternary-bonsai-2-27b` | B | 8.0 | 8.1 / 12.0 | 0.219, 45.6 | 8.48, 483, 42.4 | 58.3 / 11.2 | 24/24, 15.9 | 0 | 0.15, 0 | none |
| `qwen3.6-35b-a3b-vl-mtp-mxfp8` | A | 9.0 | 20.0 / — | 0.078, 75.9 | 1.95, 2,098, 72.7 | 185.9 / 42.4 | 97/97, 67.6 | 0 | 0.25, 0 | none |
| `qwen3.6-35b-a3b-vl-mtp-mxfp8` | B | 7.3 | 20.0 / 22.0 | 0.073, 105.1 | 1.21, 3,385, 97.7 | 201.7 / 54.5 | 115/115, 80.3 | 0 | 0.15, 0 | none |
| `EigenLabs/Qwen3.8-27B-4bit-mtp` | B | 6.8 | 17.0 / 20.0 | 0.254, 40.0 | 6.92, 592, 41.7 | 57.4 / 13.4 | 32/32, 18.8 | 0 | 0.15, 0 | none |
| `gemma-4-26b` | A | 2.3 | — / — | 0.094, 82.0 | 1.97, 2,083, 71.2 | 199.5 / 41.9 | 97/97, 67.5 | 0 | 0.26, 0 | none |
| `gemma-4-26b` | B | 1.8 | 26.0 / 29.0 | 0.107, 84.3 | 1.32, 3,104, 72.4 | 161.6 / 50.3 | 103/103, 72.0 | 0 | 0.21, 0 | none |
| `gemma-4-26b-8bit` | A | 2.6 | — / — | 0.093, 81.9 | 1.96, 2,088, 72.3 | 200.5 / 42.2 | 97/97, 67.9 | 0 | 0.25, 0 | none |
| `gemma-4-26b-qat-4bit` | A | 8.0 | 15.0 / 18.0 | 0.089, 99.8 | 1.89, 2,170, 84.3 | 220.7 / 45.1 | 107/107, 74.6 | 0 | 0.19, 0 | none |
| `gemma-4-26b-qat-4bit` | B | 6.5 | 15.0 / 17.0 | 0.066, 129.0 | 0.90, 4,531, 100.4 | 240.9 / 65.2 | 135/135, 95.5 | 0 | 0.15, 0 | none |
| `qwen3.5-35b-a3b` | A | 10.0 | 20.0 / 24.0 | 0.079, 113.3 | 1.95, 2,096, 118.9 | 187.9 / 41.5 | 97/97, 68.1 | 0 | 0.19, 0 | none |
| `qwen3.5-35b-a3b` | B | 7.3 | 20.0 / 24.0 | 0.066, 154.4 | 0.96, 4,269, 146.0 | 233.7 / 62.8 | 127/127, 89.1 | 0 | 0.15, 0 | none |
| `nvidia-nemotron-3.5-lightning (MTP off, not the default)` | B | 6.5 | 17.0 / 21.0 | 0.093, 133.7 | 1.07, 3,831, 128.0 | 232.2 / 63.4 | 128/128, 89.5 | 0 | 0.15, 0 | none |

- `nvidia-nemotron-3.5-lightning` loads and then fails every request while
  the default `mtp_mode = "auto"` activates its inline head; with
  `mtp_mode = "off"` it serves normally. The reason is not visible to an
  operator: the HTTP error is generic and the provider's log line is private.
- `mimo-v2.6-flash-mopd` was verified on Mac A (53 of 53 files) and listed by
  the provider at 176.4 GB, but the provider answered every request with HTTP
  503 and did not load it, with about 207 GiB reclaimable and no memory
  pressure.
- `gemma-4-26b-qat-4bit` ran without its MTP assistant because the benchmark
  keeps the provider offline and the assistant is fetched from the coordinator.
- The cluster runtime's own load gate requires 6 GiB of free pages and refused
  a 5 GB stage while 208 GiB sat in reclaimable file cache.

## Limits

- No two-Mac measurement of any kind; no test of the cut prediction, of
  swapped roles, of a pair soak or of collective latency.
- Client-clock rates only; five to ten samples per single-request cell.
- Stage-6 runs on Mac A overlapped model downloads for the first three models.
- One provider build, one branch; the Nemotron and MiMo results are for this
  build and were not compared with a released provider.
