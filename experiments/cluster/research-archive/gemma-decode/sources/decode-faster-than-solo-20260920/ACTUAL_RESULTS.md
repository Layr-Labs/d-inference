# Decode faster than solo: measured status

The acceptance target is a real, matched decode win over a single Mac, including the best qualified solo MTP configuration. It has **not yet been achieved**.

## Latest completed Gemma run

Both Macs are M4 Pro (14 CPU / 20 GPU cores), with 24 GB and 48 GB unified memory. The registered Gemma 4 26B 4-bit artifact was run with a 4,096-token prompt, 64-token prefill chunks, 16 output tokens, greedy sampling, MTP disabled, one warmup and three measured requests. The pair used a 7/23 layer split and plaintext lab RDMA.

| Configuration | Prefill tokens/s | Decode tokens/s |
|---|---:|---:|
| 48 GB solo | 371.09 | 46.56 |
| Two Macs, CPU-only control frames | 454.79 | 32.02 |

The previous padded-control pair result was 32.01 decode tokens/s. CPU-only control frames remove unnecessary GPU synchronization from host-only messages, but did not provide a meaningful speedup to the existing serial layer split. Their purpose in the next candidate is to let drafting and target verification overlap.

Exact output tokens, complete captured logit rows and cache components matched the retained references. The successful comparison is `review-cpu-source-union-correction/actual-cpu-1/comparison.json`, SHA-256 `b9d85f0544fcd828551a7cf570e838fc09ae0204fdb87f67b96151a9a784c4f2`. The original comparator failure and its source-union correction are both retained. Native build: `4170caffc2f21238efea2ab115c4a3d43a105faedd78e62fbbad0e84b8e4d621`.

## Current candidate

Keep the complete target on the 48 GB Mac and run the registered small Gemma assistant on the 24 GB Mac. The assistant drafts from a frozen target KV/hidden snapshot while the target verifies a bounded proposal window. Only target-confirmed output may be published. Reusing lookahead also requires matching the target's bonus token; otherwise the branch must retire and reseed.

The registered assistant (236,127,665 bytes of catalog files) is hash-verified and installed on both Macs. Its aggregate SHA-256 is `d8c5fae1f4b7a07376c9f0b92f3ec283ba276d57ec3b675d8cf758a79d73bd34`.

The owned rectangular target state, target-session adapter, conditioning seam and proposal ledger compiled in native build `586aef9b75e7769563be420285442d36eab8355d30f15d45be7664eb097f1366`. The tiny physical state qualification passed all 24 control groups and 56 prefix cases on the 48 GB Mac, including rollback, rejected-suffix isolation, cancellation and window wraps. See `../gemma4-mtp-state-physical-draft-20260920/comparison-1.json`. It exercised real native cache state, not Gemma weights, and establishes no model throughput or batch-numerical claim.

Foundation-only controls also passed: 13 proposal-ledger groups, six attention-plan groups, and 17 bounded-control-operation groups. The latter operation-boundary policy has not been composed into the native runtime or performance-qualified. The power-reader comparison was CPU-only and likewise has not changed runtime policy.

## Actual local MTP result

The checked assistant loader and combined resource owner are now compiled and physically exercised. All 94 registered assistant tensors loaded; depth-one and depth-two conditioning matched the original CBv2 assistant. The actual constructor/live-memory checks, request cleanup and device lease retirement passed.

Native build `eaeb7eecd1f135f75ce53919ca0d517b743411bda0224f190f0f8158413d19e7`, one warmup and three measured requests, C64/O16, greedy:

| Prompt tokens | Mode on 48 GB Mac | Prefill tokens/s | Decode tokens/s | Accepted/proposed draft tokens per request |
|---|---|---:|---:|---:|
| 128 | Solo, MTP off | 391.41 | 59.57 | — |
| 128 | Local MTP, depth 2 | 391.87 | 36.20 | 6/14 |
| 4096 | Solo, MTP off | 370.15 | 46.94 | — |
| 4096 | Local MTP, depth 2 | 371.05 | 32.12 | 7/14 |

These are measured rates, not a qualified speedup. Local MTP is slower. The 4K MTP case first refused before loading because actual free memory was below its unchanged threshold. An authorized cache-only purge restored sufficient free memory; the fresh retry passed resource and process checks. Both receipts are retained.

At P128 the 16 greedy output IDs matched, but the complete final logit row did not: maximum absolute difference 2.4101 and relative RMS difference 11.18%. All 60 K/V components differed; 30 position components matched. Prompt positions 0–127 and the ordinary prime at 128 were exact. The earliest chronological divergence was at position 129, initially small, then amplified through subsequent layers. This is an unresolved numerical failure, not merely a comparator issue or an accepted rounding tolerance.

Evidence is in `harness-local-mtp-v2/cases/{p128-solo-capture-1,p128-mtp2-qualification-1,p4096-solo-timing-1,p4096-mtp2-timing-2}` and `p128-numerical-diagnostic-1/REPORT.md`. The original failed complete-row comparison remains in `p128-numerical-actual-1`.

The dense multi-token projection dispatch uses explicit dequantization and a different reduction from single-token qmv. A private kernel experiment reuses packed weights across up to three token rows while retaining single-token arithmetic. The synthetic primitives and forced-token target controls have now run; their measured outcomes are recorded below. Full-model correction remains pending.

The asynchronous remote assistant protocol and target/assistant cohort sources are prepared, including target-only resource admission and bounded transfer lifetimes, but have not yet executed on both Macs. They do not fix the numerical failure by themselves. No new kernel is enabled in default model dispatch. No faster-than-solo claim, encrypted production serving qualification or M3 Ultra measurement has been established.

## Measured verification bottleneck

The timer-only successor physically ran P128/C64/O16 on the 48 GB Mac (native `73abfebeacf531f74e20a6b59b89325afd02b5d1c0a6ff8f36548df8c05328c8`, one warmup/three measured). It preserved the target arithmetic and produced the same selected tokens. The original resource/process comparison passed; numerical correctness remains unresolved as above.

Per measured request, target admission used 167.27 ms (40.30% of total decode), actual target execution plus validation 205.19 ms (49.44%), drafting 23.03 ms (5.55%), and reconciliation 11.08 ms (2.67%). Width-one admission was 20.16 ms versus 16.32 ms execution; width-three admission was 18.14 ms versus 24.65 ms execution. These are wall-time phases, not pure GPU kernel timings.

The admission code queries the same actual allocation-footprint/device-limit function repeatedly for equal-sized per-layer arrays. The bounded per-admission memoization below preserves each separately charged array and every fresh OS/native admission observation. Raw evidence and replayable summaries are `harness-local-mtp-target-profile/cases/p128-mtp2-target-profile-1`, `local-mtp-phase-summary.json` and `local-mtp-target-phase-summary.json`.

## Admission optimization: actual measured improvement

The per-invocation bound memo compiled as native `ffb80547d4715dad6a212efc9c599389357a9d2601c18ed1483482cf0d2772fa`; all seven focused accounting controls passed. On P128/C64/O16, local MTP depth2 improved from 36.20 to **55.50 decode tokens/s** (measured requests 58.22,55.77,52.49; one warmup excluded). Admission fell from 167.27 to 12.43 ms/request. Prefill was391.16 tokens/s; draft acceptance remained6/14 per request. A fresh same-build solo case measured **61.03 decode tokens/s** and406.76 prefill tokens/s; MTP remains slower and is not a distributed win. That solo case is `harness-local-mtp-bound-memo/cases/p128-solo-memo-1`.

The independently re-read non-regression comparison passed all four complete262144-value final rows, all360 final state components (128,860,640 bytes per arm),64 token IDs and all acceptance/width counts against the earlier local-MTP run. All728 files and both physical/build/source/native evidence chains were validated. Target/auxiliary reservation totals were unchanged. The memo therefore preserved the prior local-MTP numerics, **including its unresolved difference from ordinary solo**. See `memo-numerical-nonregression-actual-2/comparison.json`, SHA `c23d9c9e740d459b6d03135aa0c828edc81aae8946c5cd4161f2b329db2994f8`. The preceding reader rejection on an empty Python package initializer is retained; its correction changed only zero-length source-file handling.

Both private shared-weight primitives were separately exercised on the48GB GPU:108 dense cases matched independent M1 projections exactly;288 gathered-expert cases matched existing gathered projections, including96 weighted-slot comparisons and12 malformed-route controls. Original physical resource/lease/process comparisons passed. The gathered candidate was slower in the isolated measurements and remains unused. These synthetic primitive checks establish no full-model speedup or full-model numerical fix. Results: `../gemma4-small-qmv-physical-20260920/comparison-{dense,gathered}-1.json`.


## Forced-width full-model isolation

Native `73abfebe` loaded the registered model once and ran four fresh P128/C64/O16 target sessions: ordinary decoding; width-one verification; width-three verification retaining all three forced inputs; and three width-three windows each retaining one forced input. Every arm used the ordinary arm's actual selected tokens, the same prime at128, and the same committed frontier132.

Width-one verification matched ordinary exactly on all six captured complete rows and all90 cache components. Both width-three modes failed with the same discrepancy pattern:52/90 state components differed, starting in layer0's value cache. Captured rows0 and1 were exact; rows2,3,4 and15 differed. The read consumed all24 complete rows and360 state components (144,114,144 native bytes). The physical resource/process comparison passed; the numerical comparator naturally exited1 and its failed evidence is retained. This isolates the observed failure to width-dependent forward computation; it does not qualify a proposed fix or establish a benign tolerance.

Evidence: `harness-target-width-v1/cases/p128-width-controls-1/comparison.json`. The next explicit dense-only qualification preserves ordinary/M1 controls, existing gathered expert computation, fresh admission, and all original numerical checks.


## Dense projection correction: actual full-model pass

Native `00442de76acb54cf73148f0763ad266b5d3dd48b5514ca7494dfc50ffae72a55` passed the same P128/C64/O16 forced-token qualification with the explicit dense policy. All24 complete captured rows and all360 state components were read; all18 non-reference complete rows and270 non-reference components matched ordinary solo exactly. This covers ordinary/M1 bypass, width-three keep-all and repeated width-three keep-one at the same frontier132. Actual235 dense modules plus one tied head were exercised. Gathered expert dispatch remained unchanged. This is a numerical pass for this fixed test, not a long-context or throughput qualification.

The fix retains M1 reduction arithmetic for packed multi-token dense projections and evaluates the tied head per row with shared metadata casts. Four separate head-output rows are explicitly charged; existing resource floors, native ownership, cancellation and process/lease retirement remain. The original physical comparison passed, and17 focused parser/native-byte controls passed.

Evidence: `harness-target-width-dense-v1/cases/p128-dense-width-controls-1/comparison.json`, SHA256 `075f4dba32a49c8c5f0dbb1d35361dccae23234ff2685835cc0f14c05f84d398`. The first compile failed on four scalar constructors in the separate tiny-RDMA fixture; its exact one-file correction and failed receipt are retained. The successful build took55.39 seconds, sources `809aba59d5569646bb436fb9de4895595fae17a7326cb1e3c915a01a983c5f16`.

The remote protocol's18 Foundation controls and six resource-budget controls also executed and passed; its eight Python contract controls passed. These establish no actual two-device transport claim. The next step is tiny actual-RDMA qualification and explicit local/remote MTP activation with this arithmetic policy, followed by matched solo comparisons.


## Actual two-Mac pull protocol qualification

The tiny real-JACCL qualifier passed on both Macs using native00442de. It exercised all five cases:21 actual snapshot tensor transfers; queued acknowledgment followed by fenced scalar-token pull; cancellation of queued/unpulled work after fencing; retained receive roots through an injected post-receive check failure; and malformed sequence/padding rejection with refusal to reuse a poisoned channel. This uses synthetic exact roots, not Gemma or assistant inference. All original physical resource, peer cancellation, canonical lease/process retirement and Thunderbolt alias-restoration checks passed.

The initial attempt refused on the24GB Mac at startup. A fresh reading showed10,346,299,392 actual free bytes, below the unchanged10GiB+128MiB+2MiB requirement. Authorized filesystem-cache reclamation raised this to12,916,244,480 bytes, with normal pressure/AC/zero swap. A fresh retry completed in4.57 seconds and the physical comparison passed. Both attempts and the memory-preparation receipt are retained.

Evidence: `../gemma4-mtp-remote-qualification-physical-v3-20260920/cases/tiny-2/physical-result.json`, SHA256 `2cc6a235bef4e6522983920e28e4fae5a15598c8c1f7a9ec87bd93b2b0bda4e2`. This clears the tiny transport prerequisite; it establishes no assistant-model speedup or encrypted serving qualification.


## Correct local MTP: actual generation results

The explicit serial-head dense policy is now compiled and exercised in actual local MTP (native5db4b221, sourcec8688c2d). Both depths passed full same-build ordinary comparisons: each read and compared four complete final vocabulary rows,360 final cache components and64 generated IDs exactly. These are actual autonomous drafting/verification runs, in addition to the earlier forced-input tests. Original resource/physical comparisons passed.

P128/C64/O16, one warmup and three measured requests:

| Mode | Prefill tokens/s | Decode tokens/s | Draft acceptance per request |
|---|---:|---:|---:|
| Solo, MTP off |393.42|60.24|—|
| Local MTP depth1, corrected dense/serial head |392.76|57.50|5/8|
| Local MTP depth2, corrected dense/serial head |392.64|50.25|6/14|

No speedup has been achieved. Full comparisons: `local-dense-d1-numerical-actual-1/comparison.json` and `local-dense-d2-numerical-actual-1/comparison.json`; retained phase summary: `local-dense-phase-summary.json`. The exact resource-name binder correction preserved both required resource identities and rejected altered/duplicated entries; its three CPU controls passed.

A separate packed-head policy also passed the actual same-build forced-input24-row/360-state comparison on5db4b221: `harness-target-width-packed-head-v1/cases/p128-packed-head-width-controls-1/comparison.json`. It reuses packed output-head weights across2/3 rows with the same M1 arithmetic, preserves ordinary/M1 paths, and retains every prior resource charge. This qualification is not yet a measured MTP performance result.


## Actual remote assistant inference and exact numerical pass

The first actual full-model two-Mac pull run completed with target on48GB and assistant on24GB (native5db4b221, P128/C64/O16, depth2, serial output head). Three measured requests reached **25.5487 decode tokens/s**, compared with same-build ordinary60.2358 and local depth2 50.2456. Prefill was about394 tokens/s. Each request accepted6/14 offered draft tokens, generated27 assistant candidates including discarded work, and reused two lookahead proposals. All original resource, ownership, peer retirement and alias restoration checks passed. This is plaintext private RDMA and is slower than solo.

Full retained numerical replay now passes: all64 generated IDs, four complete final262144-value rows and360 cache components (128,860,640 bytes) match ordinary exactly. Evidence: `remote-dense-numerical-actual-2/comparison.json`; physical evidence: `../gemma4-mtp-remote-dense-physical-v3-20260920/cases/p128-remote-dense-capture-1/physical-result.json`. The prior comparator stopped before sidecar reads on a declared-empty package initializer; its successor changes only that declared-empty read policy, preserving size/hash and all numeric checks. Six focused metadata controls passed. Full replay child74304 exited0 naturally and was reaped with its process group absent in6.77 seconds.

Packed-head generation activation compiled as native49d48bde/source9b6f354f. Same-build solo measured61.3012 decode and390.3806 prefill tokens/s. The first packed local depth1 attempt refused before weights executed because actual free27,810,856,960 bytes was below the unchanged28,326,502,832-byte startup requirement. Both the failed process and lease retired. Authorized cache-only preparation raised free memory to33,488,109,568 bytes, normal pressure/AC/zero swap. Fresh cases are pending; no packed-head generation speedup is yet established.

Additional CPU checks actually passed:13 fresh-observation chronology groups,26 remote-depth protocol groups (including eight depth1 additions), and eight bounded output128 envelope groups. These source successors are not yet in an actual native build; they establish no model, transport or performance claim.


## Packed output-head generation: actual results

On native49d48bde, P128/C64/O16 local depth1 measured57.8498 and depth2 50.7078 decode tokens/s; same-build solo measured61.3012. Both full numerical comparisons passed all four final rows,360 state components and64 token IDs exactly. These results are only small changes from serial-head generation and remain slower than solo. Per-request depth1 was52.50,60.88,61.03; report the full measured aggregate, not the best sample. All original resource/process comparisons passed. Evidence: `local-packed-d1-numerical-actual-1/comparison.json`, `local-packed-d2-numerical-actual-1/comparison.json`, and `local-packed-phase-summary.json`.


## Bounded control-path successor built

The combined121-file source2e5d0419 compiled as natived3d0cfaf in53.77seconds (originalcompiler74609 exited0 naturally/reaped/group absent). It combines invocation-scoped assistant observation sharing, fixed16KiB control entry/exit resource observations with inner lifetime/native checks, explicit remote verification depth1/2, and bounded full-mode output128. All prior floors, reserves, snapshot transfer cadence and original native completion fences remain. CPU execution passed17 control-operation and6 counter-chronology groups,13 fresh-observation groups,26 protocol/depth groups and8 output-envelope groups. Source review independently replayed all121 output pins.

This build is not yet physically measured. The old tiny qualifier uses the default control path and cannot qualify the new callback cadence; actual remote inference and full same-build numerical replay remain required. No faster-than-solo claim.


## Actual optimized remote control and depth1/2 results

Native d3d0cfaf/source2e5d actually completed both P128/C64/O16 remote depths with the new control cadence. Matched ordinary was61.7055 decode tokens/s; remote depth1 reached41.3613 and depth2 38.4714, versus prior serial-head/depth2 remote25.5487. Depth2 is a50.6% improvement over the earlier remote configuration; neither depth beats solo. Depth1 accepted5/8 and depth2 accepted6/14 offered drafts per measured request. Both complete numerical replays passed all64 IDs, four complete final rows and360 state components exactly against same-build ordinary. Evidence: `remote-control-{d1,d2}-o16-numerical-actual-1/comparison.json`. All original physical resource, native ownership, same lease inode, peer retirement and alias restoration checks passed.

The actual depth1 report has396 completed fixed control operations per member (198 send/198 receive),396 fresh entry checks,396 fresh exit checks and2970 inner lifetime checks; depth2 has388 completed operations and2910 inner checks. The report keeps unchanged snapshot cadence/native fences and no resource-value cache across operations. These actual reports qualify this private test's control cadence; plaintext remains explicit.

The first O128 native metadata call refused before inference: Gemma4BenchmarkResourceBudget still required output16 and capacityP+16, despite the earlier input gates. Original native93264 exited1 naturally/reaped/group absent; witness `mtp-o128-native-metadata-failure-1`. The narrow675f correction reuses the closed output envelope and capacityP+outputCount; all following allocation formulas are byte-identical and already derive sizes from maximumTokens. It is combined with bounded per-window timers and structural verification-total caching in source9c764084 (122files). Seven timer and six structural owner-transition controls passed; the latter use explicit metadata doubles and establish no actual allocator/OS claim. The new native build is in progress; O128 remains physically unqualified.


## Actual per-window profiling and second O128 metadata issue

Native5e840fa5/source9c764084 built successfully in255.02seconds after a full dependency rebuild. Same-build O16 solo measured61.3930 decode tokens/s, remote depth1 40.7335. Structural sum caching did not yield a material measured improvement. Full numerical replay again passed four complete rows,360 cache components and64 IDs exactly: `remote-measurement-d1-o16-numerical-actual-1/comparison.json`. The strict new window timings and request/global control-count joins also passed physically.

The measured bottleneck is exposed assistant reset/refill. A maintained-branch window is about25.7ms versus45–46ms for many reset windows. Individual reseeds cost about10ms, and initial proposal fill after reseed often costs9ms. These are target-process wall phases, not pure wire or independently measured assistant GPU time. All measured aggregate phases are in `remote-measurement-d1-phase-summary.json`.

Second O128 preflight failed before model execution because ordinary description() still tried to derive stage0 and stage1 budgets after the full budget. Those staged O128 workloads correctly remain forbidden. **The request dtype chain was correct; the earlier suspected dtype mismatch was disproved.** Witness `mtp-o128-native-metadata-failure-2` retains native95117 natural1/reaped/groupAbsent. The minimal ba368a85 correction changes only which diagnostic targets are described: O16 still allthree, O128 only its admitted full target. Nine focused Foundation controls passed; sourcec7216fb6 is in the new build. O128 physical execution remains pending.

## First actual output128 baseline

The description-only correction built as native54b2809e/sourcec7216fb6 in55.43seconds; original compiler76646 exited0 naturally and was reaped with its group absent. Seven v3 harness controls passed. Actual O128 native metadata now passes with the full target alone; no dtype, budget, floor or inference change was needed for this second correction.

P128/C64/O128 ordinary solo completed one warmup and three measured requests: **61.6844 decode tokens/s**,393.2420 prefill tokens/s. The aggregate counts381 decode tokens over6.176603seconds. Original physical resource, process retirement and lease checks passed. Evidence: `harness-local-mtp-o128-v3/cases/p128-o128-solo-capture-1/comparison.json`. Matched local and remote MTP runs and their complete numerical comparisons remain pending; this baseline establishes no distributed speedup.

To retain room for longer evidence, six completed deployment transport archives were removed only after every regular archive member was hashed against its retained deployment file and installation receipts were verified. This reclaimed1,394,319,360bytes; all source, binaries, resources and benchmark evidence remain. Details: `transport-archive-cleanup-4.json`.


## Output128 local MTP: exact and faster than ordinary solo

Same-build P128/C64/O128 local depth1 reached **70.8096 decode tokens/s** and389.8026 prefill tokens/s, versus ordinary61.6844/393.2420. This is a14.79% decode improvement on one Mac. All three measured requests accepted59/66 offered drafts. Full replay passed512 generated IDs, four complete final vocabulary rows and360 state components (229,786,080bytes) exactly against ordinary. Reader77090 completed naturally in11.41seconds, exited0/reaped/group absent; original physical resource/retirement comparisons passed. Evidence: `local-d1-o128-numerical-actual-1/comparison.json`.

This raises the current best solo baseline to70.8096; a two-Mac result must exceed the best matched solo mode. It establishes neither a distributed win nor a multi-prompt or long-context performance qualification. Local depth2 and remote output128 are pending.


## Matched output128 cohort: best solo remains ahead

Native54b2809e/sourcec7216fb6, P128/C64/O128, one warmup and three measured requests, greedy and the same registered4-bit target:

| Mode | Prefill tokens/s | Decode tokens/s | Accepted/offered drafts per measured request |
|---|---:|---:|---:|
| Ordinary solo |393.2420|61.6844|—|
| Local MTP depth1 |389.8026|70.8096|59/66|
| Local MTP depth2 |391.4128|79.7598|80/90|
| Remote MTP depth1 |393.1663|61.1324|58/67|
| Remote MTP depth2 |392.0366|66.1892|80/90|

Both local depths and both remote depths passed separate complete same-build ordinary numerical comparisons: each512 IDs, four full262144-value rows and360 cache components, all exact. All physical resource/process/lease checks passed; both remote runs restored the Thunderbolt alias. Numerical readers77090/77220/77157/77301 exited0 naturally, reaped/group absent, each about11.4seconds. Evidence: `{local,remote}-d{1,2}-o128-numerical-actual-1/comparison.json`. The best solo79.7598 is29.3% above ordinary; remote66.1892 exceeds ordinary but is17.0% below best solo. **No faster-than-best-solo cluster result.**

Remote depth2 disjoint cost per decode token: target10.3442ms, exposed fill1.92394ms, reseed1.31983ms, reconcile0.50482ms, lookahead grant0.27578ms, drain0.20994ms, resolve ACK0.20398ms, selection0.16103ms, branch retirement0.09726ms, other0.06073ms and finish0.00669ms. Target execution9.90891ms and admission0.40425ms are included inside target, not added again. Both depths reset15 times per request. Full scalar evidence: `o128-remote-phase-summary.json`.

Source audit identifies a depth2 replenishment deficit: two ready plus two background proposals minus the two accepted drafts and bonus bridge leaves only one ready. The next depth2 window must fill again. An explicit three-credit policy implemented as separately fenced2+1 native batches is being designed; it has not been compiled or physically qualified. The depth1-only single-refill source and12 Python controls passed, but its model experiment is deferred because current depth2 is the competitive mode.

Twelve snapshot batch Foundation controls passed on the actual policy/progress source (compiler77338 and checks77343, natural0/reaped/group absent). The exact124-file batch candidate7bc10191 is applied and building. It retains seven ordered tensor transfers and every CPU completion while moving intermediate GPU waits to explicit batch boundaries; fresh guards, roots and budgets remain. Tiny actual-JACCL qualification and model numerical/performance comparisons remain required.

Seventeen additional completed collection-tar duplicates were removed after every member matched retained extracted evidence byte-for-byte, reclaiming3,107,051,520bytes. All evidence content remains; failed cases remain. Receipt: `transport-archive-cleanup-5.json`.
