# PagedAttention Migration — Journal

Working log for the contiguous → paged KV migration shipping in **provider
v0.8.0**. Plan of record: `docs/reports/2026-07-25-paged-kv-migration-plan.md`
(Rev 2).

Integration branch: `paged-kv/integration`.

---

# ⇱ RESUME HERE — live state, rewritten every wave

*Everything below this banner up to `## Journal contract` is a MUTABLE snapshot.
The dated entries at the bottom are append-only history. If you are resuming
with no memory of this work, read this section and nothing else first.*

## Prime directive

**Do not stop until v0.8.0 ships PagedAttention everywhere** — every model,
every slot type, `.auto → .paged`. This is a multi-wave migration, not a task.
Finishing a wave is not finishing the job. Waves remaining are listed under
"What is left" below.

## Where everything is

| | Path / ref |
|---|---|
| Integration worktree (provider, coordinator, e2e, docs) | `/Users/gaj/Documents/Builds/d-inference-paged-kv` on `paged-kv/integration` |
| Engine worktree (submodule work) | `/Users/gaj/Documents/Builds/d-inference-paged-engine` on `paged-kv/engine`, submodule on `paged-kv/wave1` |
| Master checkout — **DO NOT WORK HERE** | `/Users/gaj/Documents/Builds/d-inference` (carries the owner's own parallel work) |
| Plan of record | `docs/reports/2026-07-25-paged-kv-migration-plan.md` (Rev 2, plus the Rev 2.1 correction in §10) |
| Engine repo | `Layr-Labs/mlx-swift-lm`, base `main`, pinned `abd1985` + Wave 0 |
| Provider repo | `Layr-Labs/d-inference`, base `master` |

## ⚠ RETRACTED DELETIONS — do not re-attempt

Two deletions were scheduled, started, and **stopped on evidence**. A compacted
context WILL want to redo them, because the original inventory still reads as if
they are dead. They are not.

| Do NOT delete | Why it looked dead | Why it is not |
|---|---|---|
| **Last-query prefill** (~1,384 lines: `Gemma4Text.swift` policy trio, `LastQueryPrefillV2.swift`, `AttentionV1.updateAndAttendLastQuery`, `CBv2LastQueryPrefillTests.swift`) | `numKvSharedLayers` "defaults to 20", so the last layer looked KV-shared | **The default applies only when the JSON key is ABSENT.** Both shipping checkpoints set `num_kv_shared_layers: 0` explicitly (verified on disk), `layer_types[29] = full_attention`, so `gemma4SupportsLastQueryPrefill` is TRUE and the feature is LIVE on the flagship. The "proof" test used `TinyGemma.sharedFinalConfig()`, a fixture built with `numKvSharedLayers = 2` — it pinned the negative case only. |
| **`CBv2PrefixCacheStats`** | A repo-wide grep for the TYPE NAME returned zero hits | The tests obtain it by **type inference** from `cache.stats()`, so no use site ever names it — and `stats()` is not a `CBv2PrefixCache` protocol requirement, so a protocol-surface grep misses it too. Six files read all five fields. Deleting the struct deletes `stats()` and breaks all six. |
| **`PrefixCacheV2`** (~1,293 lines) + its 8 dependent test files | Never constructed in production; `EngineV2SlotFactory.swift:379` installs `SSDPrefixCache` | It is the **only in-engine exercise of the `CBv2PrefixCache` contract**, and `SSDPrefixCache` is unreachable from `MLXLMTests`. `CBv2EndToEndTests:526-572` is the only test of the `requiresMaterializedSnapshots` guard — the exact bit WS-3.5 builds on. Keep as a test fixture; only `CBv2PrefixCacheStats` (zero references) is deleted. |

**Root cause, stated so it is not repeated: "not reachable from production" is
NOT "safe to delete".** The inventory measured the first and claimed the second,
and it was wrong three different ways:

1. A **Swift struct default** is evidence about absent keys only, never about a
   shipping checkpoint.
2. A type can be **dead in production and load-bearing as a test fixture**. Ask
   what covers the contract if it goes.
3. **Grep the accessor, not the type.** A type obtained by inference
   (`let s = cache.stats()`) has no use-site mention anywhere, and if the
   accessor is not a protocol requirement, a protocol grep misses it too — two
   independent searches both return clean on live code.

Track DEL netted **zero** source deletions after three refutations. That is the
correct outcome; the defect was in the inventory, not the execution. Deletion
totals quoted anywhere in the plan of record should be treated as unverified
until each premise is individually checked against a live caller.

## ⚠ Ordering constraints — violating these ships a daemon abort or silent corruption

1. **The ring shrink (WS-1.2 / 3.1) must land AFTER WS-3.5.** It collapses the
   ~528-token alias margin that keeps the MTP lazy-gather hazard latent.
2. **WS-3.3 must never ship without WS-3.4 (and 3.0).** Flipping
   `supportsSpeculativeWrites` makes `MTP/EngineLoopV2+MTPTargetVerification.swift:50-52`
   reachable — a `preconditionFailure`, i.e. daemon death with no telemetry.
3. **WS-0.2p must land before the `b == 1` precondition is lifted.** Unblocked
   packed prefill puts B gathers + B score tensors live behind
   `concatenated(axis: 0)` — over 3 GiB on one layer at B=8.
4. **WS-2.2 (spans) must not sub-block without fixing `spanChunkMask`.**
   `AttentionV1.swift:559-577` anchors on `context.chunkEnd`; under sub-blocking
   `qAbs` slides to the wrong absolute window. Silent wrong vision output.
5. **Do not delete the contiguous backend before 0.8.0 is stable.** It is the
   `DARKBLOOM_CBV2_PAGED_KV=0` rollback path and there is no canary fleet.

## Process rules learned the hard way

- **Absolute paths in every agent brief.** Relative paths resolve against the
  master checkout; this bit three agents in Wave 0.
- **No git state mutation in a worktree with live agents.** Main ran `git stash`
  during Wave 0 and swept an agent's in-progress work (recovered, no loss).
  Branch prep goes in throwaway worktrees (`/tmp/engine-pr`, `/tmp/dinf-pr`).
- **Agents never run git.** They leave changes in the tree; Main commits per
  track, which keeps attribution clean and avoids index-lock contention.
- **PRs are independent branches off base, not a literal chain**, unless the work
  is genuinely sequential. Every PR needs the before/after Mermaid pair.
- **Metallib:** engine tests abort with "Failed to load the default metallib"
  unless it is copied to `<engine>/.build/debug/` AND each
  `.build/debug/*PackageTests.xctest/Contents/MacOS/`. Source:
  `/Users/gaj/Documents/Builds/d-inference-paged-kv/provider-swift/.build/arm64-apple-macosx/debug/mlx.metallib`.
- **`.build/debug` is a symlink** — binaries run through it silently disabled
  paged until commit `0408b73`. Gate runs should still prefer
  `.build/arm64-apple-macosx/<config>/`.

## Wave status

**Wave 0 — DONE.** 8 commits, integrated, validated, all 8 PRs open:
engine [#86](https://github.com/Layr-Labs/mlx-swift-lm/pull/86) seam contract ·
[#87](https://github.com/Layr-Labs/mlx-swift-lm/pull/87) admission ring ·
[#88](https://github.com/Layr-Labs/mlx-swift-lm/pull/88) bench prompt axis ·
[#89](https://github.com/Layr-Labs/mlx-swift-lm/pull/89) resource symlink;
provider [#580](https://github.com/Layr-Labs/d-inference/pull/580) telemetry parity ·
[#581](https://github.com/Layr-Labs/d-inference/pull/581) CI paged gate ·
[#582](https://github.com/Layr-Labs/d-inference/pull/582) e2e backend knob ·
[#583](https://github.com/Layr-Labs/d-inference/pull/583) benchmark `--kv-backend`.

**Wave 1 — IN FLIGHT, 13 agents.** On completion: commit per track, bump the
gitlink, open a PR per track, then run the full validation set.

| Track | Items | State |
|---|---|---|
| L | 0.2p paged sub-blocking, 0.5 pad site, 2.3 capability protocol, 3.4 rectangular | running |
| P | 0.5 poison page, 0.6 guards, 1.3 lazy reservation, 6.4 PTOK | running (**NOT** the ring formula) |
| R | 3.2 spec transaction, 3.3 headroom | running |
| M | 3.0 graceful degradation, 3.5 materialize captures | running |
| G | remove compiled decode | running |
| DEL | **zero deletions** — all three premises refuted. Ships a header comment + an inference-consumer marker | yielding |
| T | differential oracle, slab canary, ring upper bound, invert the defect pin | running |
| X | OPEN-9 hard refusal, 0.4 merge scheduler configs, kv-quant veto | running |
| E2 | parametric activation reserve + `servability.go` 9-site mirror | running |
| E3 | `k` re-fit, quality cap reachable at 8 | running |
| C4 | mixed-version gate | **DONE**, uncommitted |
| KVQuantEngine | `CBv2QuantizedSequenceKV`, `PrefixReusePlan` case, `snapshotIsLossless` | running |
| KVQuantProvider | `kv_quant` → `RetiredCodingKeys`, orphaned scaffolding, docs | running |

## What is left after Wave 1

| Wave | Content |
|---|---|
| **2** | Ring shrink (1.2/3.1, gated on 3.5) · packed prefill / lift `b == 1` (gated on 0.2p) · WS-2.2 vision spans + lift the VLM veto · WS-4.1 `installShared`/`restoreWindow`/`windowSnapshot` + the three `.contiguousUnquantized` hardcodes · **WS-2.4 paged `CBv2LastQueryPrefillLayerCache` conformance** (upgraded, not deleted) · G's dead-but-compiling follow-up |
| **3** | WS-4.2 SSD windowed sidecar (2.5 wk) · §15 multi-model co-residency pool resize — **unscheduled and mandatory**, 94 mixed boxes · WS-7 heartbeat KV-backend discriminator (Gate G5) + MTP/paged telemetry fields |
| **4** | Benchmark matrix on the M4 Max (serialized, single machine) · Gates G0a/G0b/G1/G2/G5 |
| **5** | **The flip**: `EngineV2Factory+Production.swift:346` `.auto → .paged`, plus its 4 test updates · version bump `0.7.15 → 0.8.0` in BOTH `coordinator/api/server.go:148` and `provider-swift/Sources/ProviderCore/ProviderCore.swift:172` (AGENTS.md requires they stay in sync) · release |

## Open questions

| # | Question | Owner |
|---|---|---|
| OPEN-9 | Explicit paged request hard-refuses on preflight failure. **Decided yes**; TrackX implementing. Kill switch keeps degrading — it is an operator override, not a failure. | in flight |
| OPEN-10 | First CI run must be watched: the new paged kernel suites dispatch JIT Metal with no skip guard. | Main |
| OPEN-11 | `hypervisor_active` (~190 Go), `EngineV2Config` retired-env enum (39), BenchCBv2 legacy doc (4) — out of paged scope. Fold in only if the owner asks. | owner |

---

## Journal contract

- **Single writer.** Main appends every entry. Subagents do NOT edit this file
  — parallel worktrees would collide on it. Each subagent ends its task by
  emitting a `JOURNAL` block (format below); Main transcribes it here.
- **Append-only.** Never rewrite a past entry. Corrections get a new entry that
  references the old one.
- **One block per unit of work**, not per commit.
- Entries carry evidence: `file:line`, measured numbers, or an explicit
  `[INFERENCE]` tag. "Looks fine" is not an entry.

Subagent block format:

```
JOURNAL
stack:    <P|L|R|M|T|G|X|E|F|D|C>
pr:       <branch name or "none">
did:      <one line, past tense>
files:    <paths touched>
evidence: <what proves it works — test name, measurement, or "unverified">
decided:  <any judgement call made, and why>
blocked:  <what is needed, or "nothing">
```

## Scope for v0.8.0

**In scope (mine):** everything required to make `.auto` resolve `.paged` for
**every** model and slot type, safely, with observability and CI coverage.

**Out of scope (owned elsewhere):** the dedicated-models fleet partition and
hardware-aware routing. Everything else in the coordinator that paged or B=8
touches is mine — there is no second team; see DEC-4.

## Stack status

| Stack | Repo | Owns | State |
|---|---|---|---|
| **E0** seam contract | engine | protocol decls only | **DONE** — `a6af510` |
| **T** oracle | engine | `Tests/CBv2Paged*`, `CBv2KVSharingParityTests` | not started |
| **P** pool | engine | `PagedKVPool`, `PagedAttentionKernel` | not started |
| **L** layer | engine | `PagedLayerCache`, `LayerCacheBankV2` | not started |
| **R** row | engine | `PagedSequenceKV`, `PrefixReusePlan` | not started |
| **M** MTP | engine | `MTP/EngineLoopV2+MTP*`, `EngineV2` mode select | not started |
| **G** compiled | engine | `Compiled/*` + hooks | not started |
| **X** factory | d-inference | `EngineV2Factory+Production`, `EngineV2SlotFactory`, `ProviderConfig` | not started |
| **E** memory | d-inference | `AdmissionV2`, `UnifiedMemoryCap`, `registry/servability.go`, `registry/concurrency_cap.go` | E1 **DONE**; 0.0/0.0b/0.3 pending |
| **F** wire | d-inference | telemetry mirrors, `BackendSlotCapacity` | F1 **DONE**; discriminator + fields pending |
| **D** SSD | d-inference | `KVCacheSSD/*`, `PrefixCachePolicy` | not started |
| **C** CI/bench | d-inference | `ci.yml`, `e2e/testbed`, `BenchCBv2`, `gemma_contbatch` | C1/C2/C3 **DONE**; C4 (mixed-version gate) pending |

## Decisions (2026-07-25, product owner)

| # | Decision | Effect on the work |
|---|---|---|
| DEC-1 | **Remove kv-quant now.** Do not port it to paged. Quantized paged pages are separate follow-up work after the migration, and are considered worth doing. | New deletion stack. Simplifies `applySlotVetoes` and possibly the `PrefixReusePlan` backend enum. |
| DEC-2 | **VLM is mandatory.** gemma-4 — one of only two supported models — serves as VLM slots, so span masks must work and the VLM veto must be lifted. | WS-2.2 spans is a release blocker. Vision becomes the only unblocked prefill path, so WS-0.3's reserve must cost the span path at full `L`. |
| DEC-3 | **Remove compiled decode.** | WS-5 becomes a deletion stack. Collapses WS-2.5 (`uniformAttentionSoftcap` for paged) — it existed only to un-veto compiled. |
| DEC-4 | **We own the whole coordinator.** The quality cap and the load-factor re-fit are mine. | Track E absorbs `concurrency_cap.go` + the `k` re-fit. Not a handoff. |
| DEC-5 | **PR rights on every repo are available.** | No blocker on stacked branches in `Layr-Labs/mlx-swift-lm`. |
| DEC-6 | **Exclusive M4 Max, this machine only.** No second arm. | All benchmarks strictly serialize. Makes C3 (the benchmark context axis) critical-path, not reporting. |
| DEC-7 | **No canary fleet.** Ship 0.8.0, observe, cancel the release if it misbehaves. | Gates G3/G4 (24h soaks) are deleted. Pre-release verification — Track T's oracle, e2e, and the benchmark matrix — becomes the *only* safety net, so its bar goes up, not down. |
| DEC-8 | **MTP must work on paged.** | WS-3 in full, not just the 3.4 abort fix. |
| DEC-9 | **Prefill must be fast enough.** | Item 0.2p is a release requirement with a parity bar, not an optimisation. |
| DEC-10 | **MTP stays default-off in 0.8.0** (`[backend] mtp = false`). | Does NOT reduce the work — every WS-3 item is required for "working when enabled", because the current enabled-on-paged behaviour is silent inertness one flag-flip from a daemon abort. Keeps 0.8.0's blast radius to paged alone: MTP inflates `observed_decode_tps` with no wire discriminator, and there is no canary. |

## Open questions

| # | Question | Needed from |
|---|---|---|
| ~~OPEN-7~~ | ~~MTP default-on?~~ **RESOLVED: default-off** — see DEC-10. | — |
| OPEN-8 | Who repairs the red mixed-version gate (SIP disabled on the CI runner)? Defaulting to me as stack C4. | user (default: me) |

---

## Entries

### 2026-07-25 — Main — scope set, worktree created

```
JOURNAL
stack:    -
pr:       none
did:      Scoped v0.8.0 to full paged rollout; created the integration worktree
          and this journal; confirmed the two version anchors that must move.
files:    .claude/worktrees/paged-kv/JOURNAL.md
evidence: worktree on paged-kv/integration at 2b943b667, submodule at abd1985
          (verified: git submodule status). Version anchors that must go
          0.7.15 -> 0.8.0 in the release commit:
            coordinator/api/server.go:148  var LatestProviderVersion = "0.7.15"
            provider-swift/Sources/ProviderCore/ProviderCore.swift:172
              public static let version = "0.7.15"
          AGENTS.md requires these two stay in sync.
decided:  Single-writer journal (subagents emit blocks, Main transcribes) —
          per-track worktrees would otherwise conflict on every append.
          Stacked PRs: one linear chain per file-owner, all chains rooted on
          E0 (the seam contract), integration by submodule bump.
blocked:  OPEN-1..6 above.
```

### 2026-07-25 — Main — prior work carried in

```
JOURNAL
stack:    -
pr:       d5251a463, 2b943b667 (on master, pre-worktree)
did:      Bumped the engine submodule to abd1985 (#85, query-block prefill
          attention) and rewrote the migration plan as Rev 2 after verifying
          every claim against the current tree.
files:    libs/mlx-swift-lm (gitlink),
          docs/reports/2026-07-25-paged-kv-migration-plan.md (+2 companions)
evidence: provider `swift build` clean (33.1s); coordinator `go build ./... &&
          go test ./...` clean; provider `swift test` 1639 tests / 2 failures,
          both SelfUpdaterTests on a missing local mlx.metallib fixture
          (NSCocoaErrorDomain Code=4) — environmental, not the bump.
decided:  26 corrections logged in plan section 22. Four reshaped the work:
          (1) #85 shipped Track A, and paged does NOT inherit the win —
              PagedLayerCache.prefillAttend still does one SDPA over the full
              [L, kL] rectangle plus a gathered copy. New blocker item 0.2p.
          (2) B=8 is not reachable by provider config; the coordinator quality
              cap pins gemma-4 at 2. Split G0 into G0a/G0b.
          (3) The wire has no KV-backend discriminator, so a mixed canary is
              unobservable. New Gate G5.
          (4) CI runs no paged correctness test; the three silent-corruption
              classes have zero fireable assertions. New sections 19 and 20.
blocked:  nothing
```

### 2026-07-25 — RemovalSurface (scout) — deletion inventory

```
JOURNAL
stack:    scout
pr:       none
did:      Inventoried everything that dies under paged-everywhere + no-compiled + no-kv-quant.
files:    Gemma4Text.swift, GPTOSS.swift, CBv2LastQueryPrefillTests.swift, Compiled/*,
          EngineLoopV2.swift, PrefixCacheV2.swift, EngineV2Config.swift, EngineV2SlotFactory.swift
evidence: Last-query prefill is DEAD ON BOTH MODELS. It is gemma-4-only by type
          (gemma4UseLastQueryPrefill takes Gemma4TextConfiguration; grep across all 59
          files in Libraries/MLXLLM/Models matches Gemma4Text.swift ONLY), and on
          gemma-4-26B numKvSharedLayers=20 gates it off — pinned by the repo's own test,
          CBv2LastQueryPrefillTests.swift:730-733 asserts
          gemma4SupportsLastQueryPrefill(sharedFinalConfig) == false.
          Deletable now ~5,400 lines: compiled ~2,470, last-query ~1,384 (1,176 of it test),
          PrefixCacheV2 ~1,293 (zero production construction sites; EngineV2SlotFactory.swift:379
          installs ssdPrefixCache instead), hypervisor_active ~190 Go, EngineV2Config enum 39,
          bench legacy doc 4. Plus ~2,270 lines of contiguous backend held as the 0.8.0
          rollback path and deleted in phase 2.
decided:  Strike WS-2.4 (paged last-query conformance) from the plan — the work item does
          not exist. Delete the feature instead.
blocked:  nothing
```

Three corrections to the plan of record from this scout:

1. `EngineV2Config.swift` is **not** a retired-env warner. Only the enum is (39 of 281
   lines); the rest is the live bridge factory, including a live
   `maxConcurrentRequests: Int = 4` default at `:133`.
2. **`eagerCompositionStale` must survive.** MTP owns an independent writer at
   `MTP/EngineLoopV2+MTPFinalize.swift:195-197`. Only `eagerBindingsReleased` is
   purely-compiled and dies with it.
3. **Compiled decode is live in production today at B≤4** (`compiledSteps=130,
   fallbacks=[:]`). Deleting it is not a free win — it costs ~2–3% decode TPS at low B.
   It is still correct to delete (incompatible with paged, and no B=8 rung), but the
   honest framing is "a wash at B≤4, unavailable at B=8", not "strictly worse".

### 2026-07-25 — KvQuantRemoval (scout) — kv-quant deletion map

```
JOURNAL
stack:    scout
pr:       none
did:      Mapped the full kv-quant surface for DEC-1.
files:    43 files across three repos; 6 whole-file deletes + 1 whole-directory delete
evidence: ~1,700-1,900 deletable lines. applySlotVetoes COLLAPSES TO THE IDENTITY
          FUNCTION once kv-quant goes and the VLM veto lifts (DEC-2) — delete it and its
          test outright. `.contiguousQuantized` is already UNREACHABLE in production
          (EngineV2Factory+Production.swift:361 is the only construction site and never
          passes `quantization:`), so CBv2QuantizedSequenceKV (246 lines) is dead code kept
          alive solely by tests. PrefixReusePlan's backend enum goes 4 cases -> 3;
          `.contiguousUnquantized` should be renamed `.contiguous`.
          CBv2PrefixResidencyClass DOES NOT EXIST — it is a WS-4.1 planned symbol, so
          kv-quant removal cannot simplify it. provider-swift/Benchmarks/KVQuant/ and
          scripts/kvquant/ (~556 lines) are orphaned: the kv-quant-gate executable they
          document has NO TARGET in Package.swift. Removing CBv2QuantizedSequenceKV leaves
          snapshotIsLossless with zero false-returning implementors, making 3 guards and
          the .lossySnapshot wire enum vacuous.
decided:  USER-FACING BREAK: `darkbloom beta enable kv-quant` stops working and effectively
          every provider.toml in the field carries `kv_quant` because the serializer
          round-trips it. Config LOADING does not break (decodeIfPresent ignores unknown
          keys) but `kv_quant` MUST be added to the existing RetiredCodingKeys mechanism
          plus a release note.
blocked:  nothing
```

### 2026-07-25 — PrefillParity (scout) — 0.2p scoped and quantified

```
JOURNAL
stack:    scout
pr:       none
did:      Quantified paged-vs-contiguous prefill at abd1985 and scoped item 0.2p.
files:    Paged/PagedLayerCache.swift:309-344, AttentionV1.swift:460-495,
          Paged/PagedKVPool.swift:527-553, Paged/pagedattention.metal,
          Sources/BenchCBv2/BenchCBv2RealModel.swift, gemma-4-26B config.json
evidence: Verified from the real config: 25 sliding (w1024, d256, 8kv) + 5 full (d512, 2kv),
          num_kv_shared_layers = 0 -> 30 independent gathers per chunk.
          Score tensor 16*L*kL*2B: paged 2.044 GB vs contiguous-blocked 0.511 GB at 124k.
          Sliding FLOPs 785,920 vs 589,312 (+33%).
          Gather Sigma-retained: p50 336 MB, p90 8.12 GB, max 389.8 GB. The FULL-layer share
          (30.5 MB / 2.20 GB / 313.4 GB) is pure delta, because FullSequenceKV.update
          returns zero-copy strided views and copies nothing.
          Peak on ONE full layer at max ctx: ~3.06 GB vs contiguous 0.51 GB — over the flat
          3 GiB activation reserve.
          Measured TTFT (07-09, pre-#85, both arms unblocked): gemma +4.0..+14.4%,
          gpt-oss +2.0..+16.6% — a ~60-90 ms CONSTANT offset, not a slope.
          pagedattention.metal has exactly 3 kernels, all q=[B,KVH*GQA,D] with no query
          axis; the virtual-row trick needs an 8.19 GB f32 split-K partials buffer. No
          paged prefill kernel exists and none is reachable.
          NO PAGED PREFILL MEASUREMENT EXISTS ANYWHERE: PagedBackendBenchmark steps L=1 only
          and its "prefill" calls row.write directly, bypassing prefillAttend.
decided:  0.2p = ~40 lines inside prefillAttend, 2-3 days, one file. Three traps that a
          naive port hits: (1) do NOT reuse attendQueryBlocks — it is private AND its
          maskMode returns symbolic .causal, which violates the pinned-path contract at
          PagedLayerCache.swift:13-15; (2) do NOT move the gather inside the block loop —
          per-block spans overlap by window-1, a 3x pessimisation on sliding and 4x on full;
          (3) build qpos/kpos ONCE per chunk and slice — rebuilding per block regresses host
          arange work 4x on full layers. Free adjacent win: set the pool dtype to the model
          activation dtype (fp16 and bf16 are both 2B, capacity math unchanged) to delete
          the asType copy at :316-317.
          0.2p STRICTLY PRECEDES lifting the b==1 precondition: unblocked packed prefill
          puts B gathers + B score tensors live behind concatenated(axis:0), >3 GiB on one
          layer at B=8.
          Residual gather delta (+2.20 GB p90, +313 GB max) is structural and needs a new
          flash-attention kernel — OUT OF SCOPE for 0.8.0.
blocked:  Runtime activation dtype unconfirmed (config declares bfloat16, pool defaults
          float16) — one print settles it.
```

### 2026-07-25 — MTPPagedScope (scout) — MTP on paged, full breakdown

```
JOURNAL
stack:    scout
pr:       none
did:      Scoped MTP-on-paged end to end; derived that serial verification cannot beat
          plain decode, and recommended implementing paged rectangular instead.
files:    MTP/*.swift (9 files, 2,144 lines), Paged/*, LayerCacheV2.swift, CBv2Contracts.swift,
          MTPAutomaticVerificationPolicy.swift, EngineV2SlotFactory.swift, Tests/CBv2MTP*
evidence: MTP on gemma-4 paged today is a SILENT TOTAL NO-OP, not a crash.
          mtpStorageEligible uses allSatisfy over all 30 layers
          (EngineLoopV2+MTPPlanning.swift:28-30) and PagedSequenceKV.swift:115 returns false
          for the 25 windowed layers, so every request skips with recordSkip("kv_unsupported")
          and the depth controller returns 0. The provider still reports mtp_active = true
          (ProviderEngineBundle.swift:32 derives it from assistant-load success) and still
          charges 236 MB of assistant residency.
          The preconditionFailure at EngineLoopV2+MTPTargetVerification.swift:50-52 is
          unreachable ONLY because that gate fires first.
          Rectangular is ALWAYS selected in production: CBv2MTPRoundDriver.swift:253-259
          pre-clamps depth so (1+k)*B <= cap always holds, so the .automatic arm can never
          pick serial. Corroborated by MTPBenchmarkRunner.swift:419-427 asserting
          serialVerificationRounds == 0. Serial has never executed in the shipping provider.
          SERIAL IS STRICTLY WORSE THAN MTP-OFF, derivable without measurement: 1+k target
          forwards emit at most 1+k tokens, vs plain decode's exactly 1 per forward, plus k
          drafter forwards on top. So 100% of the 1.24-1.79x is rectangular's.
          Rectangular is CHEAP to port: it does NOT use batched multi-query attention.
          LayerCacheV2.swift:124 sets serializeQueries -> attendQueryBlocks(blockSize: 1),
          one query at a time. Rectangular batches only the weight-bound model body across
          1+k columns, which is backend-independent. Paged rectangular is a column loop over
          the EXISTING decode kernel. Zero Metal.
decided:  Implement paged rectangular (option b, ~3-5 days), NOT forced serial (option a).
          NEW item 3.0, ship unconditionally: replace the as? CBv2LayerCache downcast +
          preconditionFailure with a protocol conformance check that degrades to serial. A
          fatalError on an unrecognised cache class is a daemon abort with no telemetry.
          HARD ORDERING: 3.3 must never ship without 3.4 — flipping supportsSpeculativeWrites
          converts the silent no-op into a process abort.
          HARD ORDERING: 3.1 and 3.5 must land BEFORE item 1.2. The ring shrink collapses the
          ~528-token alias margin that currently makes the item-3.5 lazy-gather hazard latent.
          NEW item 3.6: paged arms for the MTP suites (CBv2MTPEngineMixedTests:216 already
          takes a backend parameter — a call-site addition). INVERT
          CBv2MTPKVStagingPagedFlagTests:434, which currently pins the defect.
          NEW item 3.7: fix the silent-inertness reporting in ProviderEngineBundle.swift:32.
          RECOMMEND MTP stays default-off in 0.8.0: it inflates observed_decode_tps with no
          wire discriminator, so default-on plus no canary is an uncontrolled routing
          perturbation. Default-off does NOT reduce the work — every item is required for
          "working when enabled".
blocked:  OPEN-7 (MTP default-on or not) is the owner's call.
```

### 2026-07-25 — Main — E0 seam contract written, Wave 0 dispatched

```
JOURNAL
stack:    E0
pr:       none
did:      Wrote the P/R/L seam contract and dispatched the five independent Wave 0 tasks.
files:    libs/mlx-swift-lm/Libraries/MLXLMCommon/ContinuousBatchingV2/Paged/PagedSeamContract.swift (new)
evidence: Declarations only, zero behaviour change. Grounded on the real surfaces:
          PagedSequenceKV members enumerated at :80-303, PagedKVPool at :82-463,
          PagedLayerCache at :26-386, the existing shared protocol
          CBv2AttendingLayerCache at CBv2Contracts.swift:488, and the MTP downcast site
          at MTP/EngineLoopV2+MTPTargetVerification.swift:49-54. Compile pending — the
          worktree currently has five agents mid-edit, so a build now would report their
          in-progress state, not mine.
decided:  E0 contains three things and deliberately nothing else.
          (1) CBv2PagedSpeculation.maxSpeculativeSpan = 8. This is the highest-value item
              in the file: track P consumes it in ringPageCount (WS-3.1) and track R
              consumes it in supportsSpeculativeWrites (WS-3.3), in different files. If
              they each invent one they collide, and the failure mode is a ring that
              under-reserves — silent corruption, not a build error. Stated as a literal
              with a static assertion against CBv2MTPConfig.testedMaxDraftTokens + 1
              (= 8, MTPContractsV2.swift:175) so raising the MTP bound cannot silently
              under-size a ring built before the raise.
          (2) CBv2MTPRectangularSerializing, with CBv2LayerCache conformed by extension
              (the stored flag already exists at LayerCacheV2.swift:49). This is the
              foundation for item 3.0. It is genuinely needed rather than cosmetic:
              CBv2LayerCache is `final` and PagedLayerCache is a sibling conformer of
              CBv2AttendingLayerCache, so the `as? CBv2LayerCache` downcast at
              MTP/EngineLoopV2+MTPTargetVerification.swift:50 can never succeed for a
              paged bank, and its failure path is a preconditionFailure — a daemon abort
              with no telemetry.
          (3) CBv2PagedSpeculativeRow.speculativeHeadroom. begin/commitSpeculativeWrite
              already exist as CBv2SequenceKV requirements with default no-ops
              (CBv2Contracts.swift:297/304), so only the headroom query is new.
          Everything else is a frozen-signature comment block rather than a stub, so E0
          touches no file any track owns. Tracks implement against it; conformances are
          added by their owners.
          Worktree policy for Wave 0: agents share the integration worktree with strictly
          exclusive file lists rather than one worktree each. Five submodule clones is
          real cost for tracks whose files are disjoint. Agents do not run git; Main
          commits per track, which keeps attribution clean and avoids index-lock
          contention. Wave 1 revisits this — P/R/L genuinely need isolation.
blocked:  nothing
```

### 2026-07-25 — Main — Wave 0 complete, integrated and validated

Seven commits. Superproject `paged-kv/integration`, engine `paged-kv/wave0`,
gitlink bumped at `164614eb3`.

| Commit | Repo | What |
|---|---|---|
| `a6af510` | engine | E0 seam contract |
| `1c85ced` | engine | E1 Bug A — ring charged at admission |
| `10a5016` | engine | C3 BenchCBv2 prompt-length axis + provenance |
| `0408b73` | engine | paged resource lookup through symlinked roots |
| `238712300` | super | F1 telemetry 3-way allowlist parity guard |
| `e54aa59c6` | super | C1 CI paged correctness gate |
| `0ee27c8d2` | super | C2 e2e KV-backend + concurrency knob |
| `56f0ca323` | super | C3 `darkbloom benchmark --kv-backend` |

```
JOURNAL
stack:    integration
pr:       paged-kv/integration, paged-kv/wave0
did:      Integrated all five Wave 0 tasks plus one defect found in flight, bumped the
          gitlink, and validated the combined tree.
files:    see the table above
evidence: coordinator `go build ./... && go test ./...` clean; `cd e2e && go build ./...`
          clean; engine `swift test --filter
          'CBv2SchedulerAdmissionTests|CBv2FrozenReplayPlanTests|CBv2PagedSafetyTests|CBv2PagedEligibilityTests'`
          -> 25 XCTest + 18 swift-testing, 0 failures. provider `swift build` clean.
decided:  Content-dedupe, not path-dedupe, for the paged resource locator. C1 correctly
          warned that resolving roots alone converts an unreachable `.ambiguous` into a
          reachable one; the repro turned out to be even more direct than predicted — with
          both build trees populated, two byte-identical copies of pagedattention.metal are
          reachable (provider-swift's own bundle, and libs/mlx-swift-lm's, which the
          source-ancestor walk finds). `.ambiguous` exists to stop the process loading an
          unknown VARIANT of the kernel, so the right key is bytes. A divergent resource
          still throws.
blocked:  nothing
```

**Defect found and fixed in flight (not in the plan).** `PagedAttentionResources.locate`
enumerated roots with `contentsOfDirectory(at:)`; `.build/debug` is a symlink to
`.build/<triple>/debug`, the URL enumerator does not follow it, so the kernel source was
never found and `EngineV2Factory` degraded paged → contiguous **at INFO level**. Any
benchmark or e2e run through the conventional path silently measured contiguous while
reporting that paged was requested. `swift test` was unaffected. Fixed; both invocation
paths now print `paged-kernel-runtime-smoke: ok`.

**Open item raised by C1, not yet actioned.** The INFO-level degrade is arguably worse
than the symlink was. When paged is *explicitly* requested — `--kv-backend paged`, or
`engine_v2_kv_backend = "paged"` — a kernel-preflight failure should be a hard refusal,
not a fallback. `.auto` should keep falling back. Tracked as **OPEN-9**; belongs to
track X with `EngineV2Factory+Production.swift`.

**Process incident, mine.** I ran `git stash` in the shared worktree while C3 was still
editing, which swept its in-progress `BenchCBv2RealModel.swift` into a stash. Recovered
with no loss — E1 cherry-picked back, C3's 104 insertions restored, all three verified
byte-identical afterwards. Root cause: I mutated git state in a worktree with live
agents. **Rule for Wave 1: no git state mutation while any agent is running in that
worktree.** This is also an argument for the per-track worktrees Wave 1 was going to use
for P/R/L anyway.

**Second process note.** Three of five agents had relative `edit` paths resolve against
the master checkout instead of the worktree. All three detected it themselves and
reverted; master is clean (verified: only the 9 files of the owner's own parallel work).
Wave 1 task briefs must state the absolute worktree path for every edit.

### 2026-07-25 — Main — open questions after Wave 0

| # | Question | Owner |
|---|---|---|
| OPEN-8 | Mixed-version gate is red (SIP disabled on the CI runner). Defaulting to me as C4. | me |
| OPEN-9 | Should an explicit paged request hard-refuse on kernel-preflight failure instead of degrading at INFO? Recommend yes. | me, track X |
| OPEN-10 | `CBv2PagedKernelTests`/`CBv2PagedBackendTests` dispatch JIT Metal with no skip guard. Assessed low risk — `CBv2PagedSafetyTests` already runs `runtimeSmoke()` green in the same CI job — but the first CI run must be watched. | me |

### 2026-07-25 — Main — Wave 1 dispatched, 11 tracks in parallel

Correction to how Wave 0 was run: too much implementation stayed with Main. The
paged resource-locator fix is the clearest case — C1 and C3 had already produced
a complete brief (repro, cause, and the specific trap in the naive fix) and Main
still implemented it across six serial build/test cycles. That was a textbook
delegation. From Wave 1 on, Main scopes, contracts, reviews and integrates;
agents implement.

| Track | Worktree | Owns | Items |
|---|---|---|---|
| **L** | engine | `PagedLayerCache`, `LayerCacheBankV2` | 0.2p, 0.5 (pad site), 2.3, 3.4 |
| **P** | engine | `PagedKVPool`, `PagedAttentionKernel` | 0.5 (poison page), 0.6, 1.3, 6.4 |
| **R** | engine | `PagedSequenceKV`, `PrefixReusePlan` | 3.2, 3.3 |
| **M** | engine | `MTP/*` | 3.0, 3.5 |
| **G** | engine | `Compiled/*`, `EngineLoopV2`, `EngineV2`, `SequenceKV/*` | remove compiled decode |
| **DEL** | engine | `Gemma4Text`, `LastQueryPrefillV2`, `AttentionV1`, `PrefixCacheV2` | ~1,900 lines of dead code |
| **T** | engine | paged + MTP test suites | differential oracle, canary, ring bound |
| **X** | provider | `EngineV2Factory+Production`, `EngineV2KVBackendPolicy`, `EngineV2SlotFactory` | OPEN-9, 0.4, kv-quant veto |
| **E2** | provider | `UnifiedMemoryCap`, `registry/servability.go` | parametric activation reserve |
| **E3** | provider | `registry/concurrency_cap.go`, `warm_pool_target.go` | `k` re-fit, cap reachable at 8 |
| **C4** | provider | `e2e/mixed_version_test.go`, `integration.yml` | repair the red gate |

Two worktrees, not eleven: `d-inference-paged-engine` (74M — git worktrees share
the submodule object store) and `d-inference-paged-kv`. File ownership is
exclusive within each; SwiftPM serialises builds on a lock, which blocks rather
than corrupts. Eleven worktrees would have cost tens of GB of `.build` for no
isolation the ownership map does not already provide.

Held out of this wave deliberately:

- **The ring shrink (WS-1.2/3.1).** It collapses the ~528-token alias margin
  that keeps M's lazy-gather hazard latent. M's 3.5 lands first.
- **Lifting `b == 1` (packed prefill).** Needs L's 0.2p proven first, or B
  gathers and B score tensors go live simultaneously — over 3 GiB on one layer
  at B=8.
- **kv-quant removal and the SSD windowed sidecar.** Both are cross-cutting
  across files P, R and X own this wave. Wave 2.

Ordering constraint carried in the batch context, because it is a daemon-abort
risk: **R's 3.3 must not be considered safe until M's 3.0 lands.** Flipping
`supportsSpeculativeWrites` makes the MTP `preconditionFailure` reachable. R was
told to confirm with M over IRC before declaring done.

Main is staying out of both worktrees while agents run — no git state mutation,
per the Wave 0 incident.

### 2026-07-25 — Main — stacked PRs open; last-query deletion RETRACTED

**8 PRs open for parallel review.** Wave 0's commits were split into independent
branches off each repo's base rather than a literal stack — they touch disjoint
files, so a chain would have created false ordering and serialised review for no
reason. Genuine stacks come when work is genuinely sequential (P1→P2→P3 within a
track).

`Layr-Labs/mlx-swift-lm`, base `main`:

| PR | Branch |
|---|---|
| [#86](https://github.com/Layr-Labs/mlx-swift-lm/pull/86) seam contract | `paged-kv/seam-contract` |
| [#87](https://github.com/Layr-Labs/mlx-swift-lm/pull/87) admission ring | `paged-kv/admission-ring` |
| [#88](https://github.com/Layr-Labs/mlx-swift-lm/pull/88) bench prompt axis | `paged-kv/bench-prompt-axis` |
| [#89](https://github.com/Layr-Labs/mlx-swift-lm/pull/89) resource symlink | `paged-kv/resource-symlink` |

`Layr-Labs/d-inference`, base `master`:

| PR | Branch |
|---|---|
| [#580](https://github.com/Layr-Labs/d-inference/pull/580) telemetry parity | `paged-kv/telemetry-parity` |
| [#581](https://github.com/Layr-Labs/d-inference/pull/581) CI paged gate | `paged-kv/ci-paged-gate` |
| [#582](https://github.com/Layr-Labs/d-inference/pull/582) e2e backend knob | `paged-kv/e2e-backend-knob` |
| [#583](https://github.com/Layr-Labs/d-inference/pull/583) benchmark `--kv-backend` | `paged-kv/bench-kv-backend` |

Every description carries the before/after Mermaid pair AGENTS.md requires.
Branch prep was done in throwaway worktrees (`/tmp/engine-pr`, `/tmp/dinf-pr`)
so the two live worktrees were never touched — the Wave 0 stash incident rule.

---

**RETRACTED: last-query prefill is not dead. `TrackDEL_DeadCode` stopped the
deletion and was right.**

```
JOURNAL
stack:    DEL
pr:       none
did:      Refuted the deletion premise before removing ~1,384 lines of live code.
files:    verified against both shipping config.json files
evidence: gemma-4-26B-A4B-it-qat-4bit and gemma-4-26b-a4b-it-4bit BOTH set
          num_kv_shared_layers = 0 explicitly, num_hidden_layers = 30,
          layer_types[29] = "full_attention". So layerUsesSharedKV(29)
          short-circuits false at Gemma4Text.swift:330, all three conditions of
          gemma4SupportsLastQueryPrefill hold, and the feature is LIVE: every
          prompt chunk >= 128 tokens selects it on the final layer via
          Gemma4TextModel.cbv2Prefill -> SteppableAdapterV2.swift:78, because
          CBv2LayerCache conforms to CBv2LastQueryPrefillLayerCache
          (LayerCacheV2.swift:186).
decided:  Deletion abandoned. DEL's new CBv2LastQueryPrefillProductionShapeTests
          is kept — it pins the production shape, which nothing did before.
blocked:  nothing
```

**My error, not a scout's.** The Rev 2 claim rested on `numKvSharedLayers`
"defaulting to 20". That default applies only when the JSON key is ABSENT.
Worse: the model-facts block of the Wave 1 task brief states
`num_kv_shared_layers: 0` — sourced from `PrefillParity`, which read the real
`config.json` — while the deletion rationale two sections below asserted the
struct default. **I had both halves in one document and did not reconcile
them.** Had this shipped it would have been a silent perf regression on the
flagship model.

The wrong conclusion looked tested because the cited proof
(`CBv2LastQueryPrefillTests.swift:729-734`) uses `TinyGemma.sharedFinalConfig()`,
a fixture deliberately built with `numKvSharedLayers = 2` — it pins the NEGATIVE
case only.

Rule added to the plan: **a Swift struct default is evidence about absent keys
only, never about a shipping checkpoint.**

**This makes WS-2.4 more important, not less.** Under paged, if
`PagedLayerCache` does not conform to `CBv2LastQueryPrefillLayerCache`,
`hasCapableCache` goes false and the flagship model silently loses the
optimisation on the final layer of every chunk — an unpriced paged-vs-contiguous
regression. Perf, not correctness, so it does not block the flip, but it belongs
in the release measurement and is now a scoped item for track L.

### 2026-07-25 — Main — Wave 1 rulings

| Track | Ruling |
|---|---|
| **G** | Granted the compiled-decode call sites outside its list (`SteppableAdapterV2`, `FrozenReplayFullSequenceKV`, `BenchCBv2RealModel`, 7 test files) — mechanical only. Carve-out: `CBv2MTPKVStagingTests.swift` stays TrackT's. Its dead-but-compiling list (`producesCompiledDecodeEligibleRows`, `externalReserveBytes`, `uniformAttentionSoftcap`) is deferred to one deliberate follow-up, not scattered. |
| **X** | Granted both gate/policy test files and `EngineV2Config.swift`. Its call that the fleet kill switch keeps DEGRADING on explicit paged is **right** and must be commented in code: a kill switch that refuses would 503 every slot on a paged-configured fleet. Refusal set is exactly preflight / capacity / construction error. Also adding a dedicated refusal reason — `.engineInitFailed` is a catch-all that would make a paged regression indistinguishable from a bad model load. |
| **R** | May append a suite at EOF of `CBv2PagedBackendTests.swift`; asked to also assert free-list and refcount restoration, since a row-only check passes even if a deferred free leaks. `PrefixReusePlan.swift` released back to unowned. |
| **C4** | Complete. SIP was **incidental**, not intrinsic — coordinator trust is stamped (`suite.go:367-372` forces `ChallengeVerifiedSIP = true`) and the provider-side check is log-only. Replaced with a SHA-256 artifact pin plus an explicitly host-gated `security_posture` subtest that is falsifiable in both directions and never skips. |
