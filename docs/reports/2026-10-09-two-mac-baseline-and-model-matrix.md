# Two-Mac baseline, load generator and catalog model matrix

> Last updated: 2026-10-09

One night of measurement on the two Macs used for the cluster work: "Mac A"
(M3 Ultra, 256 GB, macOS 27.2) and "Mac B" (M5 Max, 128 GB, macOS 27.0),
provider 0.9.19 built in release configuration from `f93e4cf7f`
(`kimi/cluster-foundation-20261007`). It records the single-Mac "before" for
the two-Mac cluster through the product's own serving path, the state of every
catalog model on each Mac, two investigations (a model that answered nothing,
a model that would not load), and the tooling added. It does **not** contain a
two-Mac "after": the Thunderbolt port on Mac B had lost its address and no
pair run could be made that night.

Every time is on the client's monotonic clock on the serving Mac over
loopback, from just before the request is written; token counts are the
server's `usage`. "Prefill tok/s" is prompt tokens over time to first token;
"decode tok/s" is (output tokens − 1) over the time between the first and last
streamed token. Greedy sampling, thinking disabled, 128 output tokens, each
prompt unique unless a row says "cached".

## A local build is not the product unless it is staged like the product

The first round of single-Mac measurements (stages 3 and 6, 05:28–09:45 UTC)
was **not on the product's normal path**. The provider had been built with a
plain `swift build -c release` and run beside its SwiftPM bundles. On this
toolchain that build writes resource bundles as `X.bundle/Contents/Resources/…`;
the runtime looks only for the flat `X.bundle/pagedattention.metal`. The paged
KV backend's kernel preflight therefore failed and every model **silently fell
back from `paged` to `contiguous`** (no log line an operator can read, no
reason in `/metrics`). The fleet runs paged (1,449 of 1,478 loaded models by
the public counters). It also made Nemotron fail every request (see
Investigation A).

The same binary (`5ed1f67c…`), staged in the product's app layout, selects
`paged`. Everything was then re-measured in the coordinator's order of
priority; those tables are marked "corrected" and each old table is headed by
a line saying it is superseded. **Use only the corrected tables for the
"before".** The first-round tables are kept because they are valid
measurements of the contiguous backend.

Local build that matches the fleet's backend (verified on both Macs): keep
`swift build -c release --product darkbloom` and `scripts/fetch-metallib.sh`,
then stage `Darkbloom.app/Contents/MacOS/{darkbloom,mlx.metallib}`, each
SwiftPM bundle flattened (`X.bundle/Contents/Resources/*` → `X.bundle/*`) under
`Darkbloom.app/Contents/Resources/`, and
`Contents/Resources/darkbloom-runtime-capabilities/paged-kernel-v1` containing
`1`; then check `kv_backend_info{…backend="paged"}` in `/metrics`. The release
tooling's `swift build --build-system native` should give the flat bundles
directly (not verified tonight).

## Tooling added

`scripts/benchmarks/cluster/` (standard library only, Python 3.9+):
`loadgen.py` with `test_loadgen.py` (fixed-shape streamed load, per-request
records, percentiles, soak; self-test against a stub server); `serve_bench.py`
and `remote_bench.sh` (isolated `darkbloom start --local`, readiness on
`/health`, graceful stop, memory and leftover checks, backend and MTP state at
load, optional memory-pressure guard; the same on a second Mac over SSH);
`fetch_catalog_model.sh` and `verify_artifact.py` (product downloader under a
disk floor; manifest check file by file); `pair_sweep.py` (cut, schedule and
prompt sweep for the pair driver — **written, never run against a pair**);
`with_lane.sh`, `redact.py`, `tables.py`.

Isolation for anyone repeating this: `-c` moves only the configuration file.
`start --local` derives every other path from the Foundation home directory,
so the harness sets `CFFIXED_USER_HOME` (`HOME` alone does not redirect it),
the per-file state variables and an ephemeral prefix-cache root; `darkbloom
stop` has no `-c` and is never used.

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

## Qwen3.5 9B on each Mac alone, product path, paged backend

Headline, one request at a time, 128 output tokens (Mac A: p50 of ten warm
requests; Mac B: a fresh server after 180 s with nothing running, seven
requests back to back, "first" is request 1 and "settled" the median of
requests 4–7):

| Prompt tok | Mac A first content s | Mac A prefill tok/s | Mac A decode tok/s | Mac B first content s, first request / settled | Mac B prefill tok/s, first / settled | Mac B decode tok/s, first / settled |
|---:|---:|---:|---:|---:|---:|---:|
| 1,023 | 1.029 | 993 | 98.5 | 0.373 / 0.378 | 2,742 / 2,704 | 130.6 / 120.8 |
| 4,097 | 4.250 | 964 | 87.6 | 1.472 / 1.798 | 2,783 / 2,279 | 119.6 / 111.3 |
| 8,186 | 8.590 | 952 | 77.9 | 2.974 / 3.784 | 2,752 / 2,163 | 101.1 / 97.8 |

Mac B, the seven requests in order (180 s idle and a server restart before
each shape; power mode automatic, on AC; nothing was changed):

| Prompt tok | Time to first token by request, in order (s) | Decode tok/s by request, in order |
|---:|---|---|
| 1,024 | 0.37, 0.36, 0.36, 0.36, 0.37, 0.38, 0.39 | 131, 128, 130, 119, 126, 121, 121 |
| 4,096 | 1.47, 1.45, 1.60, 1.78, 1.78, 1.82, 1.84 | 120, 120, 105, 111, 114, 112, 99 |
| 8,192 | 2.97, 3.31, 3.55, 3.69, 3.77, 3.80, 3.85 | 101, 102, 95, 97, 98, 100, 93 |

Mac B slows under sustained load on the paged backend exactly as it did on
contiguous and as another worker measured: an 8k prompt goes from 2.97 s to
3.85 s to first token within seven requests, and without the rest the next
shape starts slow. **Quote Mac B as "first request" and "settled", never as
one number.**

MTP on against MTP off (`mtp_mode = "off"`, a non-default configuration), same
backend, p50:

| Mac | Prompt tok | MTP on (default): prefill, decode tok/s | MTP off: prefill, decode tok/s |
|---|---:|---:|---:|
| A | 1,024 | 993, 98.5 | 1,115, 104.8 |
| A | 4,096 | 964, 87.6 | 1,085, 103.2 |
| A | 8,192 | 952, 77.9 | 1,069, 100.8 |
| B | 1,024 | 2,502, 126.1 | 1,714, 86.9 |
| B | 4,096 | 1,866, 98.3 | 1,870, 90.2 |
| B | 8,192 | 1,947, 99.6 | 1,905, 88.8 |

Concurrency (closed loop):

| Clients at about 1k prompt tokens | Mac A output tok/s (ok/all) | Mac B output tok/s (ok/all) | Two independent providers |
|---|---:|---:|---:|
| 1 | 58.7 (8/8) | 76.7 (8/8) | 135.4 |
| 2 | 65.6 (16/16) | 85.6 (16/16) | 151.2 |
| 4 | 77.6 (32/32) | 106.6 (32/32) | 184.2 |
| 8, default width 4 | 76.8 (4/48) | 103.7 (4/48) | — |
| 8, width set to 8 | 83.3 (48/48) | 120.6 (48/48) | 204.0 |

Mac A soak (10 min, 4 clients, mixed sizes): 136/136 ok, 28.3 output and 743 prompt tok/s.
Mac B soak (10 min, 4 clients, mixed sizes): 210/210 ok, 44.4 output and 1,158 prompt tok/s.

## Before and after for the pair: what exists

**There is still no "after" from this night** (stage 4 blocked). "Before" is
now the corrected paged-backend baseline; the pair columns are the earlier
single runs of 2026-10-09 03:27–04:02 UTC by another worker (cut 4, recording
mode, first request of a fresh session, Mac B rested, 64 outputs at 1k and 4k),
shown for scale only. Clocks as before: client clock over loopback for the
product; the driver's clock to rank 0's first committed token for the pair.

| Prompt tok | Metric | Mac A alone (product, paged, warm) | Mac B alone (product, paged): first request / settled | Pair cut 4 serial (earlier run) | Pair cut 4 lookahead (earlier run) | Best pair ÷ Mac B (first / settled) | Best pair ÷ Mac A |
|---:|---|---:|---:|---:|---:|---:|---:|
| 1,024 | Time to first token s | 1.029 | 0.373 / 0.378 | 0.52 | not run | 0.72× / 0.73× as fast | 1.98× |
| 1,024 | Decode tok/s | 98.5 | 130.6 / 120.8 | 62.8 | not run | 0.48× / 0.52× | 0.64× |
| 1,024 | Total s, 128 outputs | 2.29 | 1.35 / 1.43 | — | 2.54 (computed) | 0.53× / 0.56× as fast | 0.90× |
| 4,096 | Time to first token s | 4.250 | 1.472 / 1.798 | 1.87 | 1.40 | 1.05× / 1.28× as fast | 3.04× |
| 4,096 | Decode tok/s | 87.6 | 119.6 / 111.3 | 62.5 | 60.2 | 0.52× / 0.56× | 0.71× |
| 4,096 | Total s, 128 outputs | 5.77 | 2.64 / 3.02 | — | 3.51 (computed) | 0.75× / 0.86× as fast | 1.65× |
| 8,192 | Time to first token s | 8.590 | 2.974 / 3.784 | 3.79 | 2.67 | 1.11× / 1.42× as fast | 3.22× |
| 8,192 | Decode tok/s | 77.9 | 101.1 / 97.8 | 61.6 | 61.1 | 0.61× / 0.63× | 0.79× |
| 8,192 | Total s, 128 outputs | 10.32 | 4.33 / 5.15 | — | 4.75 (computed) | 0.91× / 1.09× as fast | 2.17× |

Where two Macs help and where they do not. On this model the pair helps one
thing: time to first token on long prompts, and only against a Mac B that has
been working. Against Mac B's first request the earlier lookahead figures are
about level (4k: 1.40 s against 1.47 s; 8k: 2.67 s against 2.97 s); against a
settled Mac B they are 1.3–1.4 times as fast; against Mac A three times. At
1k the pair is slower than Mac B alone. Decode on the pair (60–63 tok/s) is
0.5–0.8 of what each Mac serves alone (78–131), and that gap is the engine,
not speculation. Whole requests of 128 outputs are a wash or a loss
against Mac B alone, and the pair has no prefix cache, no batching and no
concurrency. For "it should absolutely be faster": **only prefill on long
prompts is, by up to about 1.4× over the faster Mac once that Mac is warm;
everything else about this model is slower or equal on the pair today.**

The alternative use of the same hardware, two independent providers, from the
corrected concurrency table above: about 184 output tok/s at four clients per Mac,
against roughly 50 for one pair serving one request at a time (computed from
the earlier pair run: 0.52 s + 127/62.8 s per 128 tokens).

Expected pair prefill by cut from single-Mac rates (arithmetic for 32 equal
layers and a pipelined prefill: the slower of 32·a/c and 32·b/(32−c), with
Mac A at a = 960 tok/s and Mac B at b = 2,750 on a first request or about
2,200 settled), first request / settled: cut 4, 3,143 / 2,514; cut 8,
3,667 / 2,933; cut 10, 3,072 / 3,072; cut 12, 2,560 / 2,560; cut 16,
1,920 / 1,920. The predicted best cut is 8 with a rested Mac B and between 8
and 10 once it has settled. The sweep that would test this was not run.

## Catalog model matrix

Status through `start --local` with product defaults (64 and 4k prompts, 1 and
4 clients, a 3-minute soak). "Paged" rows are on the product's backend;
models not re-run after the layout correction have only a contiguous-fallback
row.

| Catalog model | Mac A (M3 Ultra, 256 GB) | Mac B (M5 Max, 128 GB) | Two-Mac cluster |
|---|---|---|---|
| `Qwen3.5-9B` | passed | passed | the one model the cluster runtime admits; pair blocked that night |
| `gpt-oss-20b` | passed | passed | not supported by the cluster runtime yet |
| `ternary-bonsai-2-27b` | passed (slowest prefill in the catalog) | passed | not supported yet |
| `qwen3.6-35b-a3b-vl-mtp-mxfp8` | passed | passed | not supported yet |
| `EigenLabs/Qwen3.8-27B-4bit-mtp` | unsupported (requires `apple_m5`, `mlx_nax`) | passed | not supported by the product path yet |
| `gemma-4-26b` / `gemma-4-26b-8bit` (one artifact) | passed under both ids | passed as `gemma-4-26b` | not supported yet |
| `gemma-4-26b-qat-4bit` | passed, without its MTP assistant (offline) | passed, same | not supported yet |
| `qwen3.5-35b-a3b` | passed | passed | not supported yet |
| `nvidia-nemotron-3.5-lightning` | passed once the install was corrected (see below) | passed with default MTP on paged | not supported yet |
| `mimo-v2.6-flash-mopd` | blocked: refused by the load gate with other work resident | unsupported (172.9 GB of weights, 128 GB of RAM) | not supported yet |

Corrected runs (paged backend):

Re-run of the paged-listed models with the app-layout install, in the
coordinator's order (Qwen3.8 27B on Mac B, Nemotron with default MTP, then the
rest as lanes allowed). `gemma-4-26b` / `gemma-4-26b-8bit` select contiguous
by policy and were not re-run; their first-round rows stand. A model missing
from this table had not been re-run when the night ended; its first-round row
below is then a contiguous-fallback figure.

| Model | Mac | Ready s | Footprint GiB loaded / peak seen | 64-tok prompt: first token s, decode tok/s | 4k prompt: first token s, prefill tok/s, decode tok/s | 4 clients: output tok/s at 64 / 4k | Soak ok/all, output tok/s | Requests failed | Stop s, left over | Session failures |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---|
| `gpt-oss-20b` | B | 6.8 | 12.0 / 14.0 | 0.075, 111.9 | 1.42, 2,886, 108.4 | 184.5 / 52.6 | 105/105, 73.7 | 0 | 0.15, 0 | none |
| `ternary-bonsai-2-27b` | B | 8.6 | 10.0 / 12.0 | 0.340, 34.2 | 9.17, 447, 34.2 | 52.4 / 10.2 | 25/25, 16.7 | 0 | 0.14, 0 | none |
| `qwen3.6-35b-a3b-vl-mtp-mxfp8` | B | 7.5 | 21.0 / 21.0 | 0.071, 102.1 | 1.11, 3,702, 110.8 | 202.4 / 56.2 | 117/117, 81.7 | 0 | 0.15, 0 | none |
| `EigenLabs/Qwen3.8-27B-4bit-mtp` | B | 6.8 | 18.0 / 21.0 | 0.193, 38.6 | 7.09, 578, 37.3 | 58.1 / 13.5 | 30/30, 18.5 | 0 | 0.15, 0 | none |
| `gemma-4-26b-qat-4bit` | B | 6.8 | 15.0 / 19.0 | 0.101, 105.5 | 1.11, 3,693, 103.6 | 208.6 / 57.0 | 119/119, 82.8 | 0 | 0.15, 0 | none |
| `qwen3.5-35b-a3b` | B | 7.8 | 20.0 / 24.0 | 0.068, 122.3 | 1.11, 3,692, 133.0 | 207.0 / 55.7 | 110/110, 77.1 | 0 | 0.20, 0 | none |
| `nvidia-nemotron-3.5-lightning` | A | 219.8 | — / — | 0.094, 107.8 | 2.03, 2,022, 71.5 | 199.0 / 42.9 | 103/103, 72.4 | 0 | 0.20, 0 | none |
| `nvidia-nemotron-3.5-lightning` | B | 6.5 | 18.0 / 19.0 | 0.130, 77.1 | 1.39, 2,958, 54.2 | 186.1 / 52.1 | 113/113, 79.1 | 0 | 0.15, 0 | none |



| Model | Mac | Backend at load | MTP active | Prefix cache | Lanes held | Load average at start |
|---|---|---|---|---|---|---|
| `nvidia-nemotron-3.5-lightning` | A | paged | 1 | ready | lane.sh+lane-build.sh | 10.8 |
| `EigenLabs/Qwen3.8-27B-4bit-mtp` | B | paged | 1 | ready | lane-b.sh | 2.1 |
| `gemma-4-26b-qat-4bit` | B | paged | 0 | ready | lane-b.sh | 2.8 |
| `gpt-oss-20b` | B | paged | 0 | ready | lane-b.sh | 3.1 |
| `nvidia-nemotron-3.5-lightning` | B | paged | 1 | ready | lane-b.sh | 2.8 |
| `qwen3.5-35b-a3b` | B | paged | 1 | ready | lane-b.sh | 3.0 |
| `qwen3.6-35b-a3b-vl-mtp-mxfp8` | B | paged | 1 | ready | lane-b.sh | 2.6 |
| `ternary-bonsai-2-27b` | B | paged | 0 | ready | lane-b.sh | 3.5 |

- **`nvidia-nemotron-3.5-lightning` passes with default MTP on the paged
  backend on both Macs** (every request; `mtp_active 1`, rounds counted). The
  first-round "failed" was the install fault (Investigation A).
- `mimo-v2.6-flash-mopd` was never loaded: the provider's `doctor` said it
  did not fit at each of three gated attempts (Investigation B).
- Nemotron with default MTP is much slower than with MTP off on Mac B:
  decode 54–77 tok/s against 128–134, prefill 2,958 against 3,831 tok/s at 4k
  (the MTP-off figures are from the first round on contiguous, so backend and
  MTP both differ; worth a clean A/B).
- On Mac A only Nemotron (and Qwen3.5 9B, stage 3) were re-run on paged
  before the night ended; the other Mac A models have first-round rows only.
- Mac B's paged rows show 13–20% lower 4k prefill than its first-round
  contiguous rows for the same models (for example `qwen3.5-35b-a3b` 3,692
  against 4,269 tok/s). The second round ran back to back for over an hour on
  a Mac that slows under sustained load, so backend and thermal state are
  confounded; a rested A/B of the two backends was not done.
- `EigenLabs/Qwen3.8-27B-4bit-mtp` on Mac B, paged, MTP active: 578 prefill
  tok/s at 4k (7.1 s to first token), 37–39 decode tok/s, 58 output tok/s at
  four clients with short prompts.

First-round runs (contiguous fallback; for the models above without a
corrected row, and as a record of that backend):

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
| `nvidia-nemotron-3.5-lightning` | B | 6.5 | 18.0 / 18.0 | —, — | —, —, — | — / — | —/—, — | 0 | 0.15, 0 | run cold-p64 exited RuntimeError: calibration probe failed: sse error: {"code": "server_error", "message": "Response generation failed", "type": "server_error"}; run warm-c1 exited RuntimeError: calibration probe failed: sse error: {"code": "server_error", "message": "Response generation failed", "type": "server_error"}; run warm-c4 exited RuntimeError: calibration probe failed: sse error: {"code": "server_error", "message": "Response generation failed", "type": "server_error"}; run soak-mixed-c4 exited RuntimeError: calibration probe failed: sse error: {"code": "server_error", "message": "Response generation failed", "type": "server_error"} |
| `nvidia-nemotron-3.5-lightning (MTP off, not the default)` | A | 218.5 | — / — | 0.098, 94.3 | 2.03, 2,022, 93.6 | 222.6 / 45.4 | 107/107, 75.2 | 0 | 0.18, 0 | none |
| `nvidia-nemotron-3.5-lightning (MTP off, not the default)` | B | 6.5 | 17.0 / 21.0 | 0.093, 133.7 | 1.07, 3,831, 128.0 | 232.2 / 63.4 | 128/128, 89.5 | 0 | 0.15, 0 | none |

## Investigation: a model that answered nothing

**Cause: the benchmark's locally built install, not the model, the chip, the
weights revision or the coordinator. The same defect silently moved every
model in the first round of measurements from the paged KV backend to the
contiguous fallback.** Real providers (the release bundle) are not expected
to be affected.

Measured:

| What | Result | Where |
|---|---|---|
| Raw error behind "Response generation failed" (temporary diagnostic build: two `stderr` prints, never committed, source tree restored afterwards; binary `46aa8559…`) | `MultiModelBatchSchedulerEngineError.generationFailed("backendIneligible(reason: \"PagedKVPool: paged-attention runtime resource unavailable: missing SwiftPM resource pagedattention.metal; searched <exe dir>, <exe dir>/../Resources, <exe dir>/.., …")` | `investigation/nemotron/diag3-macB/diag3.server.log` |
| KV backend decision at load, same build, Nemotron and Qwen3.5 9B | `selection auto resolved paged`, then `kernel_preflight: paged kernel preflight child exited 1: Error: Required Qwen4 Metal resource is missing or empty: gemm…` → falls back to contiguous | same, and `investigation/kv-backend/diag3-macB/` |
| Where the resource actually was | `mlx-swift-lm_MLXLMCommon.bundle/Contents/Resources/pagedattention.metal` (and `…/Qwen4Metal/gemm.metal`): the nested layout that `swift build` produces on this toolchain (Swift 6.4, the "swiftbuild" build system) | `ls` of the staged bundle |
| Same binaries staged in the product's app layout (`Darkbloom.app/Contents/MacOS/darkbloom`, flat bundles under `Contents/Resources`, `darkbloom-runtime-capabilities/paged-kernel-v1`) | `/metrics`: `backend="paged"`; no fallback line; **Nemotron generates with default MTP** (`mtp_active 1`, 4 MTP rounds, 0 errors, 2 of 2 requests); Qwen3.5 9B the same | `investigation/nemotron/diag4-app-layout-macB/`, `investigation/kv-backend/diag4-app-layout-macB/` |
| With `mtp_mode = "off"` on the broken layout | Works (contiguous backend, no per-request pool) | `stage6/mac*/nvidia-nemotron-3.5-lightning/mtp-off/` |
| Smallest failing request | 64-token prompt, 1 output token, fails in under a second before any token | `stage6/macA/…/diagnostic/` |
| Production, public read-only endpoints (no credentials) at 09:50 UTC | coordinator build `8277409d` of 2026-10-08, provider version 0.9.19, 1,176 providers; of 1,478 loaded models 1,449 are on `paged` and 29 on `contiguous`; no endpoint shows per-model MTP state | `investigation/nemotron/public-*.json` |

Read in the source at `f93e4cf7f` (submodule pins identical on current master;
nothing on master after the branch's merge-base touches Nemotron or MTP):

- The resource locator (`PagedAttentionResources.swift` in the
  `mlx-swift-lm` submodule) accepts only `<root>/pagedattention.metal` and
  `<root>/*.bundle/pagedattention.metal`; the Qwen4 Metal loader makes the same
  flat assumption. The release tooling builds with `--build-system native`
  (`scripts/provider-release-swift.sh`), which writes flat bundles, and
  `scripts/stage-swiftpm-resource-bundles.sh` stages them under the app's
  `Contents/Resources`.
- With `engine_v2_kv_backend = "auto"`, a failed paged kernel preflight
  degrades to contiguous and the reason goes only to telemetry (a no-op sink
  in `--local`); `/metrics` prints the backend name without the reason.
- Nemotron's inline MTP head (`NemotronH35MTP.swift`) builds its own paged KV
  pool for every request; MiMo's native path builds one too. No Qwen or Gemma
  drafter does. The engine keeps the MTP driver active on the contiguous
  fallback, so the first prefill step throws `backendIneligible`, which the
  HTTP layer reduces to the fixed text. The raw error is logged nowhere.
- `revision=inline-c75cadc4-97251709 source_revision=none` is normal for an
  inline head (hashes of `config.json` and the tensor index); nothing for this
  model comes from the coordinator; no revision-keyed table exists for MTP.

Inferred: that released providers are unaffected (they are built with the
native build system and installed in the app layout, and the fleet's public
counters show paged as the norm; I did not run a released binary). Not done:
a bisect (not needed: it is a build-layout fault, the code is the same on
master) and a debug-versus-release comparison (the layout, not the
optimization level, decides it).

**Recipe for a local build that matches the fleet's backend.** Either build
with the release tooling's build system, `swift build --build-system native
-c release --product darkbloom` (not verified on this toolchain tonight), or
keep the default build and stage it the way the product is installed
(verified tonight on both Macs):

```
Darkbloom.app/Contents/MacOS/darkbloom
Darkbloom.app/Contents/MacOS/mlx.metallib            # scripts/fetch-metallib.sh
Darkbloom.app/Contents/Resources/<each SwiftPM bundle, flattened:
    X.bundle/Contents/Resources/*  ->  X.bundle/* >
Darkbloom.app/Contents/Resources/darkbloom-runtime-capabilities/paged-kernel-v1   # contains "1"
```

and check `kv_backend_info{…backend="paged"}` in `/metrics` after the first
load. A bare `swift build` followed by running the binary from the build
directory, which is what the developer build page describes, gives a provider
that runs every paged-listed model on contiguous without saying so.

Product changes proposed (none made; for a decision):

1. **Say why paged fell back.** When `auto` degrades to contiguous, write the
   reason (`kernel_preflight: …`, `native_kv_probe: …`, `crash_loop_guard`,
   `model_capability`) to stderr at start-up and add it as a label on
   `kv_backend_info` (for example `fallback_reason="kernel_preflight"`).
2. **Do not activate an MTP head that needs a pool that cannot be built.**
   If the paged-attention resource is unavailable, Nemotron's (and MiMo's)
   head should come up inactive with `mtp_inactive_reason="paged_resource_unavailable"`
   and serve plain decode, or the load should be refused with that reason —
   not load and then fail every request.
3. **Log the engine's error for a failed request** somewhere a local operator
   can read (stderr, model id and the engine's own description); the HTTP
   body can stay generic.
4. **Make the locator accept the nested bundle layout**
   (`X.bundle/Contents/Resources/…`) that the current toolchain's default
   build system writes, or make `make provider-build` and the developer build
   page use `--build-system native`; today the documented local build is not
   the product.
5. The same missing-resource signature is the likely cause of the local
   provider test failures recorded in the evidence ledger
   (`pagedattention.metal` missing on this toolchain).

## Investigation: a model that would not load

**Cause: the load gate needs at most 47.5 GiB of the Mac in use by everything
else at the moment of admission, and Mac A had about 47–50 GiB in use. It
missed by roughly 0.5–2.5 GiB. A 256 GB Mac can serve this model; this one,
tonight, with other work resident, could not.**

Measured:

| What | Value | Where |
|---|---|---|
| Server ready without the model | 32.5 s (28 s of it hashing weights, hash = catalog aggregate) | `stage6/macA/mimo-v2.6-flash-mopd/` |
| Every request | HTTP 503, `{"error":{"type":"invalid_request_error","message":"Provider capacity is temporarily unavailable."}}` | same |
| Memory at the attempt (`vm_stat`) | free 0–9 GiB, inactive 197–208 GiB, active 38–39, wired 8, compressor 1; pressure normal, swap 0 | `memory-precheck.txt`, journal |
| Wired memory during the attempt | 7.9 → 8.2 GiB (nothing was materialised) | session file |
| The product's own verdict, an hour later, from `darkbloom doctor` | `[FAIL] model fits in RAM — mimo-v2.6-flash-mopd needs ~182.9 GB but only 163.4 GB is usable now (19.4 GB short for preload)` | `investigation/mimo/doctor-macA.txt` |
| `doctor` again inside a two-lane hold at 10:10 UTC (attempt 2 gate) | `needs ~182.9 GB but only 180.3 GB is usable now (2.6 GB short)` → not started | `investigation/mimo/attempt2/doctor-before.txt` |
| `doctor` again inside a two-lane hold at 11:15 UTC (attempt 3 gate, app-layout install) | `needs ~182.9 GB but only 175.9 GB is usable now (7.0 GB short)` → not started | `investigation/mimo/attempt3-app-layout/doctor-before.txt` |

Read in the source at `f93e4cf7f` (file and line references in the journal):

- Required = the scanner's load estimate + load headroom =
  176.4 + (5.5 activation reserve + 1.0 minimum KV) = **182.9** (the figures
  are GiB although the messages say "GB"). The estimate is the weights
  (161.0 GiB on disk) plus about 15.4 GiB of load transients, including the
  audio sidecar. There is no MiMo-specific minimum-RAM table or activation
  floor.
- Usable = (free + speculative + inactive pages) − load reserve, where the
  load reserve is physical − hard cap = 10% of physical = **25.6 GiB** on this
  Mac (`UnifiedMemoryCap`; `memory_reserve_gb` is not consulted in `--local`).
- So the rule is **free + inactive ≥ 208.5 GiB**, i.e. everything that is
  active, wired or compressed must total **≤ 47.5 GiB**. File-backed active
  pages count against the model.
- The request-time refusal is `ensureMemoryHeadroomForLoad` in
  `StandaloneServer.swift`, which throws "Insufficient memory headroom to load
  model (needs 182.9 GB available)"; that is rewrapped as a token-budget
  capacity failure and sanitized to the fixed 503 text, with `type` hard-coded
  to `invalid_request_error`.
- `min_ram_gb` (256 for this model) is used only for display, the picker and
  the coordinator's static fit check (256 ≤ 256 passes). The live rule adds a
  condition the catalog does not express.

Arithmetic (measured inputs, source formula):

| free + inactive | usable (− 25.6) | required | result |
|---:|---:|---:|---|
| 206 GiB (the attempt, low reading) | 180.4 | 182.9 | short 2.5 GiB |
| 208 GiB (the attempt, high reading) | 182.4 | 182.9 | short 0.5 GiB |
| 189 GiB (when `doctor` ran, another GPU job active) | 163.4 | 182.9 | short 19.4 (doctor's own figure) |
| 240 GiB (an otherwise idle 256 GiB Mac; assumed) | 214.4 | 182.9 | passes by 31.5 GiB |

Inferred, not observed: that the start-up preload failed at the post-hash
ledger recheck rather than at its first check (from the 28-second hash, which
is only reached after the first check passes — the Mac was that close to the
line); that an idle Mac A has about 240 GiB free + inactive; that the post-load
KV probes would pass once it loads.

Answers to the questions asked:

1. *Can a 256 GB Mac serve it under the rules as written?* Yes: required
   182.9 GiB against 230.4 GiB under the cap. But only while everything else
   on the Mac holds no more than 47.5 GiB. The catalog's "minimum RAM 256 GB"
   and the rule do not contradict each other; the catalog figure is simply
   silent about that condition, and a provider that also runs a desktop
   session with a browser and tools will sit near or over it. If the fleet is
   expected to serve MiMo on 256 GB Macs, either the minimum should say "256 GB
   and little else running", or the 10% hard-cap reserve (25.6 GiB here) is the
   number to revisit for large-memory Macs — a decision, not a bug.
2. *What state does Mac A need?* Active + wired + compressed memory of all
   other processes at or below about 45 GiB (47.5 minus a small margin) at the
   moment of loading, which tonight means the other agents' and tools'
   resident memory would have to shrink by 2–20 GiB depending on the moment.
   Nothing was stopped or purged to get there. Two further attempts were
   gated on the provider's own `doctor` verdict inside two-lane holds; both
   times it said the model did not fit (2.6 and 7.0 GB short), so the model
   was never loaded tonight. Note also that once it does load, MiMo's native
   path builds a paged KV pool like Nemotron's, so it needs the app-layout
   install described in Investigation A.
3. *Where would an operator have had to look?* Only at `darkbloom doctor`
   run from a second terminal. The server's stdout says "Startup preload: 0
   model(s) loaded" (and only at exit when piped); the skip/failure line with
   the numbers goes to a `<private>` os_log entry; the request-time refusal is
   logged nowhere; `/metrics`, the state file and `darkbloom status` carry
   nothing about it; the HTTP body is generic and mislabelled
   `invalid_request_error`.
4. *What should it say?* At start-up, on stderr: `mimo-v2.6-flash-mopd was
   not preloaded: it needs 182.9 GiB usable and 180.4 GiB is usable now
   (2.5 GiB short); it will be loaded on the first request if memory allows —
   run "darkbloom doctor" for details`. At request time the same sentence on
   stderr, and a 503 whose body says the model cannot be loaded for lack of
   memory (no figures needed in the body) with `type` `server_error`.

Proposed change (reporting only; not made — for a decision): in
`StandaloneServer.preloadSelectedModels` also write the preloader's existing
`WARN:` lines to stderr and have `runLocalStartupPreload` print the skipped and
failed lists beside the loaded count; in `acquireModel`'s
`capacityUnavailable` catch, write the message to stderr before rethrowing;
in `ensureMemoryHeadroomForLoad` add the measured usable figure to the string.
Admission logic, HTTP status and body stay as they are.

## Other findings

- Requests beyond the engine width are refused, not queued: 44 of 48 at eight
  clients against the default width of 4, as HTTP 200 with an SSE error frame.
- Mac B slows under sustained load; quote it as first request and settled.
- In a mixed soak a 64-token prompt's p95 time to first content was 5–8 s
  against 0.06–0.11 s alone.
- The prefix cache reuses in 4,096-token blocks (first-round measurement).
- The cluster runtime's own load gate requires 6 GiB of free pages and refused
  a 5 GB stage while 208 GiB sat in reclaimable file cache.
- Start-up text is buffered when stdout is a pipe; every clean stop logs two
  error-level lines from the HTTP layer.

## Limits

- No two-Mac measurement of any kind.
- Client-clock rates only; five to ten samples per single-request cell.
- First-round runs on Mac A overlapped model downloads for three models; load
  averages of 6–12 on Mac A during corrected runs (other work on the Mac),
  recorded per session.
- One provider build; the released provider was not run.
