# Distributed cluster delivery — current handoff

Updated 2026-09-15 20:03 UTC. Goal remains ACTIVE, no token budget. User explicitly
required plan first: reviewed plan is done and ordered execution has resumed.

## Requirements and authoritative plan

Read repository docs/design/distributed-cluster-delivery.md and
 distributed-cluster-execution-plan.md. Build reusable opt-in Darkbloom cluster
inference on actual24/48GB M4Pro pair overTB5/RDMA. Start registered9B4bit,
then Qwen3.8 27B4bit then Gemma4 26BQAT4bit. Prefill/externalTTFT first,
MTPoff/on with actual engagement and128requested outputs. SLA from request send
is10s+1ms/prompttoken (8192=>18.192s), per-request misses pluspercentiles.
M3Ultra800/1000TPS remains projection, not measured gate/hardware blocker.

Repository /Users/developer/DarkbloomDev/d-inference, feat/cluster-inference HEAD
605651bb95d71c1da9bb122107925143e9441973. Latestmaster fast-forward merge DONE,
localwork preserved; backup pre-master-refresh-20260915 and stash retained.
No production deploy/push. User full access permits setup/tests. Root owns
SSH/network/GPU/heavySwiftbuilds; agents source/CPU only. Do not weaken6GiB
actualfree/zero-swap/AC/pressure guards or resetbridge/interfaces/reboot.

## Machines

SSH aliases darkbloom-24 (developer@192.0.2.250) and darkbloom-48
(developer@192.0.2.223). Both M4Pro14CPU20GPU,24/48GB. Keys and12hControlPersist
already configured. Password private0600 machines/CREDENTIALS.private.md,
parse password header; never print it or put inargv. LocalM4Max36GB.
Bothonline. TB5 en1/rdma_en1 active. Physical tests need bounded exact48
169.254.70.47/32 alias lease; all4attempts removed it/verified bridge+management.
No active remote worker/alias now. Exo GUI2115 and exactbackgroundworkers2169,
2186 were stoppedon24 for benchmark; do not restart during tests. Otherapps
andOSservices leftalone. Purge24 credential works, no admin question needed.

## Completed current implementation and evidence

1. Real48GB resident solo9B cohort PASSED: one load, excludedwarmup,three fresh
8K/512/B1/output1/MTPoff measured18.547385417/18.546285208/18.559176250s.
Median441.68TPS. All4reference comparisons and7events accepted, shutdown0,
resourcesmin8.6383GiB,swap0,cache0 final. Engine timing only, repeateddiagnostic
prompt; notexternalTTFT/representative/fastestsolo/physical qualification.
Evidence returned-resident-solo-aa7d-20260915; summary resident-solo-aa7d-summary-
20260915.json; publicreport docs/reports/2026-09-15-cluster-resident-solo-baseline.md.

2. Native resident JACCL7b4ae5d707fab11a3b9d410fbe948ca8f62f7768a4465fb1fecb747f74a5551e
built/tested/deployed both resident-jaccl-runtime-20260915.425sourcesnapshot
28172c792400853e1abe745c3e71f69ff68d59dd908b61f16325c98fddef737d,
434memberpackagec33f6888a7ca01693e8bc291f0174cc45d6bcb4fc5065afd4e761956c6757255,
bundle59049b46d88119e11724866a3cdb44254e2ac4bfcb26c9880b3d2adb10f3b211.
Build286s,workerCPU6groups passed,adapter41 byteidentical.27compiled Swiftfiles
promotedmainrepo; Package.resolved/publicbuild.sh preserved. Originalaa7d/c079
workspaces/packages/binaries/evidence unchanged.

3. PhysicalV2launcher frozen resident-physical-integration-v2-20260915,
53members,manifest26ba0db54ae9a9441620160de0a6c3600f5a05eaf787380e6b8281a7f3a393a3,
17CPUtests passed, deployed both. Physicalcut12/20 serial8K/512/1 fixed4requests.
V1 rejected native JACCLretry stderr; V2 source-boundrank1 ordered0..3 retries
1000/2000/4000/8000ms onlybeforeReady,rawstderrretained,allotherstderrstrict.
No launcher change needed for newnative pin/package members; accepts planpins.

4. Fourphysical attempts, NONEranrequests. Attempt1 startupretry rejection;
2,3,4 rank0 actualfreefloor duringload,rank1Ready. Attempt4 nativeprelaunch
8.905GiB=>5.247GiB inload; loadedanon+2.184GB,filebacked+1.719GB. Afterkillanon
returnedwithin3MB,filebacked+1.751GBremained. Bothremoteleaders-9reaped/fenced,
zero remote cleanup errors, aliases restored eachtime. Attempt4 localSSH
killpg33648 EPERM secondary retained; laterread-onlybothlocalgroupsabsent.
XNU zombie-onlygroupexplainsplausibly, notexactobservedcause. Do not rewriteerror.
Evidence resident-physical-attempt4-cut12-20260915, aliasreceipt37e337c0aff7ec9d20c9df55d19b7d74e8242f34711e267e90616e87beaf26ec.
Olderattempt2=v2,3=attempt3 dirs. No physicalmodel TPS claim.

5. Root isolatedselectedpayload-cachefix: resident-payload-cache-build-20260915.
Fourfiles,426snapshot894d27fe66b4b370af46d4c7490a5d3f4624947bd5da8a9825e88b30c6f2a05f.
VerifiedCheckpoint ownedFDopt-inF_NOCACHE, rehashpreservespolicy; selectedstage
materializerinvokesbeforepayloadreads; full-reference/defaultscachedunchanged.
No tensor/math/admission/resource/wirechange. TinyactualCPUfilecheck appended
adapterchecks. Independentreview no blocker, source-review receipt under
resident-payload-cache-review-20260915. Memorysourceaudit confirmsselected
rank0 bytes2,032,294,848,348tensors,largest508,559,360; nofullmodel eval/mmap.
BuildACTIVEroot session72231, logsrecords/build-1.{stdout,stderr}.log.
Recipe prepare_payload_cache_package_20260915.py PREPARED NOTRUN, requiresbuild
success. NextCPUchecks, packagebothpeers,newattempt5plan/nativepins, freshpurge,
boundedaliasrun. Do not repeatoldnativeattempts or lowerfloor.

6. Externalstreamingclient inpublicscripts/benchmarks benchmark_streaming.py,
streaming_latency.py,test_streaming_latency.py. Explicitendpoint+exactrequest,
authenvonly, actualSSEtext clock, reasoning/contentseparate, rawarrivals,
absolute timeout, actual/declaredpromptSLAs, failedrequestneverpass.10tests
passed,Python3.9syntax/docschecks/diffpassed. No actualproviderAPIrunyet.

7. ProviderCore/Inference/Distributed adapter fivefiles,tests3files20methods,
sourcehandoff-v2 SHA484e4b666919faaebe8d5195e57bebb5df94027661670818d6e68cda2aba645b.
Injectsexclusiveowner/lease, modelprofilelimits, readinessidentityepoch,
perpeerreserve, committedtokens, deadlines/cancel/peerloss/retirementheldresources.
ExistingEngineV2Bridgefactory, NOproductionwiring/realbackendyet. Firstcompile
failed self.actionshadow fixed. NormalEOS/lengthnowcleanfinishfalsecallback,
notabnormalleasecancel. Second Swift test PASSED all20 tests/2suites, build164.57s/total169s;
logsdistributed-provider-adapter-20260915/swift-test-2.*. All8sourcepins reverified.

## Parallel agents and immediate next work

arithmetic_audit now source-onlynormalSwiftbuild sharedlibraryintegration map;
canreviewgeneration. pipeline_stage_plan implementingconfigurablegeneration
admission/schedule/wire/control+Sessionseams inresident-generation-build-20260915,
6newfiles plusadditivechanges; no.forward/state mathchange.8192/512/128 derives
16prefill+127decodeframes,capacity8320,lastfrontier8319. Bothframecommit/tokenACK/
continueorstopACK/cleanretiregates. CPUfixturespending. ActualnativeCollective
runner and providerlease stillneedhookup. Rootownsnextcompile.

Do not claim framework finished from interfaces/receipts. Priority next real
physical9B correctness, then multi-tokencontinuation/liveproviderowner+endpoint,
then overlap/balance/profile and MTP transactions perplan. CLItrust/config,
model27B/Gemma, qualification, externalroute andM3projection remainunfinished.

## Retained reference and resources

9B modelboth /Users/developer/DarkbloomDev/models/Qwen3.5-9B. Artifact127de76b4ef82b7aaa0acaac0ee31c784cff066eda64291f521f051469b7c24b;
configurationc8e767de4953e58352fbc1acbf6615329075ed02fe16a36b8065714d85ee4423;
manifest4f2735026cc7b40ee2c886ee53fb8755816c0001c4c69c141a61d5f56ff22aa4.
Independentfull8Kreference runs/qwen-long-prefill-reference-peer24-20260914:
stdoutda85eb1e79a43c16575e6a8ffd48594ccb72306c16543a1e02c24903b89c154a,
promptee6caf0be6391e00ec41df930f0fd6351613969622cbb247b1b4bdaf69afe997,
BF16logit4dea769bd622b97b34a914e2c488ffe599701884561f1a42b1d4ee9dfde6dfe6,
argmax271,72statecomponents319946784B. Originalreference7f779/266sources,oracle
frozenafterreferencebeforecandidate. Candidatehashonly;8offsetdigestsreconstruct,
64stateopaque. Ten8192token DEVELOPMENTprompts prepared, separatequalification
and perpromptreference notyet. NoactualMTP/distributed27B/Gemmaresult.
