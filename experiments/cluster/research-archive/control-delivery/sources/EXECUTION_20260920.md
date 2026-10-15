# Darkbloom cluster execution — 2026-09-20

The user explicitly resumed the existing delivery goal and requested completion,
including measured Gemma 4 numbers. This is the same goal, not a replacement.
The goal service currently retains `blocked`; it exposes no resume operation.
Engineering is proceeding. Do not mark the delivery complete until its acceptance
criteria are met.

## Completion criteria

- Opt-in configure/start/status/doctor works on both verified, routable Macs.
- Shared model loading, partitioning, state, transport and lifecycle interfaces
  support the registered Qwen9B, Qwen27B and Gemma4 artifacts.
- Actual Gemma TP/EP candidates are compared numerically before performance
  qualification; automatic placement uses compute, memory and network costs.
- Reproducible uncached solo/distributed prefill, decode and sender-to-first-content
  measurements cover multiple prompts and repetitions, with deadline misses.
- MTP on/off means genuine active drafting/verification, with measured overhead.
- Trusted member traffic is encrypted and actual pair execution, recovery,
  cancellation and accounting are tested end to end.
- Integrated source, install documentation, compatibility matrix and release
  checks are complete. Production publication is a separate concrete operation.
- M3 Ultra 800/1000 prefill TPS remains a projection until hardware measurements.

## Active work

1. Root: physical test orchestration, build serialization, measurements and review.
2. transport_probe: independent lifecycle and Gemma loading/lookahead reviews.
3. arithmetic_audit: correct the actual EP kernel-selection numerical mismatch.
4. pipeline_stage_plan: repair two actual protected HTTP test failures, then
   automatic coordinator initiation and current App Attest identity integration.

All new candidates live in fresh September 20 directories. Existing reports and
accepted evidence remain unchanged. Preserve other working-tree changes.
One compiler/materialization slot, jobs=2; no bulk copies/compilation concurrent
with physical inference. Native AC/normal pressure/zero swap and existing free
memory limits remain in force. Local 36GB development Mac stays off GPU.

## Fresh observations

Both Macs respond over SSH. Both report AC power, normal pressure and zero swap.
The 24GB Mac initially has only about 4.3GiB actual free, below the native floor;
authorized cache preparation and a new observation are required before execution.
Cache preparation subsequently produced about 12.9GB/33.3GB actual free before
physical runs. Both still report zero valid signing
identities. Genuine signing/provisioning and attestation configuration remains
an external dependency for protected product qualification, not for native lab
benchmark engineering.

## New measured Gemma baseline

The resident benchmark compiled successfully for macOS 26.2. Binary SHA-256:
`9cfc4ac873e9c54965530796472e317e5585d25444dc4b2d02d387e84b5f1eb3`.

Matched case `gemma4-execution-20260920/cases/p128-cut8-correctness-2`
completed solo and on both Macs. P128/C128/O16, BF16 residuals, cut8/22,
one warmup plus three measured requests, fresh state each request, MTP off:

| Metric | Solo 48 GB | Two-Mac serial pipeline |
| --- | ---: | ---: |
| Aggregate prefill TPS | 515.262 | 372.690 |
| Aggregate decode TPS | 45.357 | 8.522 |
| Median internal first token | 0.248800 s | 0.343830 s |

All 64 generated IDs, four complete final logit rows and 360 state components
(128,860,640 bytes) match exactly. Actual parent/process-group retirement,
empty canonical device journals, resource checks and Thunderbolt alias restore
passed. The first comparison is retained as `comparison.json`; an independent
retained-evidence validator passed without rerunning inference (`comparison-v2.json`).
This is a short-prompt correctness baseline: serial pipeline, plaintext lab
RDMA, no external sender-to-first-content measurement, no TP/EP speedup claim.

First pair attempt was refused before loading on rank0, 70.6 MiB below its
higher admission budget. The failed run and successful first solo are preserved.
Both workers retired and the alias restored. New v2 supervision cancels the
remaining peer through its own supervisor after a peer failure. Retrying after
all deployment I/O and reclaimable-cache preparation passed unchanged gates.

## Larger Gemma and expert results

P1024/C128/O16, cut6/24 (`cases/p1024-cut6-c128-correctness-1`) passed:
solo 510.253 prefill TPS and 37.582 decode TPS; serial pair 397.720 prefill TPS
and 8.279 decode TPS. Median internal first token was 2.047235s versus 2.575072s.
All 64 IDs, four complete final rows and 360 state components (923,976,160 bytes)
matched exactly. Both native owners retired and the TB alias restored. This
remains MTP-off plaintext lab RDMA, not TP/EP or external TTFT qualification.

P8192/C64 solo (`cases/p8192-cut8-c64-correctness-1`) was refused during loading,
165.315MiB below its current required free-memory budget. Native/parent cleanup
completed; the pair was not launched. No 8K Gemma TPS is accepted. Source review
found the budget kept reserving the largest already-completed tensor read. A
successor uses the maximum of the unread suffix, retaining pending reads and all
existing residency/runtime/headroom floors. Eight pure controls passed. Physical
fit still needs to be established.

Actual `GemmaExpertAxisCheck --synthetic-small` ran 60 cases: 52 raw expert outputs
matched exactly; eight T8/T9 cases differed as sharding changed matrix-kernel
selection. All BF16 weighted outputs matched, but the strict numerical check
failed. No EP correctness/performance pass is claimed. A private projection-policy
fix is being prepared; no tolerance widening. Real checkpoint and two-rank
expert tests wait on that correction. Both expert products compiled successfully.

## Work now in progress

- Gemma one-chunk lookahead source reuses the qualified Qwen frontier/credit
  guard. Fourteen Foundation control groups and ten Python overlap tests passed.
  Native compilation and matched solo/serial/overlap cohorts are next.
- Protected configure/start plus retained session integration compiled. Actual
  175-test run finished with 173 passing and two HTTP tests failing (five issues).
  The failure evidence is preserved in `cluster-product-start-20260920/Build/qualification-1`;
  its HTTP path is being diagnosed, without weakening assertions. Independent
  source lifecycle review found no concrete blocker in its bounded scope.
- Latest master fetched at `cc225365f866d9a0e6f565fe9426703785611f84`, 18 commits
  ahead. Isolated three-way audit preserves all dirty/untracked work; integration
  remains. Upstream now supports qualified App Attest without MDM, so cluster
  identity must reuse that authorizer explicitly instead of inventing legacy proof.
- Signing/provisioning remains missing; the earlier configuration-location
  question is pending. Native lab and product engineering continue independently.
- Current compiler: `cluster-product-http-qualification-20260920`, prepare passed,
  178 tests plus matching CLI build scheduled. No active physical inference.

## Qualified overlap pilot and next loading boundary

Native composition `applied-lookahead-experts.json` SHA `6fc4df52…9afcbe` compiled
all three products successfully. Resident binary `ceb0bca6…25e74ca`; expert-axis
`5e82a28d…588943`; expert-RDMA `0df9ab04…744ef0`. Thirteen projection-policy
Foundation groups and fourteen actual resident argument/description calls passed.
Resident v4 is installed on both hosts with package `1c413eeb…8af719`.

Matched P128/C64/O16/cut8 solo, serial pair and one-chunk lookahead pair passed
all five process/lease/alias/resource/phase joins. Prefill: solo381.114,
serial250.668, lookahead283.561TPS (+13.12% over serial, still slower than solo).
Decode:45.123/8.543/8.512TPS. Eight complete final rows and720 state components
(257,721,280 bytes) match the reference; all generated IDs match.
Receipt `cases/p128-cut8-c64-overlap-v4/comparison-overlap.json`, SHA
`990fc9d6097e46453837dd8c9ed9822d554b6f12afddb95f2e2c9567a9c4e528`.

8K/C64 v4 solo reached all1339 loaded tensors but refused the next guard:
actual free16,954,916,864B versus required17,134,295,756B, active15,070,714,228B,
cache0. This is a new boundary,179,378,892B (~171.07MiB) short. It retired cleanly;
pair remains unlaunched. Original failure/evidence is retained. A4K matched
cohort is next; no8K timing is accepted and no resource floor was lowered.

The HTTP correction fixes resolved empty stop-token propagation and one actual
synchronous distributed admission rejection before SSE headers. Original two
HTTP tests are unchanged, three stop-policy regressions added. Independent
review passed. Its initial preparation correctly refused a stale prior-CLI pin
because the failed175-test run incidentally rebuilt the CLI. A successor binds
and preserves that observed unqualified binary; all source/test changes are
identical. Earlier qualified binary and all failed evidence remain preserved.
Other early error-only branches are being audited separately.

Expert projection harness successor `gemma4-expert-projection-execution-20260920`
passed20 Python controls (13 parser and7 actual-child retirement). It now drains
natural exit2 before numerical rejection, preserving failure. Physical EP retry
is next. Automatic-initiation source is frozen but uncompiled; current-master
App Attest signer/identity integration remains under development. Go conflict
resolution is staged/reviewed; Swift context conflicts are being composed.

## Expert and protected-product qualification completed

The expert projection successor now passes all physical gates: 60 small
synthetic cases, 30 Gemma-geometry cases, 10 real-checkpoint/router cases, and
five actual two-Mac RDMA cases for each of the unequal 48/80 contiguous and
43/85 strided expert layouts. Unweighted expert rows, original-order weighted
outputs and post-normalization outputs match exactly. Both RDMA native pairs
exit naturally, actual process groups and device leases retire, resources pass,
and the temporary interface alias is restored. Pair receipt hashes:
`ff8f1ecc0887efa5cc2e3a3b4850de12c7dd0c9b795f53c575f36d4a9acddb92`
and `a6ab6f7ba76c42aa5523e9563b4f34edb1f29d317b1ba4f640b952a5bd48ba99`.
These are one-layer expert correctness results, not full-model EP or TPS.

Protected startup/HTTP qualification now passes all 178 tests in 27 suites;
the matching CLI builds as `fc19d07359d7fbe08ff979ee605ec22c321e81bb7530e9048cba66737f81d59f`.
Actual source candidate `2d86c6dfa94fe829c7f602f8ad38f463f58464e661ef11c7ef6a5a2372909f6a`
is retained in `cluster-product-http-qualification-20260920`. No signing,
installation or actual protected hardware inference is implied.

Master plus original MAIN work is composed in the isolated actual git worktree
`upstream-refresh-20260920/workspace`: 58 exact overlays and all 1,083 original
untracked source files, receipt `7f2510a2cd7102fa843ced4ed5f08839804a7cc0dd6540fdaec7f3ec5f42c4b4`.
MAIN remains untouched. Submodules and private qualified product promotion
are still pending. App Attest proof-to-lease/typed identity source is frozen
at manifest `4ecea45ac240774539d1001de530b9fc235bdd3445de140c2a2047531c01179c`;
pair transcript/hold/release readers still need migration before admission.

The 4K/C128 solo attempt performed its first request and captured its final
state, then failed a fresh guard at actual free16,398,565,376B versus required
16,464,874,700B (66,309,324B short). All actual owners retired cleanly; no timing
is accepted. A fresh 4K/C64 cohort reduces the workspace bound and is running.
Guard instrumentation is staged and independently read at source manifest
`84352102855784c7137546371eda5c77be427dee881a5f407d7b3c0cdf3d549c`;
qualification follows the physical cohort. It preserves all checks and floors.

## Accepted 4K Gemma comparison and metrics build

P4096/C64/O16/cut8 resident-v4 matched solo/serial/lookahead completed and
passed all five physical owner/resource/alias joins,64 generated IDs,8 complete
final rows and720 state comparisons (2,351,268,800 bytes). One warmup plus three
measured requests. Prefill349/257/339 TPS precisely:
348.657783511564 solo,256.5175984097541 serial pair,
338.80806311328973 conservative lookahead pair (+32.08% over serial).
Decode36.7966/8.0395/8.0104 TPS. Median internal first token11.746114 /
15.966619 /12.104948 seconds. These are plaintext lab RDMA, MTPoff, no external
TTFT or p95 claim; overlap is still slightly below matched solo.
Serial receipt `fffb13addf63a54e878826351e8303051953a341da63620c756c80e7727cc843`;
five-role overlap receipt `2b9eb421e957060efc9e911a9cca8e2afca6df897a171abc1e5fbc850d2aff07`.

Guard instrumentation built successfully (36.73s), resident binary
`f3676c3ab0e41c25552d2aead70f39b68bc9e627db67368fe3fffd99a2cde7b0`,
source receipt `386403c0125d7b5a14165f170635b1dc6e70e83173965d9aac7ee981a872d6a7`.
Seven Foundation metric groups and14 actual argument/description calls pass.
Both hosts now have a separate resident-v5 package
`68f5fc022c833c27ca6c1ccafea2a65ecdd1d36d98a6fe9a1beb03d31db86976`.
All v4 binaries, deployment and supervision are preserved. No v5 physical
cohort has run yet. Fresh guard consolidation is separate source freeze
`3a51c3b0d6d046bcd75ab7302b6942899db825deee867ef0859424f40ff59aa7`;
source controls and9 Foundation groups pass, native application still pending.

Root staged expert C64/C128 extension in `gemma4-expert-prefill-bound-20260920`,
manifest `96b09205616dc075d0efb09c6962a630f7e88ba14ee8a7b76e6613fe34b44a06`.
It increases real-E128 packet and graph limits to1024 assignments and adds
wire reserves. Original weighted/kernel arithmetic stays unchanged; small-E16
retains33-row cases to avoid an unsupported density-tile change. Sixteen
Foundation policy groups pass; native compilation and physical qualification
remain. Full-model EP constructor/decoder/selection adapter is being implemented.

All five current-master submodule checkouts were materialized in the isolated
worktree, preserving9 MAIN dependency overlays; no MAIN mutation. App Attest
identity15 overlays applied with receipt `c2daf9b3d868d9ec1305467dec5bed64e86219002a364d6facfef27c3e4ffe19`.
Previously qualified common coordinator mesh/worker17 overlays composed with
receipt `4b6c0db953bf10f4ec83e2f32d4aa29dfbc5c61842dc63916074dd8b85172284`.
Focused current-master Go tests are running using pinned mise Go1.25.0 from
the root module. An initial invocation failed before compilation because Go
was absent from PATH; that diagnostic is retained. Automatic initiation and
typed App Attest pair admission are not yet enabled/qualified.

## Fresh guard and current-master continuation

The v5 P128/C64/O16/cut8 metrics cohort passed the full five-role numerical
comparison (64 IDs,8 full rows,720 states), receipt
`c3a078a8d5ab3711c0b649387e56258a991ffd2a9098d4cde8283c30629d5375`.
Solo378.5344/45.5469 prefill/decode TPS; serial251.1247/8.54875;
overlap283.3180/8.53317. Distributed logical guards account for23.6–28.1%
of prefill and62.1–64.4% of decode. The analyzer initially used the serial
frame-clock validator for overlap; corrected it to select the already frozen
one-chunk validator by actual policy. All original comparators stay unchanged,
and the old analyzer is preserved. All three guard analyses now pass.

Fresh guard6 + bounded expert C1288 + description1 overlays applied with source
receipt `1dd0bfaf4fb7c9425eb631bfd45bfd25c4c3b2d87b7d9e9fd330acdb40fda33e`.
All three release/macOS26.2/jobs2 builds pass: resident
`110598d98fe332d012113ca4db05a3714e5d5dbacefcf3a1b72cf768f3ac0720`,
Axis `5214694750eb62519ac78946e16cbced26cf2a9c62f1c59c4a152426b7172839`,
RDMA `7dee6ce5510ce11827c7ebcb8d1f3e27cab7c821ad4534aa6b84b3d47f772f06`.
14 actual metadata calls pass. Resident v6 installed on both Macs, package
`5f8f3a796c2b5917b9eff3ed21a230d2eecc938e03065c03807f3cb7d349e6a5`.
P128 solo v6 passed owner/metrics validation:392.5122prefill/59.1812decode;
guard shares0.85%prefill/8.27%decode. Matched pair correctness still running.
The C128 harness26 parser/actual-child controls pass; binding caught a metadata
schema mismatch (package row has additional manifest hash), pending narrow fix.
No expert C128 physical claim yet.

Current-master focused Go tests completed:113 top-level/263 total completions,
four packages,0failed/0skipped. Log `qualification-1/go-focused-2.log`,
SHA `d5a6794129e9e6f173daf6cb9008da5199ec2d05d52f28391eafd24092b0a221`.
Default product85 overlays applied with receipt
`241031e677b8a58f874d526008a1a8cfd88b223409180e422c4541f2cfdba39e`.
Subsequently initiation Go10 +Swift12 +typed App Attest pair27 applied with
receipt `edc9ca6570b2e2ad24c1d992a20d07979a5c32e773155bc1c631cf23a9516a0b`.
These newest layers remain uncompiled; source checks pass and peer review is
ongoing. Prior successful tests do not qualify these later changes. No private
hardware flag or trust fallback added. MAIN remains untouched.

P128/C64 v6 matched solo/serial/lookahead is fully accepted:392.5122 /319.6153 /
382.4771 prefill TPS;59.1812 /24.7265 /24.8517 decode. Overlap comparison
`c0a07d0c86c11af48a4b8fdafda2ac82503aede329561f96c257f4a763d5c754`
checks8 rows/720 states. Guard OS reads are exactly1 per synchronous invocation.
This is +35.0% prefill and2.91x decode versus matched v5 short-overlap baseline.

V6 4K/C64 solo passes:363.8342prefill/45.3009decode, median internalfirst11.265157291s.
The serial pair then REFUSED during evidence capture after2 request states:
24GB actualFree6,863,978,496 vs required6,866,186,254 (2,207,758B short),
active4,316,034,632/cache0. Peer cancelled; both actual process groups retired,
canonical journals unchanged/empty, original TB alias restored. No pairTPS accepted.
Native guards/floors stay unchanged. Root stages F_NOCACHE on exclusive evidence
file descriptors, before first write, keeping all original writes/fsync/hash/
identity checks. It is outside timing and may prevent file-data cache from
consuming later request margins. Not yet built/physically measured.

Current-master automatic initiation+typed App Attest source passed focused
Go qualification:142 top-level/355 total,4packages,0failure/skip. Includes all
142 exact expected methods from old113+initiation8+typed21. Actual12.43s,
source-before/after identical, natural0/reaped/group absent. LogSHA
`fcdbd6c349176f9705fdb60fff252fff53623af2ce45c2468d9d53da4466490b`.
Registry race is running. Independent critical reader review found no blocker,
receipt `fc8a48f3db9e6602834179b317a5a75ae182ad2eafdc178d5762c7a056b5be6f`.
Swift default192-method compiler runner still being prepared.

Expert harness successor `gemma4-expert-prefill-execution-2-20260920`, manifest
`93c806befa953c8701cfd72981b408a1665003e60111bb600d52c751177d90d2`,
fixes exact optional manifest metadata handling without relaxing integration or
binary/source matching. All4 new controls pass. Actual Axis/RDMA/source receipts
now bind successfully. Original26 controls remain predecessor evidence.
No new expert physical run yet.

Registry race pass completed:82 top-level/258 total test completions,0fail/skip;
actual10.816s,natural0/reaped/group absent, same source inventory5029ef57.
LogSHA `ad4ddf41353ea507918d58c6f1c6a6b663843bd509627458fa8ac21fed8d62ed`.
Expert new actual native metadata qualification passed14 invocations including
7 local decoder groups and exact1024/8MiB/32MiB description bounds; noGPU.

Uncached evidence native build6 PASS35.98s, SHA
`6115f51db204f8afe59b1e6b68d47074c7cad14bfde11e5acda477c290305034`,
source receipt `8ec41c24385edfa16b66864ffbf4161de470dbb5b5c559d8a134243b102288a6`.
14 actual metadata checks pass. Separate resident-v7 installed on both Macs,
package `98d051e36e94953201e3f117b9fec97e07d694c1239f898109b91d3f56b7a284`.
No v7 physical result yet. All v6 evidence retained, no resource floor lowered.

Default current-master runner f1626822 passes source/4 parser controls. Actual
APFS preparation12.28s PASS with4,279 source+9,832 dependency files, candidate
`a764ed673a6c47f41a9cbc63f2d1cc4fd55c9e6429d87878eee6455e704b7a2e`.
Six fresh helper compiles pass/reap/groups absent.192-test default product
compilation/execution is running. No private activation flag or old SDK fallback.

Default Swift first test attempt failed before tests because copied Clang PCMs
retain an absolute ModuleCache path. Preserved the scratch ModuleCache and rebuilt
it in place; no original cache or evidence deleted. The next compiler reached
ProviderCore but found one new-master API mismatch: providerVerificationStatus
now carries a fourth authorization field, while the member interceptor matches
three. Retry receipt `qualification-1/tests-2/receipt.json` retains natural
failure and confirms terminal source inventory unchanged. A minimal compatibility
fix and regression are being prepared; no default Swift tests have passed yet.

Full-model EP source freezes0551+a082 pass read-only source checks. The successor
retains all30 decoder/state layers per rank, ordered selected expert weights,
original router and weighted sum, and the same sole Collective after resource
admission. The first physical scope isP32/C16/O2, both full90-state replicas
against a new full reference. No full-model EP compile or physical claim yet.

Resident-v7 P4096/C64/cut8/O16 solo is running with uncached evidence writes.
Initial actualFree24=12,995,870,720 /48=33,462,304,768B, normal pressure/AC/zero swap.
Matched serial and overlap cases prepared using the same request IDs, epoch
and native build. No compiler or bulk materialization overlaps physical runs.

V7 P4096/C64/cut8 solo accepted:363.7956prefill/44.8162decode,
medianinternalfirst11.266065708s. Matched serial pair FAILED again after two
complete rank0 states: actualFree6,848,708,608 <required6,866,186,254B;
active4,295,390,736/cache0. F_NOCACHE did not fix the live memory margin.
Both actual native groups retired, canonical leases remained empty/identical,
alias restored, failure retained. No v7 pairTPS and overlapcut8 remains unrun.
New cut7 cases prepared to move one layer off the constrained24GB machine;
no limits changed.

Full-model EP0551+a082 overlays applied to disposable native workspace, actual
source receipt `5cac94b82c27ff27dbbbe3aa87ac5439caaaf619099fceb5545b85f0ed4597e5`.
23 Foundation partition/schedule groups pass. GemmaExpertFullCorrectness build
PASS74.182s,47,686,856B,macOS26.2, native
`45d25b836a602094cce7e9c94775ba6844fbaae5470e8e23cf93229bd3ff50ca`.
No full-model EP GPU execution yet.

Current-master member event compatibility successor d33e750d updates only
four-field trustStatus arity and one meaningful diagnostic/stop regression.
Original handler receives all diagnostic fields; no diagnostic becomes a grant.
PreparationPASS1.372s with exact14,111-source/dependency inventory except two
reviewed replacements, candidate d6fab2c4. Updated exact193-test phase running.
Original failed attempts and source preimages retained.

Default current-master193 exact tests PASS (five parameterized cases),160.168s
including146.03s compilation, allnatural0/reaped/groupsabsent; candidate
`d6fab2c4e0ce6598ef4fc19b0c1e04ce83c555e48a543c89e6ac8a4dc1ee7228`.
Matching CLI buildPASS10.302s,150,860,752B, binary
`ff4812473edb94cd4ca0a709100bf05b4e6c3cf990beaa97a543e99366cfdc0e`.
MTP accepted-round Foundation26controls PASS (2.919scompile/.320stest);
noactualmodelacceptance yet. Measured-placement planner19syntheticgroupsPASS
2.794s; independent reviewfoundnoconcretebug but legal graph/completeliveness
remain adapter obligations. No actual calibrated placement claim.

FullEPphysical8parsercontrolsPASS;actualbuildbinding cb517d5f and bothinstalls
package3323ffb196dac854a0132255cb47eab3a9fe7237e3e30ed135a7002ddcd6eee1.
Seven actualCPUmetadata/codec/ledger/encodingcallsPASS;109checks andmaximum-width
544,992B report (<1MiB), noGPU. Prepared32/96map was notlaunched: its minimum
initial requirement13,065,569,964B exceeds actual12,970,295,296 beforeallocation
rounding. New24/104map freshlybound; allsevenmetadata callsPASS.
Fresh actual48GB fullreference PASS: IDs1813,496;twofull262144rows/all90state
components;93rawresourcesamples,minimumfree17,142,710,272B;actualPID56491,
natural0/fullEOF/groupabsent/samecanonicalemptyjournal.
Case gemma4-full-model-ep-physical-20260920/cases/p32-c16-o2-ep24-104-v1.
Pairedexpert run is next. NoEPthroughput claim.

Actual24/104EPpair refused before construction: actualFree12,141,969,408B
<required12,206,449,881B; completed0/1339,active/cache0. Startup consumed
about797MB of initial free memory, leaving the unchanged admission requirement
64,480,473B short. Both native groups retired, canonical journals remained
empty/identical, original TB alias restored; total13.619s. Failure retained.
No EP numerical comparison or throughput is accepted from this attempt.

Fresh16/112ownership case prepared with the same native45d25b83 and limits;
all seven CPU metadata calls passed. Cache preparation found actualFree
24=12,996,788,224B and48=33,512,587,264B,normal pressure/AC/zero swap.
New full reference is running before the paired expert test; no compiler or
bulk materialization overlaps this physical run.

Full-model Gemma EP16/112 now physically PASS on both Macs. Fresh full reference
and both expert ranks selected1813,496; each rank's two complete262,144-element
logit rows and all90 decoder-state components match native bytes exactly.
Both ranks complete150 expert exchanges/607 control records and the original
frontier33. Full/rank0/rank1 minimum actualFree respectively17,027,956,736,
7,997,456,384 and18,843,811,840B. Natural0/completeEOF/nativegroupretirement,
same canonical empty journals and original TB alias restoration all pass.
Pair cohort49.3853s includesloading/probes/evidence and IS NOT aTPS benchmark.
Plaintext labRDMA/MTPoff/smallP32C16O2 scope only; productserving remainsdisabled.
Evidence:gemma4-full-model-ep-physical-20260920/cases/p32-c16-o2-ep16-112-v1
and root-validation16.stdout. Revisedcut7 longpipeline cohort is next.

V7 P4096/C64/cut7/O16 fresh solo and serialpair PASS. Solo363.686216prefill,
44.866064decode,11.263918292sinternalfirst; serialpair318.466920prefill,
22.607147decode,12.863236250sinternalfirst. One warmup+three measured,
64IDs/four full rows/360state comparisons and all three resource/owner joins.
Comparison-v2 SHA285192207bd09d9e53fac8a7dcd107bd8307bd92e5984935560d396ad4353b48.
The cut7 split resolves the observed late cut8 memory refusal with the same
native6115f51d and unchanged limits. Matchedoverlapcase is now running.

MTP physical/compare source reviewed. Initial16CPUcontrols had15pass and one
renderererror: the retained sampler already requires pressure1, so a proposed
0..2 substitution had no preimage. Preserved all four originalsource/manifest
files andfailedCPUreceipt underroot-template-correction-1, then made the renderer
verify the exact existing pressure1 check. No native/source arithmetic change.
Updatedqualificationmanifest8c3af0386d15f6a31435299528ea0000349b6071769e5e0028bd3a587a8deba0,
Physical079cb9eb37b839db5a0b62229e0665359e53276023ed1fa511babf9e39352173.
All16 CPUcontrols nowPASS in cpu-controls-2, sourcecheckPASS; Build725c unchanged.

V7 P4096/C64/cut7/O16 overlap nowPASS: conservativepair452.192428prefillTPS,
22.212139decodeTPS,9.021425250smedianinternalfirst. Freshmatchedsolo363.686216,
44.866064,11.263918292s. One warmup+three measured; all64IDs/eightcomplete
finalrows/720statecomponents andfiveactualowner/resourcejoins pass.
Comparison-overlap f625a609a44943561ee66b5bc0325ae021c74e42d2e8d4d695159945e12d9a87.
This replacesv4as newestaccepted4Kmatchedcohort. +24.3%prefilloversolo,
~42.0%overserial;decode remainslowerthansolo. PlainlabRDMA/MTPoff;
internal9.02s is not an externalOpenRouterTTFTmeasurement.

MTPpreparefirstattempt refusedbeforeanywrites dueonlyinventoryordering:
actual3075source/8755dependencyrowsallmatch, but originalsused traversalorder
andactualinventoryuseslexicalpathorder. Preservedroot-inventory-order-correction-1;
normalizeexpectedorderingonly, allpath/length/hash checksunchanged.
Buildmanifest4d0eff4686d8eca3ffc423b80c3440ad47c46fa68620cdc920ad698fc3e9c832;
qualification0ff099c948827e1a2ea37e1e1060707f4b48ec5057523e73c82a5badf6ee8b1a.
ActualpreparationPASS3481sources/8755unchangeddeps,oldproducts/preimagesretained.
Newworker/referencebuild isrunning withjobs2andmacOS26.2, nophysicalrunconcurrent.

StandaloneencryptedRDMA source98a051061c971046901b913ff20f86fb81642f5f6c6714ba9baf4ac68409f591
reviewedwithindependentnonce/counteraudit; no concreteblocker. Pythoncontrol
initial5/6pass foundmacOStemporaryfixture /varalias; runtime correctlyrejectedit.
Preservedroot-fixture-path-correction-1, canonicalizedonlytestpath; all6controls
nowPASSnatural0/reaped/groupabsent. Newfullmanifestad8f7d8096825f5e98023fd8d0fce4d337dbdf8c7b2f463691a2b61d2470c3fb.
Nativecrypto/copy/JACCLunchanged. Actualnativebuild/physicalencryptionstillpending.

MTP same-source build1: both native products compiled and retired naturally (worker225.263s, reference48.251s), but qualification FAILED after the reference build: its old Package.resolved specified23 different revisions across the same31 dependencies and SwiftPM materialized them in the shared cache. Source3481 unchanged; dependency guard correctly refused. Failed build receipt and logs retained. Root prepared a narrow reference-lock successor using all31 qualified worker revisions while retaining the reference originHash; no Swift runtime changes. Original wrapper/locks preserved at qwen-mtp-accepted-qualification-20260920/root-reference-lock-correction-1. New Buildmanifest f2893064bf793a397a5f3794601f8511ae975e12785644115ea9c761ea331bef; root f3f923fd0521f943d2b92db557e8cac12ab2c36c7d84d797562b4323cc28c26b. Restoration and requalification pending. No physical MTP execution.

Standalone authenticated RDMA build preparation passed a3367f653c7baa7594e5b43c7d785f2dda0a518b80c42b69d874624bea4733ff, exact3088sources/9832dependencies. Actual one-slot jobs2 compiler running. Fresh pinned strict SSH observations found both hosts Mac16,7/macOSbuild26A428. No component hardware measurement yet.

ACTUAL Qwen9B accepted-MTP PASS: build2 be40029f4e09c0899b8a3d3db2c770f56f7147c5c64d60fef98cfd135a1c8239, worker7787dad5/reference91c3cf8c, exact3481sources/8755dependencies. Fresh reference P32/C16/O8/cut4 matched off and depth1. Offresult 066171e554bdf721139cccbee7e68f06ec6c0d8ae84e5bc8c3693275beb3da44; onresult c11f6dc76cb246bb5d1710cc1353e60dbdb24666ea35672b28cab8d3fff80257. Actual3matched drafttokens/4rounds/7decodeinputs/11bilateralreceipts, final496640-byte BF16row and72states exact. All physical resource/retirement/alias checks passed. Corrected snapshot collector removes raw payload key symmetrically, retaining full identity/hash comparisons; source receipt retained. No performance/encrypted/serving claim.

ACTUAL standalone encrypted RDMA PASS: native d3440a9ac8e4b3dcf24d00841e3ea96512390fce84caf5f3388505c241f8c459; build00bc5ccc3edb6f8f53a00ae7b5a6a61d2af0a717c51b63c793316dbccbe4cf0b;14physicalcases/11sizes/3warmups+20measured per mode. All exact byte/ciphertext/counter joins and native-owner/lease/secret/alias retirement passed. Actualsummary9e49745ef959ac8348c494a63c68650921bea51dbe452b3580ceb2ea918b1a17. Two5MiB record median RTTs4.502604/4.5008545ms versus equal-size raw2.0174375/2.018021ms. Component only, not verified-product membership or model overhead.

Gemma8K actual6115 metadata PASS for serial and lookahead cut6/C64. Full solo physical FAILED after1339/1339weights loaded: actualFree17,003,610,112 B <requiredFree17,134,328,524 B by130,718,412 B; active14,913,427,828/cache0/requiredAllocator29,126,390,848/limit48,962,627,174. Parent stopped its own native66824 after diagnostic stderr; group absent, canonical journals/processes empty, no cleanup errors. Root600s supervisor retired naturally1 after19.010s. TerminalSHA256 683ebf17d12d21cdb23d38b61e50db01ade55d45086ba113bdf5acd0b74cf0e8. No timedrequest/TPS accepted and no pair run performed. All floors unchanged.

Next8K opportunity is a narrow source-proven reserve for five sliding-attention temporaries: current budget uses full maximumTokens for every layer, while actual fresh contiguous-window views are bounded by min(maximumTokens, window-1+chunk). Agent arithmetic draft predicts lower full reserve but is NOT a code change or hardware qualification. Root began tracing actual WindowedSequenceKV, AttentionV1, per-request maximumChunkTokens; full proof/new code/build remains pending. Existing capturedKV, all-layer concurrency, F32, casts, full-attention, head, host/native staging, probes, loader/allocator/free floors must remain charged. Current MAIN and6115 ledger unchanged.

Current idle checkpoint: MTP accepted-path correctness and14 encrypted-RDMA component cases completed; all physical jobs retired. Remaining independent work includes8K reserve proof/qualification, C128expert primitive/fullmodelEP performance, valid trueTPquality/performance, resident MTPthroughput/othermodels, measured planner adapter, protected product hardware admission/integration/recovery/accounting/externalSLA. Product signing/attestation configuration still unavailable.


Decode optimization, 2026-09-20: retained v7 profile found 105/103 live checks and11 completed transfers per pair decode token versus8 checks solo. First candidate reuses a locked UTC formatter while preserving every fresh OS/native/power read, guard count, memory inequality, fence and arithmetic path. Swift6/private lock qualification:13dates/4096concurrent comparisons; formatting-only~41us→0.7us locally. Native84cbea53d012b0f6405491c90a25f3daaaaec8108b3b1ca95be320f392e04f75 built from restored6115benchmark composition; fullEP successor source preserved before restoration. Initial Swift6 non-Sendable static formatter build refused; retained, corrected by private locked @uncheckedSendable holder, thenbuild2PASS.

Actual timestamp matched solo+lookahead P4096/C64/O16/cut7 PASS: solo370.659166prefill/47.770422decode; pair conservative459.768923prefill/28.544838decode. New versus solo4fullrows/360states, before/after8fullrows/720states exact, alltokens exact, every global/request/phase guardcount and same-role memorybudget exact. Allnativeparents/leases/groupsretired;aliasrestored. Comparison167414f90b8e60c3351106417dd2e1fd946d26bfe37009d09cdad2ac4ba7db63. Sharedformatter+onecallsite+exactCPUfixture promoted to MAIN only; main-integration/receipt.json preserves preimage andbytepins. NoQwennewTPSclaim.

Second separatelyqualified source replaces controlprefix+body withone16KiB padded control record. Strictlength/zero-pad/unchangedstrictJSON; all remaining P2Pfault/deadline/resource/fences retained. Adds native16KiB(actualrounded)+host32768B perstage, nofloor reductions. 18FoundationcontrolsPASS. Sourcea2d46fa985b4f78bb2dde0dcb5bae3706a3e76fd3b0154a4554ef3eeee42e343; natived7859728bbda3c1b4a0d65766e1bc44b964143d6e7b493e944fb05d3e09ca769; buildreceipt0fc99a3c809ba167edac947acea867083861807246519cd2c6741cd9831a9cc2. Freshharness-v2deploy/metadataPASS; matchedsolo currentlyrunning. NoacceptedsecondcandidateTPSyet.


ACTUAL decode control-frame v2 PASS: native d7859728bbda3c1b4a0d65766e1bc44b964143d6e7b493e944fb05d3e09ca769; final comparison0d7a84f40302cf9c1dd82b7ed51781539d77e25677930944d173ab081293382d. Solo370.435617667prefill/47.068302852decode; pair conservative454.477265404prefill/32.010095295decode, +44.110815%decode vsoriginal6115. Prefill+0.505280%vsoriginal and-1.150937%vs timestamp-only; shortP4096/C64/O16/cut7/1warm+3measured/MTPoff/plaintextlabRDMA. New4fullrows/360statecomponents exact; againstEACH earlierbaseline8rows/720components/2,351,268,800statebytes exact. AlloutputIDs exact. Allremainingcheck/fencepolicy preserved; stageglobalcountsprove1,108removedprefixes/8,864logicalchecks, decode6nativeops and65/63logicalchecks/token. Added32767actualnativebound+32768hostbytes/stage. Comparison16controlsPASS, framing18FoundationcontrolsPASS. Bothowners0/retired, journals/leaseidentities valid, aliasrestored. Freshfinalquiescence308399486ab1b3b33d5e899f88297f6d89e1b397a705b125f885ad282ca65646. Detailedhumanreportgemma4-decode-optimization-20260920/ACTUAL_RESULTS.md. No activecompiler/physicaljob remains; broadergoalunfinished.
