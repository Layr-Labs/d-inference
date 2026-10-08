# Active cluster delivery checkpoint

Goal ACTIVE, unbudgeted. Full reusable framework /9B→27B→Gemma /prefill+externalTTFT /MTPoff-on /serving+recovery /release /M3projection objective unchanged. No user-action blocker. No push/release/production deployment. Previous status goal turn verified both model-copy completions and changed next action; this turn is PROGRESS: actual tinyGPU numerical check PASS, fresh-session8K HTTP request PASS, source reviews/fixes, two reports,27B builds advancing.

## Live job — do not restart

pipeline_stage_plan owns compiler slot. Unified exec session **84459**, Python runner **86155**, current worker-test PID **92574** (fresh ps verified). Directory qwen27b-resident-native-build-20260915/qualification-1. Sequence verify→Foundation→Runtime tests→Worker tests→Worker build, stop-on-first-failure, jobs2, bounded process groups. Foundation PASS4.060s, Runtime metadata/admission tests PASS232.426574875s. Worker tests still live at checkpoint, worker build follows only if pass. Preserve per-step stdout/stderr/receipts. Root may poll same handle if agent unavailable; never relaunch based on observation timeout.

All root physical/transfer jobs TERMINAL: copies3204/27942 pass, tiny85654 failure preserved, correctedtiny11944 pass, installedHTTP56493 terminal with SUCCESS inference. No live inference workers on either Mac after cleanup. No compiler/bulk transfers during timed HTTP. Other agents source-only; no remote/config switch started.

## Current hardware / access / model state

BothMac16,7 M4Pro14CPU20GPU,24GB and48GB,macOS27.0build26A428. Local development Mac M4Max36GB.24 darkbloom-24/developer@192.0.2.250/research-mac;48 darkbloom-48/developer@192.0.2.223/research-mac. Both freshly SSH reachable, uptime>1day. TB rdma_en1 actual PORT_ACTIVE80Gb observed in newHTTPrun.24en1normal169.254.70.46/16;48normallynoIPv4. Only reviewed600s169.254.70.47/32 temporaryalias; restored after every run. Never reboot/reset interfaces/close apps/lower guards.

SSH key ~/.ssh/id_ed25519_darkbloom_dev;ControlMasterauto/Persist43200. Private creds /Users/developer/DarkbloomDev/machines/CREDENTIALS.private.md0600; passwords same, parse file and send sudo via stdin only, never print/passargv. PeerSSH key id_ed25519_darkbloom_cluster. Localpurge restored21.547GiBfree but1,147,928,576Bswap remains; no local GPU check untilzeroSwap. Remote48 Xcode/Swift6.3.3 confirmed. Native/physicalguards≥6GiBactualfree/AC/zeroSwap/normalpressure.

9B both /Users/developer/DarkbloomDev/models/Qwen3.5-9B, aggregate127de76b4ef82b7aaa0acaac0ee31c784cff066eda64291f521f051469b7c24b,configc8e767de4953e58352fbc1acbf6615329075ed02fe16a36b8065714d85ee4423,manifest4f2735026cc7b40ee2c886ee53fb8755816c0001c4c69c141a61d5f56ff22aa4,cut4plan67bf0b1bf94f229682df58ae1ae10c758e2a386d66d3e1b68146f5c090f6309f.
27B model now COMPLETELY copied and independently remotely rehashed BOTH hosts at /Users/developer/DarkbloomDev/models/Qwen3.8-27B:14files16,320,415,757B. Evidence qwen27b-remote-model-preparation-20260915/{darkbloom-24,darkbloom-48}/{copy,verification}.json. Copy442.413/443.720s,exit0. Aggregatebbd0e0adcfe74e095073fefd0b9e116e4311d606ad9989cf81f8175e8ac18463,manifestd1239a5bc6d26d5ce4bf87f22270e3a703f4942e3d0d779948b4f65410df6dcc,config4691da94a1b4ef415aad112ec46abebd33f8a41ad07380e486c0526eb945c1ff. No27B inference yet.64layers/H5120/1847targettensors15,132,802,048B;named8320state1,616,248,896B;independent27B tokenizer needed.

## MAIN and installed runtime

Repo /Users/developer/DarkbloomDev/d-inference branch feat/cluster-inference HEAD605651bb95d71c1da9bb122107925143e9441973 contains fetchedmaster. Extensive intentional dirty files/submodules; NEVERreset.21HTTPfiles promoted exactly;private149tests/24suites pass;all13730 testedsourceinventoryentries matchMAIN. MAIN.build binary OLD08b019, never accidentally package it. Actual private tested c408 used.
BOTH installed /Users/developer/DarkbloomDev/installed-distributed-http-delivery-runtime-20260915:
Providerdebugc4083695c07ed7da819284e48de3aeb8786940b43271fa6e974b469c26f10350
NativeReleaseffcbd7de0ccc5a8b35881f9dd5ed5b6fcb8a2f5bdc7e7b63fa1e46bd9c79bba5
Capability7e8a1480f1c8831cf447fa2f51935bf5e3b79024b1b83c09aa2df0bb6df883e7
ClusterIDdarkbloom-product-qwen9b-http-delivery-20260915;cut4/28,chunks512,lookahead,MTPoff.
Canonicalconfig24d787ce64ed4249048c195ab02cedefcda50558fe69b7d7063e08c33f373da588;48 2228dec1f648ca8aa973eb3adde9d08d97dd11ed8a2e182c2f740285a5fc0144.
ProviderTOML24dea0e291200e111d0fbc5f8e549db5054546aeeaf963a854519804e3c5c675d6;48 47c083ac6eb0d7926b4bd468437e3d6dea1dc92e9bc44e63a133c4cc907f941e.
Bothhashes/help/nativecap/configure/stoppedstatus/doctor previouslyPASS. All5qualificationhelpers pinned/copiedboth. Packages/backups retained. No startupwarmup or27B/MTPprivate source promoted.

## New first-request8K HTTP observation

installed-http-deadline-terminal-observer-20260915 frozenmanifestb1a512d3cff519f5ac87afa1183ac21d5b51f0fe11189badb3b360abfecbba03/55members. Actual harness/physical-1 used explicit PYTHONPATH=observer root. First direct invocation failedimport client_timeout BEFORE main/remotes, retained physical-1-import-refusal.json; no physicaldir created then. Corrected invocation sourceunchanged, launch session56493 terminal31.666s.
Actual inference SUCCEEDED: firstcontent17.007461750s,deadline18.192,margin1.184538250,total21.130248792,8192prompt/123outputEOS (128requested),122content events,usage/DONE/bodyEOF/client0. Independent SSEbytes+arrivaloffset replay matched exactTTFT; Swift/tokenize all8192IDs matched. Beforestatus bothready/all16remaining/noactive/epoch787084de-3e9e-460f-af9f-e36c0e78ba40. Provider one reservation,normalterminal+retired.
No prior inference warmup in this freshsession; diskcachepurged, but GPU/driver caches NOTreset and previous work occurred. Do not claim reboot-cold/cleancompiler-cache/representativeSLA or causalperformance improvement. Prior coldmisses remain.
Expected-failure validator returnednonzero honestly: inferenceRequestSucceeded=true,slaPassed=true,terminalObservationQualified=false. No typeddeadlineerroroccurred. Parent then normalstopped CLI0/noforcedkill;bothworkersabsent/journals0/aliasrestored. NOTautonomousfailedrequestcleanup.117/110samples,min10.547714233/25.830352783GiB,allAC/pressure1/zeroSwap. root-review.json retained10artifactpins. Clientreceiptc0795f764522cb556960bce0194a9dd62d365425f318a04504ded6e434f4157c.
Frozen report docs/reports/2026-09-15-cluster-first-request-8k.md indexed; executionplanStatusline updated. Originalphysicalrecord preserved.

## Actual tiny MTP GPU numerical PASS

Original tiny proposal build/snapshot3passedtypecheck but localtiny-gpu-1 REFUSEDbeforechild forfree/swap. Root deployed12file227MBpackage to48 /Users/developer/DarkbloomDev/qwen-mtp-tiny-20260915; firstactualchild82049 trapped-5 at assistant construction: fabricatedfixtureflatconfig lacked text_config. No forward loop reached. Failure qwen-mtp-tiny-remote-20260915/physical-1 retained;childreaped/groupabsent.
Fixture-only correction qwen-resident-mtp-tiny-configuration-correction-20260915 wrapsassistantconfigtext_config;target/Plan andallproposalruntimeunchanged. Correctedbuild tiny-build-2PASS23.169s,minos26.2;source3057snapshot4 **8970c7869749883d5f58b2db9b83239e0835c2b2628ffe4cb9c45e55fae5d942**.
Correctedbinary **d24d4c7d642c3fdde63b78c5c6edec7f7e11a4a8496963e79558a9d7aa45ed6e**.
Matchedmetallib2129f6132794d84243c02631bc7478417dba0e0dbd10467beab56c11bf20bdd2; pagedattention4ad3ff17d8c6e0a3b5b8a91e9151447f84e36cb3688ed204e1e7eb6838dd9149.
Rootcorrectedpackage qwen-mtp-tiny-remote-20260915/revision-2/package manifest **90c6f67778fdbd808787b75304faf6318561748587b7efcc435446a31e22625b**,remote /Users/developer/DarkbloomDev/qwen-mtp-tiny-20260915/revision-2. Invocation run_tiny.py physical-1 -> MTPTinyForwardCheck run-tiny-forward-on-gpu.
Actualchild82817exit0,empty stderr,2.539250416s,11resource samples,min30.189788818GiB,allguardsPASS,no cleanup errors/reaped/groupabsent. maximumTargetOutputDifference0,proposalHiddenDifference0,proposal15,targetfrontier5. Rootread/replayedrawresourcearithmetic,rehashedallreturnedfiles againstremote,verified12deployedmembersunchanged/botholdnewgroupsabsent. Evidence revision-2/physical-1/{remote,root-review.json}.
ScopefabricatedH64/four-layer/P5 Float32target/Q4assistant. Actualtrunk/capture/history/proposal math. LocalfabricatedACKs,NOTregistered9Bresourcegate/distributedtargetverification/acceptedprefix/MTPthroughput. Frozenreport docs/reports/2026-09-15-cluster-mtp-tiny-forward.md indexed.

## Agents / pending source work

arithmetic_audit: qwen-resident-mtp-registered-probe-draft-20260915/proposed eightfiles, source-only, finishingfreeze. Rootreadall8/diffs. Privateexistingresidentworker+driver/transport loadscombinedtarget+head+embedding onlyrank1beforeReady, mode-boundload/requestdigests, P<=32/C<=16/O2one-request. RealframeACKs precedehistory;oneproposalafterfirsttoken+continueACKs; ordinaryseeddecode→target2; assistantreleasebeforebilateralretirement. No newtransport/supervisor/targetSessionCore. Rootfoundcleanup `probe.cancel;session.cancel` couldskipsecondiffirstthrows; agentfixed independentattempts+aggregateerrors, exactnil-proberestoration preserved. Need reviewfinalcorrection,freeze,thencompiler slot AFTER27B,thenactual9Bparentintegration/physical. No acceptedprefix yet.

pipeline_stage_plan: live27Bbuild asabove. Frozenoverlay09d4866dac6b6ae53eccd44559fc7367a61d70f07f6b499ee14b3a19396e75b4/51members. SharedQwenmodeldefinition/admission/source/budgets;validationSPI27Bserialcuts4/8/12/16/32,public9Bcapability andM5/NAXpolicy unchanged. Buildworkspace3038sources,preparationbfbb6610032e99586a590647712eda2d0fa0edbf815ffa22379829578ec6a0a9. Separatesource-onlytargettransaction work: pendingseed→draftrecurrence,exact0/1/2KV/recurrentreconciliation,deviceoffsetrebind. Rootdirected progressivestatecommit beforeper-tokenpublication tosupportstopafterfirstnewtoken: agreedacceptedprefix != irrevocablefullcommit. Commitseed→publish/continuedecision→commitnextifcontinue;stoprollsbackpendingtail. retain1-onlycheck may be temporary,NOTfinal MTParchitecture.

transport_probe: frozen startupwarmup38membermanifest **3ac23085eca74829b5a850dced474c12834afbff6a71290edec9d81118069c2f**,17files9runtime/8fixture. Rootread9runtime/no blocker; no Swiftcompile/tests yet. .warming beforeexternalready;ordinaryPairrequest syntheticconfiguredchunk+decode,oneof16admissions→15remaining,fixedlifetimecountsactualcost;legacyomittedrecipebyteexact. Sourcefixtures explicitstop/Taskcancel/startfailure/deadlineafteradmission/success+remainingquota. No promise all8Kkernelshapeswarm.
Transport now implementing concrete configured2s deadline negative harness in NEWprivate dir. Root AUTHORIZES temporary default-reference switch BOTHdevelopmentMacs with exactpreimages/backups/restoration+verification, but no switch untilroot physical coordination. Plan installed-http-configured-deadline-plan-20260915 manifestc83ed4533403a9bf3f985c6dcfa6aba5683e9eef0bf9e2138c6c21288906a9bf. ConfigchangesonlyclusterID+requestTimeout120→2,samec408runtime. Existingowners readdefaultreference, so isolated--configaloneisunsupported. Agentoutertransaction will preparecanonicalpostimages thenatomicdefaultswaps guardedemptydevicejournal/sidecarlock;restoreexactbytes/modeafteractualcleanup,refuseconcurrentedits. Reuseexactclient/5helpers,changeboundvalidatoronly. Expecteddeadline_unreachable OR inference_error/safety_deadline race,8192/0attemptusage,DONE/EOF/autonomouscleanup. ExternalSLAstill18.192/failed;don'tclaimnatural18.192miss. Noimplementation/deploymentapprovalquestionneededwithinuserauthorizeddevelopment scope.

## Root next reference task / remaining

Root investigated reusable27B fullgreedyreference and saved qwen-registered-generation-reference-draft-20260915/SOURCE_PLAN.md +13sourcepins; NOimplementationyet. Existingfull-generation-reference-entry-draft retainsactualCBv2 loop/state/capture but CLI/admission/budget andsourcecheck are9B/8192,927tensors/32layers. Its loader goeslegacyDiagnosticQwenStorage6GiB limit: merelychangingCLIwouldfail27B. Reuseexactregisteredloader from MAIN QwenDenseShortReferenceLoading (VerifiedCheckpoint→PreparedQwenCheckpoint→registeredprofile/sourcevalidation→materializeVerifiedQwenDiagnostic→finishbaseline), profile-boundfullstatebudget. Do NOTrelaxlegacy6GiBglobally orduplicateinferenceengine. Existingqwen-dense-short-parity-check accepts27B P3/C2/teacher1/O2default32/32, usefulteacherforcedcontrolonly,NOTgreedy128reference. No27Bphysicalresultyet.

Priorvalid9Bresults: native128IDs/final496640BF16bytes/72state comparisonsPASS; serial426→lookahead494effectiveinternalTPS~16%vsserialdistributed,~23decodeTPS. Solo441.68diagnosticTPSnotoptimizedcontrol. Installedbothcancellationphasesnewc408autonomouscleanup~1.58sPASS,fresh42/128normalTTFT0.370661667s. Oldwarm8K16.90sPASS123EOS;oldcoldmissesremain.

Remainingfullgoal: registeredMTPproposal→targetacceptance/rollback/off-on;27Bactualreference+distributedshort/8K thenGemma+MoEreuse; optimizedsolocontrols/balance/chunks/tensorsplit/profilecriticalpath;startupwarmup,sustainedrotation,current16request/300slimits,reconnect/peerfailures,coordinatorcapacity/accounting;representativeexternalSLA/128requestedEOSactualcounts;compatibility/setup/release;M3Ultra27B800desired/1000stretchprojectionONLY. No modelperformanceclaim beyondscopedevidence.

Latest docs-check306filesPASS andgitdiffcheckPASS. Newfrozenreportbodiesdon'tedit; executionplanStatuslineonly updated. AGENTS/docsrulesread. No skillused. Sendusercommentary≤60s. Oneheavycompilerjobs2; no timedHTTPduringcompiler/bulkcopy. Nevermarkcomplete/blockednow.

Previous checkpoint archived: CLUSTER_DELIVERY_NEXT.pre-tiny-and-first8k-20260915-175838.md SHA256 0c9940e0ec173685d234fa4a8336a85e0c2b2c74b55b7ed2c16f7600459ca320.
Updated 2026-09-15T17:58:38.925212-07:00.
