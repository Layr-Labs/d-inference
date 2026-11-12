# Cluster delivery checkpoint

Updated UTC: 20260917_024925. The full previous checkpoint is preserved verbatim in
[CLUSTER_DELIVERY_HISTORY_20260917_023458.md](CLUSTER_DELIVERY_HISTORY_20260917_023458.md), SHA-256 692cdf3538a42427f0b1dc4c4a51f1edb09a7814429985f78865ab14e1580663.
This file describes current state; historical LIVE entries in the archive are stale.

## Goal and authority

Continue the user's distributed Darkbloom goal. Latest user asks where we left off;
root answered in commentary and continued work. Full development/SSH authority
persists. There is no user-action blocker. The goal API still carries `blocked`;
it exposes no resume operation. Do not create a replacement or mark this unfinished
goal complete. No production deployment, push or release has occurred.

Ship a reusable opt-in framework for trusted, verified/routable Macs. Prioritize
prefill and external send-to-first-content TTFT: 10 s + 1 ms/input token (8K =
18.192 s). First9B4bit, then registered27B/Gemma4 26B4bit,35B follow-on. Compare
MTP off/on only when actually active. Calibrate compute/memory/transport; support
model adapters and eventually tensor/expert/hybrid placement. Authenticate/encrypt
traffic between trusted Macs. Two M3 Ultras256GB800/1000TPS are unmeasured targets.

## Actual live ownership

- Root owns sole compiler: member+B Swift tests session56188 in fresh
  `coordinator-native-pair-swift-build-1-20260916`, reviewed wrapper9a33d47e/21.
  Preparation96334 PASS:4APFS copies0/reaped/groupsabsent,13813base→13821candidate,
  27overlays, old path-bound ModuleCache retained, MAIN unchanged.900s/jobs2.
  Rootreview `coordinator-native-pair-root-review-20260916/swift-wrapper-review.json`.
- No native or remote job remains. Allocation35 physical44055 and prior27B61818
  fully retired.48GB allocation counterpart is not copied or run yet.
- arithmetic_audit completed phase-only candidate7f8f67a9/54members/18Swiftfiles,
  11sourcechecksPASS, nofixtures/compiler. Source under
  `resident-generation-phase-native-draft-20260916`; CPUchecks→prepare→build→package
  exactcommands.json b07805a0. Both ordinary wrappers/core remain qualified c35c,
  actual phase reservation/resource/identity, fixed256KiB host writer, post-retire
  export before capacity restoration. Transport agent now independentread-onlyaudit.
  Arithmetic now prepares48GB source-only allocation supervisor counterpart and
  explicit resource-scope assessment. No compiler/remote/materialization grant.
- pipeline_stage_plan diagnosed Gemma dtype mismatch and prepares a narrow explicit
  safetensors-to-native projection correction; driver expansion paused for this.
  Frozen92a7forward/a7d2resource owner and both failed fixtures remain immutable.
  Foundation90202 compiledPASS3.510s, fixture35325-5/reaped/groupAbsent3.628s.
  Diagnostic01e8eb0c/55073 compiledPASS3.741s, fixture35604-5/reaped/groupAbsent3.587s.
  Actual1912arrays/1,658,991,464B vs expected2564/4,813,046,632B:652cast arrays absent.
  Layout preserves BF16/F16/U32; budget/selection/source/model/materializer compared
  native float16/bfloat16/uint32 spelling. No Gemma weights/model have executed.
  Evidence `gemma4-short-resource-root-review-20260916/foundation-{1,diagnostic-1}`.
- Transport completed source-only Swift wrapper9a33 above; independent audit of
  phase candidate7f8f67a9 now active. No compiler/remote grant.

## New coordinator and encrypted-buffer qualification

- Corrected B Go wrapper3a21, fresh `coordinator-native-pair-go-build-2-20260916`:
  focused42240 PASS35methods/18.444574s, child34774 natural0/reaped/groupAbsent.
  Full2420 PASS2790methods/3ordinaryskips/exact2793compiledentries covered once.
  Registry1067/protocol111/API1615; API batches404/404/404/403. Sixownedchildren
  natural0/reaped/groupAbsent/no-kill, allsourcepins unchanged. Source7044e32d1114.
  checks ff61e24fe4753e940c2465b3d153b4ee32c769e23d091b14d73b68724cd176db;
  root raw/owned receipts review `go-all-1/root-review.json`. B Swift pendingabove.
- Allocation native59481 PASS219.712s/all4steps0/reaped/groupsAbsent/catalog35.
  Native4f4149c7330d8268ac7294ef7b225db25078d2fb853cb06af1d02e73ae66b26c,44782072B;
  receipt7dda3ec17f122faf31e38d93152f3283a645d0444c920644421655f6a5e2566a.
  Package91492 PASS,e3ff82761600ab47921f78a43ee5416fb521bbcffcdd1bcaf446b75d7d16f7d2.
- Allocation source supervisorab74a969/39members:rootreadchangedsources and verified
  39members/7exacthelpers/15pins;4actualCPUreport-controlsPASS. Bindingef0a51f2,
  package2634d9b21ec4affe10a46b7ef45eab3774a8cf28d3bedba67e78f225c28a96b0,
  deployed onlyto24newroot `/Users/developer/DarkbloomDev/collective-native-allocation-check-20260916`.
  Copy58660PASS6.96s;firstscalar80591PASS;remaining34serial44055PASS.
  All35distinctnativePIDs/130rawresources/reaped/groupsabsent/completeEOF/
  sameemptycanonicaljournal. Maxnative20,987,904B; maxphysical71,532,640B;
  minimumactualfree11,657,560,064B.35cases include success,reuse,tamper/cancel/bounds.
  Rootaggregate `collective-native-allocation-root-review-20260916/physical-24-review.json`
  SHA14e970b06fc03dfff941c68d6998bc92ffac1b2478f32aea869a2fcfc3e291fe.
  Scope:both codec endpoints plus native staging in one process, in-memoryciphertext
  mailbox. This is not RDMA/group/model/key-handshake execution, a proven per-rank
  serving bound or an enabled profile. Keepfullobservedphysicalincrement; do not
  subtractnativebytes. Concurrent directions/domain/session cost need integration.

## New accepted 27B results

Workload: exact8192prompt/C512/O128/emptyStops/BF16greedy/MTPoff/fresh state.
Both results contain one excluded warmup and ONE measured request, not a repeated
cohort aggregate. No27B external HTTP or encrypted-RDMA measurement.

| Case | Prefill TPS | Internal first token | Decode TPS |
|---|---:|---:|---:|
| Optimized solo48GB |126.625344217|64.694789583s|12.425678047|
| Distributed16/48lookahead |164.896184659|49.679742542s|10.360252562|

Observed rate ratio~1.30; clocks differ: solo native selection vs controller
owner-control/transport/delivery. Both exclude load/reservation; decode counts127
continuations. All128IDs equal in BOTH requests of each case. Earlier full-row/
144state correctness is separate. This is whole-layer pipeline/chunk overlap,
not tensor or expert parallelism. Current27B is outside18.192s8Kdeadline.

- Solo: `qwen27b-solo-report-bound-v2-draft-20260916/physical-source/run-1`.
  run69926PASS168.414s; native53f5b5a8, complete618rawresources,
  min13,895,909,376B; sample35445a84c946eb10f36346a640b28c34df7b116a3b0986f638f11ca824028e50.
  Two follow-up jobs are source-reviewed under `followup-cohorts`eb197159;
  create-onlyprepare_jobs.py thenpurge/run/collect/validate2and3, not executed.
- Distributed: `qwen27b-matched-short-cohort-draft-20260916/distributed/lookahead-1/physical-1`.
  run61818PASS145.314632s; root-review820578ae4acc5435a8d525fede336779cfe2525ed309c68b2576eb5442c39cca;
  executionb10be7fa225afdff3751acee7f02bce78870c8a22b036c78544132debe6b13b9.
  499+505rawresources rechecked; min6,551,617,536/18,928,107,520B, zeroSwap/AC/p1.
  Both native cleanup/ownerACK/process absence/journal emptiness/alias restoration
  pass. Controller0/reaped/groupAbsent/sourceunchanged. Diagnostic EOF completeness
  and another full-row/state comparison are not claimed by this timing controller.
- Cut32: `qwen27b-cut32-resource-pilot-20260916/physical-1/root-review.json`.
  17248FAILED initial admission before0/923weights; free12,830,228,480B versus
  required13,165,129,827B (deficit334,901,347B). Both workers cleanup/aliasrestorePASS.
  No unchanged32 retry. The successful16/48timing has only109,166,592B sampled
  headroom above6GiB on24GB: addinglayers alone is not established feasible.
- Distributed timing parent4bc3f946 fully artifact-checked. Both14filelookahead
  trees deployed at `/Users/developer/DarkbloomDev/qwen27b-8k-lookahead-timing-20260915`.
  Serial tree not deployed. Short35f845 configs serial/lookahead1/2/3 ready;
  onlylookahead1executed. Do not use old4-request parent config or aggregate one
  sample as three. Source-only8aggregationtestsPASS. Original preflight requires
  empty evidence; do not rerun blindly against now-populated lookahead tree.

## Other accepted milestones

- 9B: distributed814.423 vs optimizedsolo439.851prefillTPS (1.8516x); decode24.683
  vs37.679. One external8K first content10.503s. No p95/fleet/SLA qualification.
- 27B correctness16/48serial+lookahead:128IDs/full496640BF16row/144states/front8319
  match fullreference1922793; lookaheadcomparison92ca6700. Parent elapsed is notTPS.
- Gemma/shared-state GPU: retry2511a7d7; window21/session15/target7 =43groupsPASS,
  cleanup/sourcechecksPASS. Actual mixed full/window state and tinyQwen/arrays,
  NOT registeredGemma fullforward/EP or realassistant MTP. Evidence in
  `gemma4-windowed-state-retry-draft-20260916/physical-collect-{window,session,target}-2`.
- Native key prelude A: actualCPU28groups/35childrenPASS;11commands0/reaped/groups
  absent. `cluster-native-key-prelude-validation-3-20260916/checks-1/checks.json`
  39e10340e16caee55d67c0e7b0faa3e4225833118ae69a02f1dce09189b148f4.
  Includes native-onlyX25519/HKDF/HMAC/context/PID/mesh/cancel/replay and independent
  OpenSSL. One-lineMirror tuple label fix + test vector/receipt filename fix
  preserved alongside original failures. Not MAIN, no encryptedRDMA invocation.
- MAIN already contains CLI/lifecycle/quota foundations, verified pair reservation
  (15focused/1051registryracePASS),8Security+2bytebridge/P2P/Package and4native tail
  clears. AES256GCM40Bframing. CPU5MiBseal+open1.23–1.26ms; end-to-end encryption
  overhead unmeasured. Protectedfacade4338ce5b memorypolicy still refuses until
  actual measured resource catalog/integration. No realMTPspeedup accepted.

## Registered members and coordinator native authorization

- Frozen member overlay4ae431c6:40files30replace10new; not MAIN. Negotiated
  control-onlymember role, inventory separate from solo models, nonce/deadline/
  reconnect-loss handling, anonymous metallib binder. Actual Swift CLI/test build
  stillpending. 27B ordinaryM5/NAX gate remains; neverfakecapabilities/renamemodel.
- Corrected member wrapper0550d8fb preparedbuild-2 with1096files. Focused4634PASS
  19methods/18.429652416s, realGo0/reaped/groupAbsent, pinsunchanged.
- Full29439 FAILED184.056379542s, naturalGo1/reaped/groupAbsent/pinsunchanged.
  Registry1054/protocol109PASS; API1079PASS but missing realProviderCore.swift
  fails version-sync test and180s packagealarm leaves14active+unstartedtests.
  Root failure5ded1907241c63361e73746fb1c537e9e1eb741b179eb3e1b0461a2bb538a79f
  in `cluster-registered-member-go-build-2-20260916/go-all-1/root-failure-review.json`.
  No established product regression from this run. Actual sourceversionsboth0.9.4.
- Root audited selectedGo test external reads: add3fixtures to prior5:
  ProviderCore/ProviderCore.swift, ProviderCore/Telemetry/TelemetryEvent.swift,
  console-ui/src/lib/telemetry-types.ts. Last2otherwise skip parity ifmissing.
  New wrapper must retain all8exactreal inputs. Do NOT rerun0550/7622 full suite.
- B original69189730/all38/22productfiles reviewedroot+arithmetic. Atomic real
  RegistryReserve/Commitbeforestart, exactTLS/SEsignedconnection/seq, immutable
  explicitnativecatalog, boundedpublicrelay, actualcleanup-onlyrelease.
- Arithmetic found pending-cancel reuse race. Correction4339ee60/all9 adds2runtime
  overrides +deterministicactualwriterfixture. Reuse waits for joinedwriters AND
  bothcancelenqueue/closeattempts. Rootreviewd7342d3f and independent695bf3dc PASS
  source-only. Original finding600fa419 preserved. No compiler/testofB yet.
- B wrapper7622fa3f/19 is preserved but incomplete8fixture inventory. Transport
  creates successor: member → B → correction, complete1114expectedsourceinputs,
  focused120s → compiledTest/Example/Fuzz discovery → registry/protocolfull +4
  exhaustiveAPIbatches under180s/package/300s ownedchild. Verify exact disjoint
  coverage, ordinaryexplicit skips, and16NativePair+15VerifiedPair+4memberPASS;
  no dropped tests, no arbitrary timeout increase, no productassertionchanges.
- Remaining: member actual approved-file/native-owner prelude invocation,
  trusted selector/caller policy, explicit productionTLSproxy trust, protected
  Collective resource/budget integration and actual encryptedtwo-rank requests.

## Machines, safety and repository

BothMac16,7 M4Pro14CPU/20GPU, macOS27build26A428;24GB darkbloom-24
(developer@192.0.2.250),48GB darkbloom-48(developer@192.0.2.223). Bothreachable through
lastphysical cleanup. SSHkeys/persistentmasters installed; use strictknownhosts,
`-S none` forlargecommands. Secrets only in0600
`/Users/developer/DarkbloomDev/machines/CREDENTIALS.private.md`; neverprint orpassinargv.
Knownhosts: `owner-ssh-preflight-20260915/known_hosts` (89a73d7c).
Canonicaldevicejournalboth`~/.darkbloom/cluster-device/native-device.lease`.

Keep one compiler/materialization slot/jobs2, none during physicaltiming/bulkI/O.
Local36GBM4Max remainsoffGPU. Native actualfree>=6GiB/zeroSwap/AC/normalpressure;
noappsclosed/reboots/interfacesreset.48temporaryTB169.254.70.47/32alias<=600s,
restoreafteractualworker/owner/process/journalcleanup. Sourceonlyparallelworkokay.

Repo `/Users/developer/DarkbloomDev/d-inference`, branchfeat/cluster-inference,
HEAD/refreshedmaster605651bb95d71c1da9bb122107925143e9441973, intentionaldirtytree.
Readroot/docsAGENTS; frozenreports/designbodies unchangedexceptStatus. No vendor
upstreampush/PR/comments. Followexactstoredpreimages beforefutureintegration.
Newpublic report `docs/reports/2026-09-16-cluster-delivery-progress.md`, indexed;
deliveryStatusupdated. docs-check97826PASS320files; gitdiff--checkPASS.

## Next concrete operations

1. Follow90202 Gemma34-source Foundation actual terminal; preserve failures.
   Corrected B wrapper3a21 focused35/full2790PASS with complete2793coverage.
2. Bind reviewed allocation35physical wrapper, run only after compiler release; verify
   actual rawresources/cleanup and derive explicit observedprofile. Run source-
   reviewed Gemma34-source Foundation runner in the next free compiler slot.
   Then actualSwiftmember/B qualification
   and reviewed source integration. Do not claim compiledbeforeactualresults.
3. Review/qualify concrete27Bphaseobserver andGemma shortowner; nativecorrectness
   beforetiming. Obtain measured compute+transport+memoryinputs forplanner.
4. Complete repeated27Bsolo/distributedsamples, serialcontrol, actualMTP comparisons,
   fullGemma/EP/TP, encryptedRDMA, sustainedserving/lifecyclerotation andHTTP/SLA
   matrix. Keep M3Ultraestimates explicitlyprojections; nohardwareexists here.
