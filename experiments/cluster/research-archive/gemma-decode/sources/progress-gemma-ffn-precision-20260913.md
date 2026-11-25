# Gemma wider FFN checkpoint — 2026-09-13

Goal remains ACTIVE and unbounded. Previous turn classified as progress: it
finished actual Gemma/Qwen validation, confirmed interrupted process completion
and recorded BF16 divergence. This turn implemented and measured a candidate
that materially reduces that divergence; it did not qualify the full model or
the M3 Ultra prefill target. User's mid-turn "continue" was incorporated.

## Current implementation

Repository `/Users/developer/DarkbloomDev/d-inference`, branch `feat/cluster-inference`,
base `e4df336bc8399f4fd0a46d1207b594d2514f14f5`. Work uncommitted; no push/deploy.
Submodules unchanged. Public current report:
`experiments/cluster/inference/FFN_BRANCH_PRECISION.md`.

New `FFNBranchPrecision.swift` provides native/float32 arithmetic policy,
`FFNBranchCast` paired graph-construction dtype state, and `FFNBoundaryNorm`.
Gemma float32 policy widens AFTER each ordinary input RMSNorm, retains Float32
through whole dense/sparse branches and collective, casts once back BEFORE
each branch output RMSNorm. Router remains outside widened paths. Stored
parameter values/dtypes/shapes unchanged; existing quantized layer caches may
retain additional F32 metadata. It is NOT down-projection-only precision.

`GemmaReductions.swift` now attaches optional collective and precision jointly
through `attachGemmaExecution`. Solo attachment occurs in GemmaModelLoading;
TP attaches after rank agreement. Per-layer dense-before-sparse dependencies
and cast state clear during graph construction, with no cross-forward chain.
The partition fingerprint binds the policy. Qwen rejects nonnative FFN policy.

Current reports schema7, workers protocol3, required `ffnBranchPrecision` field.
Python `ffn_branch_precision` defaults native and forwards explicit CLI policy;
worker/one-shot identity validates model family, policy and peer agreement.
Native Report extracted from Main into focused Report.swift as refactor pass.

## Final build and checks

- Binary SHA256 `99d539d3400ab186be80e2bfe003d1db9f202fb95d5c8d56e9b49d956a0b325b`.
- Bundle manifest SHA256 `3582be53622b55acb943c6fabc4ed25b9fcfbd59c0a6fdde07076390351329d0`.
- Matrix source manifest SHA256 `0bb766e83d4ffeac67f3da3adb5d702e12f56a1977c46302d44294b9204182a5`.
  Core code rechecked unchanged; later README/report edits are documentation only.
- Final build log `gemma-ffn-precision-build-validated-20260913.log`, exit0.
- Pure adapter checks9166 accepted/26rejected, plus8storage malformed cases.
- Protocol3 fixtures4112accepted/93rejected, canonical SHA256
  `b709fcf9cba5a98f73de5a9625de47aa59d4cc70eb6e36c2bf57aed487c350de`.
- Operator suite71 emitted records passed, including exact F32/BF16 boundary
  comparisons/native storage addresses and existing operator regressions.
- Five invalid native precision configurations rejected before model construction.
-147 Python tests passed27.168s; all final source hashes still match receipt
  `runtime-ffn-precision-python-20260913.json`.
- Native Gemma persistent:4cohorts/12A-B-A requests+4freshoneshot controls pass.
- Native failures:solo/TPcancel reapsallworkers and retires epoch; prompt
  mismatch beforeaccepted, numericalpolicy mismatch beforeready.
- Qwen protocol3 regression:6cohorts/18requests+6freshoneshot controls pass.
- Initial fixture failures retained in log:short-pipe expectedoldv2, then norm
  test incorrectly required Swiftobjectidentity. Corrected latter checks the
  SAME underlying native buffer address and values; no numerical weakening.

Matrix driver and immutable sources/receipts:
`runs/gemma-ffn-precision-20260913` (40executions),
`runs/gemma-ffn-precision-workers-20260913`,
`runs/gemma-ffn-precision-failures-20260913`,
`runs/ffn-precision-qwen-regression-20260913`.

## Numerical result and limitations

BF16 paired native versus wider worstrowRMS:
mixed seeds7 .0601465→.0154485,31 .2281704→0,101 .2498618→0,211 .0369814→0;
W8 seeds7 .0368766→0,31 .0574347→0,101 .0377127→.0150698,211 .0321783→0.
Six ofeight wider BF16 pairs exactlymatch; all64argmaxrowsagree compared with
62/64native. Two cases still FAIL strictlogitbounds (maxabs.05858474/.05072674).
Wider solo departs from ordinary BF16 solo:worstrowRMS.0414–.2497, oneof64
argmaxrowschanges (mixedseed211). Matching ranks is NOT modelqualityproof.
Four wider F32 controls match archived nativeF32 logitsexactly and passbounds.
CurrentnativeBF16 seed7/31 results match priorbinaryexactly.

Alltesting is smallsynthetic weights onlocalM4Max, twolocalTCPloopbackprocesses.
No physical RDMA, M3Ultra benchmark, full26B weights, realquality, performance
benefit or productionCBv2 support verified. Additionalconstantcachememory and
Float32communication costsunmeasured atrealgeometry.

## Next work

Diagnose two remaining wider-policy divergences with per-layer Gemma norm and
router captures under identical histories, preserving actual arithmetic. The
post-reduction BF16 cast and subsequent routing amplification are hypotheses,
not proved causes. Do not force reference routes as an implementation fix or
loosen the numerical gate. If preserving F32 beyond the branch boundary is
tested, explicitly name that broader activation/state policy, inspect actual
attention/KV dtypes and memory, and compare its ordinary-solo departure too.
Avoid describing it as unchanged-model arithmetic.

Primary user goal remains registered denseQwen3.8 27B4-bit on2xM3Ultra256GB at
>=800uncached8KprefillTPS (1000stretch), with correctcontinuation, betterthan
besteligible solo, reusableQwenMoE/Gemma adapters and opt-inproduct integration.
Pending realhardware/performance/productrequirements remain in canonicalgoal.

Latestread-only48GBSSH probe timedout5s; no diagnosis ofpower/hang/network is
possiblefromthat alone. No network mutations, provider/service restarts or
sustained realmodelbenchmark. No nativejobsremain after sessions85721 and78029
completed exit0; build60439 also exited0. Docs-check session37384 completed
exit0 with280 documents OK. No sessions need resuming.

Agenttransport_probe implementedPython/contracts and performedread-onlySwift
review (nofatalissue;memorycaveatnoted). Other2agentscapacityerroredwithoutedits.
Rootsolebuild/GPUorchestrator throughout.
