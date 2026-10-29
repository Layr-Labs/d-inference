# Current distributed cluster delivery

Updated 2026-09-15 after user confirmed/refined the delivery contract.

The authoritative repository goal is
`d-inference/docs/design/distributed-cluster-delivery.md`; it supersedes the old
M3-Ultra-dependent completion criteria. Reusable framework delivery and measured
prefill on the existing 24/48 GB M4 Pro pair are primary. Test registered 9B
4-bit first, then Qwen3.8 27B 4-bit and Gemma4 26B 4-bit, with MTP off/on when
supported and active. Qwen35B remains follow-on scope. Ship cluster configuration
and distributed start in Darkbloom on both members. M3 Ultra 800/1000 TPS stays
an explicitly estimated target until hardware exists.

User supplied OpenRouter first-content SLA formula 10 s + 1 ms per token and
confirmed TTFT starts when OpenRouter sends the request. Use an external client
clock through receipt of the first streamed token; retain server spans separately.
Prompt-token interpretation follows existing code. No percentile exception was
specified: record per-request deadline misses as well as percentile summaries. Existing
coordinator code independently uses 10 s upstream, 9 s internal, plus 1 ms per
estimated prompt token (ordinary models). Public OpenRouter provider docs do not
publish the numerical formula. No serving deadline/configuration changed.

The updated goal was created successfully at 2026-09-15 19:29 UTC and is ACTIVE,
with the full reusable-framework, model sequence, MTP, external-TTFT and Darkbloom
integration objective. No token budget was requested. Do not mark it complete
until the actual delivery is achieved.

User explicitly required working through the technical plan before further
implementation. Root stopped both implementation agents, completed source-based
planning and independent reviews, and recorded
`docs/design/distributed-cluster-execution-plan.md`. It includes the real external
streaming clock, MTP depth-zero issue for output1, Gemma's request-state adapter,
branch reductions and expert-width optimization loss, and the 27B M5/NAX profile
integration constraint. Plan review is complete; ordered execution resumed.

Step0 source refresh is complete: local `feat/cluster-inference` fast-forwarded
from e4df336bc to latest fetched master
`605651bb95d71c1da9bb122107925143e9441973` (six commits). Three documentation
conflicts were resolved, preserving upstream App Attest material and existing
cluster additions. All 600 other preserved files rehash identically, no
submodule pointer changed, no unresolved conflicts remain, docs-check6 and
git diff --check pass. The pre-merge605-file backup and tracked edit stash remain
available. Receipt: `latest-master-refresh-completed-20260915.json`.

## Latest execution — 2026-09-15

FIRST PHYSICAL ATTEMPT completed as FAILED with clean teardown. Output
resident-physical-cut12-20260915; localparentprimaryWorkerEOF. Rootcause:
native rank1 wrote exactly "[jaccl] Connection attempt 0 waiting 1000 ms\n";
unchanged V3 rejected any stderr before readiness. Bothnativeleadersreaped-9,
bothgroupsfenced, allremoteevidence retrieved; noresult/noinferenceTPS.
600snetworklease cleanup PASSED and exacttemporaryaliasremoved,management/bridge
stable. Receiptresident-physical-alias-execution-20260915.json SHA
3ea1980e43f7768450da8119e2dab205ade2e84564df6910659f16a4eaa10af2.
OriginalfrozenlauncherSHA b83f50a594da2115ff51018c6b2eae255a08ada12e667895ee682ec815ff1882.
Pipelineagentnow implementing siblingresident-physical-integration-v2-20260915,
allowingonlysource-boundorderedrank1bootretrylines0..3/1000..8000ms,<=180bytes,
strictbefore-ready. Retainsrawstderr; allunknown/partial/postreadylinesrefuse.
LocalSSHstderrremainsstrict; native stderrreplayedseparatelyfromstdin/stdout.
Native7b4ae5/packagepinsunchanged. RootpreparedNEW
resident-physical-v2-plan-20260915.json +run_resident_physical_v2_alias_20260915.py
withuniquepeeroutputsandlocalresident-physical-v2-cut12-20260915; NOTyetexecuted.
No active rootnative ornetworklease. V2 awaitingfinalsource+testsfreeze.

Real aa7d resident SOLO cohort PASSED on peer48. One weight load, one warmup,
three measured fresh8192-token requests, all four reference comparisons, seven
native events, explicit release/shutdown and native exit0. Measured intervals:
18.547385417/18.546285208/18.559176250s; median441.67950446 prompt TPS.
This is engine timing only, diagnostic repeated-prose input, output1/MTPoff;
not external TTFT, representative qualification or distributed performance.
Parent301 observations: minimumactualfree8.6383GiB, zero swap, validpressure/AC.
Final cache0, active4016bytes. No postflight/cleanup errors.
Returned evidence: returned-resident-solo-aa7d-20260915.
Summary: resident-solo-aa7d-summary-20260915.json.
ParentreceiptSHA4cfefe9101a3f264d30b66750f26968670f1344f3a00e9cc820796f1a713b81e.
Public report: docs/reports/2026-09-15-cluster-resident-solo-baseline.md.

JACCL source frozen: resident-jaccl-worker-build-20260915/HANDOFF.md.
425member source snapshot28172c792400853e1abe745c3e71f69ff68d59dd908b61f16325c98fddef737d;
9modified+3newSwiftfiles, originalaa7dpreserved. Root build1 PASSED in286.487s, native7b4ae5d707fab11a3b9d410fbe948ca8f62f7768a4465fb1fecb747f74a5551e.
WorkerCPU6groups passed (old5byteidentical,new24/77), adapter41byteidentical.
prepare_jaccl_package_20260915.py executed;434members package andbothdeploymentsverified.
PackageSHA c33f6888a7ca01693e8bc291f0174cc45d6bcb4fc5065afd4e761956c6757255;
bundleSHA59049b46d88119e11724866a3cdb44254e2ac4bfcb26c9880b3d2adb10f3b211.
Deployment both peers:
/Users/developer/DarkbloomDev/resident-jaccl-runtime-20260915.
Also promoted27 compiledresident/JACCLSwiftfiles into mainrepo (5updated,22new);
prioraa7dworker increment had been isolated only. Main Package.resolved/build.sh
retained; equivalentpinneddependencies, publicbuildoptionsnotchanged.
Next: freezephysical launcher, deploy it, thenactual physicalrun.

Pipeline agent implementing resident-physical-integration-20260915. Root reviewed
remote_resident.py,run_physical.py,physical_common.py,rank_validation.py. Found
executionPath expectednative vsactualcbv2-contiguous; agent fixing. Also asked
retainterminal ifstreamhash fails, and pre-nativefailure distinguish nochild.
Sources not yet frozen; agentCPUtests underway. First cut12/serial only.
Root prepared run_resident_physical_alias_20260915.py (NOT executed), a600s lease
from priorpassedaliaswrapper withindependentIPv4mappedGID and exactrollback;
it will run physical launcher with resident-physical-plan-20260915.json
(createdwithactualpins) and new output resident-physical-cut12-20260915.
Peer24cachepurge passed19:43UTC; observedactualfree8.67GiB,AC,swap0.
No network change yet.

Added real standard-library external streaming client in repository:
scripts/benchmarks/benchmark_streaming.py and streaming_latency.py.
Explicitendpoint, authenvonly, exactrequest/rawSSE/arrivalcapture, oneclientclock,
reasoning/contentseparatetimestamps, fulltimeout, actual/declaredpromptSLAs,
failureexcludesSLApass. NeverclaimsengineTPS/MTPengagementfromchunks.
Nine focusedCPU/localHTTPtests passed; additionalcleanupfailuretest passed.
Arithmeticagent independentreview fixes applied (nonfinite/duplicateJSON,
overflowfloat, legacyfunctionterminals, failedrequestSLA, cleanupinterrupts).
All3 Python3.9syntax anddocs-check4/diff-checkpassed. No realproviderAPIrun.
Arithmeticagent mapped providerseams and is now implementing an experimental
DistributedCBv2Engine adapter andfocusedtests under ProviderCore/Inference/Distributed.
Injectedresidentowner, explicitprofile, oneactivejob, realdeadline/retirement/cancellation;
no productionwiringoractualbackendclaim. Rootowns heavySwiftcompilation.

## Earlier preparation

`prepare_resident_package_20260915.py` created a fresh source/binary archive from
unchanged aa7d and its 422-member source snapshot. Local package:
`resident-aa7d-package-20260915` (431 members plus manifest).

- Native: `aa7d205de4d2b5b7ac26842e0fd0fa42c96774b5ed1b229f418d726636da279a`.
- Source snapshot: `89b0245e2f7ce823d56aa9e4a37b8d7dbfffe5742edb0682886d485b443ae613`.
- Package manifest: `282a2bfe07cdacfebbeb2c5c7ba0b785370c731f9ceb394cc4444c1a6a481885`.
- Bundle manifest: `112c6ca9ca3250b1345b7f2f19b561e81d7d08cf55beac2a54080e9ed18ec63c`.

Deployed to a new remote48 directory:
`/Users/developer/DarkbloomDev/aa7d-runtime-20260915`.
All 431 members rehashed successfully there; see
`resident-aa7d-package-remote-verification-20260915.json`.
This is an honest source archive with pinned dependency history, not a new Git
checkout. Existing c079 installation and all frozen evidence remain unchanged.

Remote48 CPU-only `qwen-resident-benchmark-worker-check` passed in 1.349 s with
empty stderr and the same five records/byte-identical stdout as local build.
Receipt: `resident-aa7d-peer48-cpu-20260915.json`; remote outputs in
`cluster-research/aa7d-peer48-cpu-20260915`. No real-model resident cohort has run.

`/root/pipeline_stage_plan` is implementing a concrete solo launcher and real
validators in `resident-solo-integration-20260915`, using unchanged V3 and aa7d.
Root owns SSH, actual model launch and source review. Initial cohort uses the
retained diagnostic 8K input for which an actual full-model reference exists:

- Reference: `runs/qwen-long-prefill-reference-peer24-20260914/native/stdout.jsonl`,
  SHA `da85eb1e79a43c16575e6a8ffd48594ccb72306c16543a1e02c24903b89c154a`.
- Prompt: the same run's `inputs/prompt.json`,
  SHA `ee6caf0be6391e00ec41df930f0fd6351613969622cbb247b1b4bdaf69afe997`.
- Prior independent audit receipt:
  `bff08ef62a84c2ebd950ef692989abe6c037773cb1cc2af50bf5a31acc63c14c`.

That older reference ran under native7f779… and 266 archived sources; its oracle
was frozen after its native run. It reconstructs the exported BF16 logit row
and eight integer state offsets. Other state digests are opaque. aa7d solo
exports candidate hashes, not all candidate logit/state bytes; retain these
limits when comparing. This diagnostic input is not representative qualification.

Both implementation agents resumed after the plan was completed and master
merged. The solo integration was partial and untested when paused; no final
manifest/native run had been produced. Pipeline now owns finishing/testing it.
Arithmetic now owns bounded resident-only JACCL source admission/report changes
and CPU fixtures in `resident-jaccl-worker-build-20260915/workspace`. At resume
that workspace contained only422 unchanged aa7d source copies and two records,
no library symlink/build cache/compiler output. Main MLX dependencies are still
the same commits, so a checked libraries symlink is now permitted. Root owns
compilation and actual native execution.

Both exact Qwen artifacts contain inline MTP heads, but the current experimental
layer partitioner excludes them. Gemma's selected4bit artifact is
`gemma-4-26b-qat-4bit` (30layers, W4/G64 default with120 W8 overrides), with a
separate compatible assistant. Native resident rank admission remains loopback
until the new code is completed/built/tested. Neither remote CPU checks nor
earlier host-buffer RDMA smoke closes physical model execution.

Both machines currently have ample disk space; last check local128 GiB,
remote24 192 GiB, remote48 212 GiB before the new 239 MB archive. Resource gates
for real model launches still need fresh memory/power observations.
