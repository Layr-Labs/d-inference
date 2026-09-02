# Activation floor measurements — full catalog sweep (2026-08-30)

**Goal:** measured B=8 activation peaks (peak-over-resident) on the *current* engine for
every active catalog model, to (a) fill the unmeasured-model gaps in the per-model
activation floor tables proposed by PR #683 (and PR #654), (b) re-baseline the two
July-measured models now that compiled decode is gone (removed in v0.8.0 — the harness
refuses `v2-compiled`), and (c) probe whether the fixed floors actually bound long
contexts (L-scaling).

## Environment

| | |
|---|---|
| Machine | MacBook Pro, Apple M4 Max, 128 GB unified memory |
| OS | macOS 26 (Darwin 25.5.0) |
| Harness | `BenchCBv2` (`libs/mlx-swift-lm`, release build) |
| mlx-swift-lm | `fe01df9f57e8f47e67c130db5488eafb5e27f7ef` (3.31.3-213), clean tree |
| mlx-swift | `1d452d837e205e1c99f7ceffd5d34fff73d9b169` (0.31.4-24), dirty: header includes + CmlxTests additions only — no kernel/allocator changes |
| mlx (C++) | `d3c82db012162f26206caf3864dae8e01274830c` (darkbloom-metal-resource-count-200), clean tree |
| Submodule pointer drift | checked-out revs differ from parent-repo pins (`git submodule status` shows `+`) — recorded here for provenance |
| Local provider binary | v0.8.15 (idle during all runs; no darkbloom process) |
| Measurement convention | per-cell `gpuPeak − gpuActive` on **v2 (contiguous)** cells; the harness resets `MLX.Memory.peakMemory` after engine construction, so each row's peak covers only that cell. Same basis as the July `*-paged-gate-2026-07-09.md` sweep that sized the 5.5 GiB default. Includes the cell's KV growth (~0.5 GB at B=8×~500 tok) — conservative direction. Paged cells are supplementary only (their pool is allocated before the reset, so peak-over-active means something different). |

## Live catalog (fetched 2026-08-30 from api.darkbloom.dev/v1/models/catalog, read-only)

| catalog id | min_ram_gb | size_gb | quant | ctx | measured floor status (pre-sweep) |
|---|---|---|---|---|---|
| gpt-oss-20b | 24 | 12.1 | fp8 | 131072 | measured (July): 2.56 eager / 3.20 compiled → #683 floor 3.5 |
| qwen3.6-35b-a3b-vl-mtp-mxfp8 | 32 | 21.3 | fp4 | 262144 | **unmeasured** → flat 5.5 (the 32 GB tier blocker from #654's thread) |
| qwen3-vl-30b-a3b-instruct | 32 | 18.3 | fp4 | 131072 | **unmeasured** → flat 5.5 |
| gemma-4-26b | 36 | 28.0 | 8bit | 131072 | default's basis model (July, qat-4bit artifact): 5.05 eager / 5.34 compiled |
| gemma-4-26b-qat-4bit | 36 | 15.6 | 4bit | 131072 | as above (the July artifact) |
| qwen3.5-35b-a3b | 36 | 20.9 | fp4 | 262144 | **unmeasured** → flat 5.5 |
| gemma-4-26b-8bit | 64 | 28.0 | 8bit | 131072 | **unmeasured** (assumed covered by default) |

Catalog-id findings for the PR review:

- `gpt-oss-20b` is the exact live catalog id — PR #683's exact-match table keys are correct.
- The provider release train is at **v0.8.15** (this machine's binary). PR #683's
  `servabilityPerModelFloorMinVersion = "0.8.11"` placeholder is stale by 4+ releases and
  must be bumped to the release that actually ships the provider half.

## Artifact mapping (measured vs served)

| catalog id | benched artifact | fidelity |
|---|---|---|
| gpt-oss-20b | mlx-community/gpt-oss-20b-MXFP4-Q8 @ 773a7da7 | same artifact as the July sweep (direct re-baseline) |
| qwen3.6-35b-a3b-vl-mtp-mxfp8 | EigenLabs/Qwen3.6-35B-A3B-MLX-VL-4bit-g64-router8 @ **73a03825** (re-downloaded; 19.82 GiB weights) | **the served artifact**: hub rev matches the catalog's `hub_revision` exactly, and the measured artifactContract (`target=affine-w4-g64; mtp=mxfp8-g32`) shows the catalog id's "mxfp8" names the inline-MTP head quant over 4bit-g64 target weights |
| qwen3-vl-30b-a3b-instruct | lmstudio-community/Qwen3-VL-30B-A3B-Instruct-MLX-4bit (17 GiB) | **proxy** (quant variant) |
| qwen3.5-35b-a3b | EigenLabs/Qwen3.5-35B-A3B-MLX-VL-4bit-g64 (19 GiB) | **proxy** (quant variant) |
| gemma-4-26b-8bit / gemma-4-26b | mlx-community/gemma-4-26b-a4b-it-8bit @ 1382fb72 (26 GiB) | this machine's provider last served exactly this artifact |

## July 2026-07-09/10 baselines (same machine, pre-v0.8.0 engine, for comparison)

| model (artifact) | v2 B=8 peak−active | v2-compiled B=8 | note |
|---|---|---|---|
| gpt-oss-20b-MXFP4-Q8 | 13.81−11.25 = **2.56 GiB** | 14.45−11.25 = **3.20 GiB** | compiled decode removed in v0.8.0 — the 3.20 path no longer exists |
| gemma-4-26B qat-4bit | 18.53−13.48 = **5.05 GiB** | 18.82−13.48 = **5.34 GiB** | basis of the 5.5 GiB default |

(July's v2-paged B=8 peaks — 29.44 / 32.49 GiB — included the paged pool allocation inside
the measured window in that harness version; the current harness resets the peak after
engine construction. Paged cells are supplementary in both sweeps.)

## Results

### gpt-oss-20b (re-baseline gate) — PASS

Artifact: mlx-community/gpt-oss-20b-MXFP4-Q8 @ 773a7da7 (identical to July).
Raw: `libs/mlx-swift-lm/benchmarks/reports/gptoss-20b-mxfp4q8-actfloor-2026-08-30.md`.

| cell | active | peak | peak−active | July |
|---|---|---|---|---|
| v2 B=1 | 11.25 | 12.37 | 1.12 | 1.19 |
| v2 B=2 | 11.25 | 12.28 | 1.03 | 1.08 |
| v2 B=4 | 11.25 | 13.47 | 2.22 | 2.20 |
| **v2 B=8** | 11.25 | 13.88 | **2.63** | **2.56** |

Current-engine eager B=8 transient matches July within 70 MB — the engine has not
drifted; July-derived floors remain meaningful. With compiled decode removed
(v0.8.0), the live worst path measures ~2.6 GiB; PR #683's 3.5 GiB floor (sized
against the removed compiled path's 3.20) now carries ~0.9 GiB of extra safety —
valid and conservative.

v2-paged B=8 peak−active = 18.40 GiB — the ~16 GiB pool (default `--kv-gb 16`)
allocates lazily *inside* the measured window (active stays 11.25), so paged rows =
pool + transients and are supplementary only. Same shape as July's 18.2.

### gemma-4-26b-8bit / gemma-4-26b (served 8bit artifact)

Artifact: mlx-community/gemma-4-26b-a4b-it-8bit @ 1382fb72 (the artifact this machine's
provider last served). Raw: `benchmarks/reports/gemma4-26b-8bit-actfloor-stock-2026-08-30.md`.

| cell | active | peak | peak−active |
|---|---|---|---|
| v2 B=1 | 24.97 | 25.55 | 0.58 |
| v2 B=2 | 24.97 | 26.13 | 1.16 |
| v2 B=4 | 24.97 | 26.55 | 1.58 |
| **v2 B=8** | 24.97 | 27.26 | **2.29** |

**2.29 GiB — less than half of July's 5.05 (qat-4bit).**

### gemma-4-26b-qat-4bit (re-baseline on current engine) — the headline finding

Artifact: mlx-community/gemma-4-26B-A4B-it-qat-4bit @ 0e3cbab3 — the exact July artifact.
Raw: `benchmarks/reports/gemma4-26b-qat4bit-actfloor-2026-08-30.md`.

| cell | active | peak | peak−active | July |
|---|---|---|---|---|
| v2 B=1 | 13.48 | 14.06 | 0.58 | 1.42 |
| v2 B=2 | 13.48 | 14.71 | 1.23 | 1.87 |
| v2 B=4 | 13.48 | 15.12 | 1.64 | 3.40 |
| **v2 B=8** | 13.48 | 15.76 | **2.28** | **5.05** |

Same artifact, same cell shapes, same machine as July: the B=8 transient dropped
5.05 → 2.28 GiB. The 8bit variant's 2.29 confirms it is quant-independent — **the
engine changed** (the Gemma prefill/decode optimization port that landed after the
July sweep). Consequences:

- **The 5.5 GiB default activation reserve is sized against an engine that no longer
  exists.** On the current engine the worst measured model is gpt-oss-20b at 2.63 GiB,
  not gemma.
- The measured-floor route stays valid, but the bigger lever may be **re-measuring the
  flat default itself** (the sanctioned "move the FLAT floor, both sides in one commit"
  shape) — pending the Qwen numbers and the L-scaling probes below, since long-prompt
  prefill is where composed-attention transients would resurface.

### Harness gaps hit (recorded for follow-up)

- `qwen3_5_moe` family (Qwen3.5-35B, Qwen3.6-35B): stock `--mode perf` SIGTRAPs at the
  first v2 warmup cell on this tree (both artifacts). Every historical qwen bench ran
  campaign mode (`--profile decode|full` + `--prompt-file` + `--receipt`, exactly 1024
  steps) from the now-deleted `mlx-swift-lm-eigenlabs-a3b` worktree (mlx-swift
  @6b0505cc). Campaign mode accepts `--batches 8` but requires a 40-hex modelRevision
  for the receipt. → Qwen measurements run in campaign mode on the true catalog
  artifact (hub 73a03825, re-downloading).
- `qwen3_vl_moe` (Qwen3-VL-30B): unsupported by the bench's LLM model-type registry
  (VLM-only type) — cannot be measured by this harness at all; needs a harness
  extension or a provider-side probe. Floor stays at the flat default.

### L-scaling probes — gemma-4-26b-qat-4bit, v2 B=8, current engine

Single uniform prompt length per run (`--prompt-lengths L --max-seq-len 2L`), 64 steps.
Raw: `benchmarks/reports/gemma4-26b-qat4bit-L{4000,8000,16000}-2026-08-30.md`.

| prompt length (×8 seqs) | peak−active | est. cell KV (fit ~22 KB/tok/seq) | activation-proper (non-KV) |
|---|---|---|---|
| 500 (matrix) | 2.28 | ~0.10 | ~2.2 |
| 4000 | 4.27 | ~0.72 | ~3.6 |
| 8000 | 4.90 | ~1.42 | ~3.5 |
| 16000 | 6.40 | ~2.83 | ~3.6 |

Findings:

1. **peak−active grows with L**, but the unbounded term is contiguous-cell KV
   (measured slope ~20–25 KB/token/seq; gemma's 5 full-attention layers), which
   production accounts under the KV budget, not the activation reserve.
2. **The non-KV activation transient saturates ≈ 3.5–3.6 GiB** by L=4000 (the
   chunked-prefill working set stepping in between 500 and 4000) and stays flat to 16k.
3. Consequence for retuning: the 500-token matrix alone (2.28) would justify a
   reckless default cut; the long-prompt saturated figure (~3.6) is the real
   current-engine gemma envelope. The 5.5 GiB default carries ~1.9 GiB of margin on
   the current engine — no longer 2× oversized, but still generous.
4. Methodology consequence: **fixed-L short-prompt sweeps under-measure the operating
   envelope**; floor measurements must include a long-prompt cell (≥4k) where the
   prefill working set has saturated.

### L-scaling probes — gpt-oss-20b, v2 B=8, current engine

Raw: `benchmarks/reports/gptoss-20b-L{4000,16000}-2026-08-30.md`.

| prompt length (×8 seqs) | peak−active | est. cell KV (measured slope ~48 KB/tok/seq) | activation-proper (non-KV) |
|---|---|---|---|
| 500 (matrix) | 2.63 | ~0.21 | ~2.4 |
| 4000 | 4.17 | ~1.49 | ~2.7 |
| 16000 | 8.57 | ~5.88 | ~2.7 |

#### Re-validation on the SHIPPED pins (2026-09-02)

The cells above were run on mlx-swift-lm `fe01df9` / mlx-swift `1d452d8`; PR #791
ships mlx-swift-lm `30da946` (which adds #126, an MoE dispatch change under the
sorted-hint path) and mlx-swift `6b0505c` (MLX 0.32.2). The gpt-oss B=8 cells were
re-run with `BenchCBv2` built at exactly those pins (`--print-revision` = `30da946`,
`Package.resolved` mlx-swift = `6b0505cc`), same machine, same convention
(`--mode perf --engines v2 --batches 8 --prompt-lengths L --max-seq-len 2L --steps 64`):

| prompt length (×8 seqs) | peak−active (shipped pins) | est. cell KV | activation-proper (non-KV) | Aug (older pins) |
|---|---|---|---|---|
| 500 | 2.27 | ~0.21 | ~2.1 | 2.63 |
| 4000 | 4.17 | ~1.49 | ~2.7 | 4.17 |

The saturated non-KV envelope is unchanged at ~2.7 GiB; the 3.5 GiB floor carries
~0.8 GiB of margin on the pins that ship. Raw reports (committed, unlike the
August raw files, which were lost with their worktree):
`docs/reports/raw/gptoss-20b-actfloor-shipped-pins-L4000-2026-09-02.md` and
`docs/reports/raw/gptoss-20b-actfloor-shipped-pins-L500-2026-09-02.md`.

The 48 KB/token/seq slope equals all 24 layers carrying unbounded KV in this
conversion (2×8 kv-heads×64 head_dim×2 B = 2 KiB/layer/token) — the sliding-window
config is evidently not limiting KV here. Non-KV activation is **flat ≈ 2.7 GiB** —
gemma's saturated ~3.6 remains the worst measured model on the current engine.

### qwen3.6-35b-a3b-vl-mtp-mxfp8 — served artifact, campaign mode (B=1 only)

Raw: `benchmarks/reports/qwen36-35b-vlmtp-actfloor-mtp-b8-2026-08-30.md` + receipt.
Run: campaign `--profile decode --mtp-depth 2`, true rev 73a03825, prompt 129 tokens,
1024 greedy tokens, inline MTP k=2 active (rounds=385, proposed=770, accepted=637 —
the production decode posture for this model). Decode 148.6 tok/s.

- Receipt `peakMemoryBytes` = 20,781,084,582 = **19.35 GiB** peak during the measured
  request; weights on disk 19.82 GiB (peak < disk is consistent with the unused VL
  vision tower never being materialized in a text-only run). The campaign report
  prints no `gpuActive`, so the B=1 transient delta cannot be split out exactly; it
  is bounded small (≲1 GiB), consistent with the other models' B=1 cells.
- **RESOLVED — the B=8 matrix runs after all.** The "SIGTRAP" was an
  Index-out-of-range in the bench's **v2-paged** cache wiring only (dense per-storage
  `pagedCaches[index]` subscripted with the hybrid trunk's sparse MODEL layer index
  from `newCacheV2`), and the buffered perf table meant the already-successful
  contiguous cells were discarded when the paged engine construction trapped.
  `--engines v2` alone completes. Fix committed on
  `fix/qwen35-stock-bench-trap` in the mlx-swift-lm worktree (model→storage index
  mapping; graceful `backendIneligible` on a miss; merged as mlx-swift-lm#129). **The
  production factory had the identical subscript shape and is fixed on the
  activation-reserve branch**: the paged-cache wiring maps each cache's model-layer
  index to its storage slot and guards an impossible miss
  (`EngineV2Factory+Production.swift:1018-1044`). Unreachable in production today
  only because `supportsPagedKV` vetoes paged for hybrid trunks upstream.

### qwen3.6-35b — stock B-matrix + L-probes (served artifact, v2 contiguous)

Raw: `benchmarks/reports/qwen36-35b-actfloor-stock-v2only-2026-08-30.md`,
`qwen36-35b-L{4000,8000}-2026-08-30.md`. Production-representativeness confirmed by
code trace: the bench's stock profile IS the production decode/prefill route (the
row-owned/direct-expert-reduction lanes are bench-only or env-gated default-OFF).
Since #777 (v0.8.14 train) embedded MTP heads auto-activate in production, so live
qwen3.6 decode additionally runs MTP k=2 — see the B=1-measured MTP delta below.

| cell | active | peak | peak−active | est. cell KV (~25 KB/tok/seq) | non-KV |
|---|---|---|---|---|---|
| v2 B=1 (500) | 18.17 | 18.95 | 0.78 | — | — |
| v2 B=2 | 18.17 | 19.40 | 1.23 | — | — |
| v2 B=4 | 18.17 | 20.00 | 1.83 | — | — |
| **v2 B=8 (500)** | 18.17 | 21.45 | **3.28** | ~0.11 | ~3.2 |
| v2 B=8 L=4000 | 18.17 | 22.23 | 4.06 | ~0.80 | ~3.3 |
| v2 B=8 L=8000 | 18.17 | 23.04 | 4.87 | ~1.60 | **~3.3 (saturated)** |

The hybrid linear-attention trunk saturates immediately (no composed-attention
prefill blow-up); the growing term is the 10 full-attention layers' KV. MTP delta
measured at B=1 only: stock 0.78 vs campaign MTP-k2 1.18 → ≈ +0.4 GiB (a measured
MTP-active B=8 needs the campaign B=N harness extension; with #777 merged this IS
the current-production posture, so the allowance applies to the live route).

**32 GB tier verdict (Outcome B leaning)**: with a best-case honest floor ≈ 4.0
(non-KV 3.3 + MTP 0.5 + slack), needs = 23.8 + 4.0 + 1.0 = 28.8 = exactly the
0.9×32 cap, leaving <4 GiB for macOS + the provider — not honestly serveable.
Recommend `min_ram_gb` 32 → 36 for `qwen3.6-35b-a3b-vl-mtp-mxfp8` (at 36: fits at
the shipped 5.5 default, 30.3 ≤ 32.4, with ~2 GiB cap margin). The measured 4.0
floor entry is DEFERRED — the shipped tables carry gpt-oss only, because the
qwens are vision-capable and the tower transient rides this reserve; the entry
returns with a vision-inclusive measurement (and would then widen the 36 GB
tier further).

### Bonus finding (explorer trace, separate from memory work)

`MLX_QWEN_DIRECT_EXPERT_REDUCTION` is documented as default-ON
(`docs/reports/2026-08-21-qwen-prefill-retained-optimizations.md:45`) but shipped
opt-in (unset → false, `SwitchLayers.swift:260`) — a retained, benchmarked prefill
optimization that is dark in production. Perf, not memory; flagged for follow-up.

### Measurement-validity notes

- Two runs carry the harness's "DARKBLOOM RUNNING — HOST CONTENDED" banner (the
  gpt-oss gate run and the qwen3.6 campaign; the daemon appeared mid-sweep and was
  idle — no slots, no inference). `MLX.GPU.activeMemory/peakMemory` are
  **process-local allocator counters**: contention taints latency numbers, not these
  memory figures — the contended gate run reproduced July's memory within 70 MB.
- All measurements are **text-only**; the VL vision towers were never exercised.
  This caveat is NOT contained by the provider's `VisionMemoryGate`: that gate
  reserves decoded-media buffers and KV, while the vision-tower transient rides the
  activation reserve these floors size. A vision-inclusive activation measurement is
  therefore still required before any VL model's floor (or the flat default, whose
  serving sets include VL models) is lowered on this evidence.
- Peak−active on contiguous v2 cells includes the cell's KV growth. The L-probes show
  the consequence: **short-prompt cells UNDER-measure the saturated activation
  envelope** (gemma 2.28 @ 500 vs ~3.6 saturated). Any floor-table measurement
  convention must include a ≥4k-prompt B=8 cell.

## Conclusions

Current-engine saturated non-KV activation envelopes (B=8):

| model | 500-tok convention (July basis) | saturated non-KV envelope |
|---|---|---|
| gemma-4-26b (qat-4bit & 8bit) | 2.28 / 2.29 | **~3.6** |
| gpt-oss-20b | 2.63 | **~2.7** |
| qwen3.6-35b (served artifact) | 3.28 | **~3.3 (measured; see the section above)** |
| qwen3.5-35b (rev 8964653) | 3.28 | ~3.3 (byte-identical family profile, measured 2026-08-31 with the fixed harness) |
| qwen3-vl-30b | n/a | n/a — served in production since v0.8.14 (#752), but the bench's LLM-factory load cannot construct `qwen3_vl_moe`; stays at the 5.5 default (fits its 32 GB tier: 27.0 ≤ 28.8) |

**Vision caveat that gates the qwen floors**: all figures above are TEXT-path.
The qwens (and the gemma VLM builds) are vision-capable, and the tower
transient rides the activation reserve — so despite the measured ~3.3
envelope, their floor entries are deferred until a vision-inclusive peak is
measured. Only text-only artifacts (gpt-oss) carry measured floors/residency.

1. **The 5.5 GiB default is sized against an engine that no longer exists.** Its basis
   measurement (gemma qat-4bit B=8 = 5.05, July) measures 2.28 on today's engine —
   the Gemma optimization port shrank the transient by more than half. The honest
   current worst-case envelope (gemma, long-prompt saturated) is ~3.6 GiB.
2. **Both levers are needed, not either — and on 32 GB neither is enough under the
   production default.** The effective ceiling is `min(0.9 × physical, physical −
   memory_reserve_gb)`; with the shipped `memory_reserve_gb = 4` that is
   `min(28.8, 28.0) = 28.0 GiB` on 32 GB, so the qwen3.6 tier needs
   `23.8 (padded) + floor + 1.0 ≤ 28.0` → floor ≤ 3.2 GiB. A measured qwen floor
   near 3.3–3.5 does NOT fit under the default; it fits only if the operator lowers
   `memory_reserve_gb` (the cap-implied floor is 3.2 on 32 GB) or the catalog
   re-tiers qwen3.6 to 36 GB — the re-tier is required regardless of any floor
   change. An aggressively retuned flat default (~4.5 = 3.6 + slack) does not fit
   either way. Per-model floors (#683's machinery) remain necessary for tight
   tiers; a default retune (5.5 → ~4.5) is a complementary follow-up, gated on the
   qwen B=8 measurement and the long-prompt convention, moved provider+coordinator
   in one commit as the contract requires.
3. **PR #683's numbers are confirmed valid on the current engine**: gpt-oss measured
   2.63 by the same convention its 3.5 floor was derived under (July compiled 3.20
   no longer exists as a path; 3.5 now carries ~0.9 GiB extra margin). The catalog id
   `gpt-oss-20b` exact-matches its table key. The release gate SHIPPED:
   `servabilityPerModelFloorMinVersion = "0.8.16"` with `ProviderCore.version` and
   `LatestProviderVersion` bumped to 0.8.16 in the same tree (the 0.8.11 placeholder
   and the 0.8.15-era coupling caveat recorded earlier in this report are resolved).
4. **L-decomposition validates the hybrid formula+measurement model**: the growing
   term in peak−active is analytic KV (measured slopes 22 KB/tok/seq gemma,
   48 gpt-oss — both explained by layer KV math), while the non-KV transient
   saturates at a measured, engine-version-dependent constant. Reserve = measured
   saturated constant; KV = the budget's analytic accounting. Formulas predict the
   scaling term; only measurement gives the constant.

## Follow-ups

1. ~~Harness fix~~ **DONE** (mlx-swift-lm PR #129): the "SIGTRAP" was the
   v2-paged dense-subscript bug + missing capability veto; stock contiguous
   was always fine, and the qwen3.6/3.5 B=8 matrices above were measured with
   the fixed harness.
2. **Vision-inclusive measurement** (the new gate): B=8 activation peaks and
   residency through the provider's VLM load/serve path — prerequisite for
   the qwen/gemma floor+residency entries AND the default retune.
3. **qwen3-vl-30b**: served in production since the v0.8.14 train (#752; vision off
   M5 per #781). The remaining gap is bench-side — a VLM-factory load path so its
   floor can be measured; same vision-inclusive gate as the other deferred entries.
3. **Re-measure the default's basis per release**: the 5.5 constant silently went
   stale when the engine improved. If floors move to the catalog (measured field per
   model, populated by the onboarding bench), staleness becomes visible and cheap to
   fix; the bench cell for it must include a ≥4k-prompt B=8 row.
4. qwen3.5-35b: local artifact (rev 8964653) predates the router8 campaign contract
   (`quantization.language_model.model.layers.0.mlp.gate` missing) — needs the
   catalog rev 59d61f3c artifact to measure.
