# 070 — independent first-principles validity audit

- Date: 2026-08-24
- Reviewer: second independent review
- Verdict: **FAIL for merge/ship; PASS for the narrowly scoped performance claim**

## Claim judgment

Notes 068/069 and `GOAL.md` have real evidence that exact reuse clears 2.5×
for these workloads:

- warm full-prompt B1/B2/B4;
- cold simultaneous B4 identical and 90%-common live forks;
- warm sequential B4 prefixes at 75% and 87.5% aligned commonality;
- construction-amortized full-prompt and high-reuse cases at the reuse counts
  now stated in the notes.

The effective-throughput denominator is legitimate for that scope:
`sum(requested prompt tokens) / burst makespan`. Each tabulated speedup is
`median(cold makespan) / median(candidate makespan)` over three iterations.
Warm-cache rows deliberately count skipped prompt tokens as completed serving
work; live-fork rows include leader compute and follower cloning. Neither is a
claim about native compute throughput for unrelated prompts.

Construction is excluded from the headline warm makespan, but is now
explicitly disclosed with construction-inclusive economics. The notes also
explicitly disclose that unrelated cold prompts remain at native baseline.
Those statements are accurate after the corrections accompanying this audit.

The broader claim that the full 2.5× objective is complete is not valid yet.

## Gate results

| Gate | Result | Evidence |
|---|---|---|
| Metric denominator | PASS, scoped | Same requested-token numerator on cold/candidate bursts; ratio of separately computed three-run median makespans. |
| Cache construction accounting | PASS after correction | Donor is separate; 8K 32-boundary donor is ~7.7–8.0 s; reuse-count break-even is stated. |
| Warm/full/partial semantics | PASS | Full hits restore frontier logits and run zero prompt forward; partial hits restore only a boundary and execute the distinct suffix. |
| Cold fork semantics | INCOMPLETE | Candidate timing includes leader/fork work and cache rows are misses, but the report has no fork activity counters and omits both fork activation flags. |
| Exact state | PASS by code/tests | Atomic snapshots contain all owning full-attention K/V, every GDN conv tail/FP32 SSM state, scalar position, and frontier logits only at a full prompt. |
| First/full token parity | PASS after E46 | Canonical block-sized singleton prefill restores 100% first-token and complete 64-token equality for every B1/B2/B4 full/partial cell. |
| Canonical/native semantic quality | PASS after E47 | Blind 128-token corpus: 11/12 continuations identical; canonical retains 224/225 adjusted points (99.56%) with zero candidate-only fatal failures. |
| Three-run medians | PASS | `iterations = 3`; archived summary medians reproduce the tabulated values. |
| Model/corpus identity | PASS | Reports contain a full model artifact SHA-256 and corpus SHA-256, with pre/post filesystem fingerprint checks. |
| Code/run provenance | PARTIAL after E41 | Sidecar binds the exact root commit, nested base/tree and patch hashes, binary/metallib/model/corpus hashes, OS and Swift; power posture is post-run, and older reports retain schema drift. |
| RAM/LRU/pinning | PASS after E48 | Pre-copy reservations evict before allocation and charge resident plus all concurrent in-flight candidates to one hard ceiling; discard/error paths release reservations. |
| Deployment budget equivalence | PASS after E41 | At the exact 2 GiB deployment ceiling, 6,144/7,168-token boundaries remain hits above 2.5×; 2,048/4,096-token boundaries are honestly evicted and miss. |
| Replayable handoff | PARTIAL | The three nested patches replay from `ab73a827...` to tree `b002398c...`; the gitlink still points at the unpatched base, so a normal recursive clone is not buildable without manual patching. |
| Deployment integration | PARTIAL | Default-off slot policy, verified identities, unified-memory carve, re-slicing, status, telemetry, daemon knobs, and a 2 GiB-equivalent performance run now exist. The nested tree is unpublished. |
| Tests/build | PARTIAL | Serving wiring runs on Apple Silicon (focused suites, release build, 2,215-test full provider suite), plus Go/UI and a valid 9-test prompt-fork suite pass. Fresh-clone CI remains blocked by the unpublished submodule. |

E41 validates against the current report schema. Historical E32–E37 reports
retain their original factory/match-policy schema drift and are not rewritten.

## State and ownership review

The durable cache is not a KV-only shortcut. Lookup validates layer layout and
the recurrent spec, pins the selected immutable entry, then creates fresh
attention and recurrent request owners. A partial adopter resumes at matched
position `M`; a full adopter samples cached frontier logits without applying
the last prompt token twice. Pin release is request-correlated on success,
fallback, cancellation, rejection, and shutdown.

The live-fork path leaves one ordinary prompt token after the fork boundary,
copies owning K/V rows into independent follower state, restores independent
recurrent wrappers, and keeps cache salt and priority in cohort compatibility.
Its design is exact, but the committed performance JSON does not record the
engine's `CBv2PromptForkActivity`, so the measured execution path is not
self-proving.

## Required actions

1. E40/E41 supply three-iteration 64-token runs, source/artifact hashes,
   captured controls, OS/Swift, and post-run power posture. A new live-fork
   report still needs activity deltas and in-run power capture.
2. Resolve identical-B2 second-token divergence or explicitly remove B2 full
   parity from the acceptance claim and justify that narrower product
   contract. The current hard goal requires correctness at B=2.
3. Publish the nested library changes to a writable remote, update the
   submodule gitlink, and run the documented tests plus release build from a
   fresh recursive clone.
4. ~~Rerun durable partial-prefix scenarios with the actual deployment cache
   ceiling.~~ E41 completes this at 2 GiB.
5. ~~Rerun the prompt-fork planner/ownership/cancellation suite with the
   correct metallib.~~ E41 passes 9/9 and archives the terminal summary.
6. Version or reconcile the report schema. Do not edit historical artifact
   provenance strings to make old JSON pass a newer validator.

## Post-audit follow-up

Completed after the initial verdict:

- E40 ran the full 8K matrix for three iterations with 64 generated tokens.
  The 75%/87.5% B4 profiles remain above target at 3.144×/5.194× and
  first-token parity is 100%.
- E40 also confirms the outstanding quality issue: full-sequence equality is
  0% for full hits and 75% for partial B4 hits.
- A sidecar now binds E40 to binary/metallib/model/corpus hashes, the root
  source equivalent, submodule base/patched tree, patch digests, OS, Swift,
  and post-run AC/high-power posture.
- The deployment slot wiring ran on Apple Silicon: 70 focused policy,
  wiring, telemetry, launch, and CLI tests pass; the release build passes;
  the complete provider suite passes 2,215 tests in 231 suites.
- Coordinator API tests and all 498 console tests pass.
- E41 pins the deployed 2 GiB ceiling: 75%/87.5% boundaries remain hits
  above 2.5×; 25%/50% boundaries are evicted and miss.
- Cache telemetry now names pre-adoption counters as lookup hits/misses and
  matched tokens rather than claiming successful saved work.
- Prompt-fork planner, independent-state, and cancellation coverage passes
  9/9 with a valid metallib.
- E43 traces divergence to donor/control chunk and packed-prefill geometry;
  E45 proves causality; E46 runs the clean canonical profile for three
  iterations and restores 100% complete 64-token parity while retaining
  2.629×/5.076× native-relative first-token speed at 75%/87.5%.
- E47 blind-scores the intentional canonical/native numerical change:
  99.56% relative quality, 11/12 exact continuations, and zero
  candidate-only fatal failures.

Still open:

- self-reported live-fork activity in a new fork performance artifact;
- publishing the nested library tree and updating the gitlink;
- sanitizing legacy benchmark artifacts/history that retain private host/user
  identifiers;
- replacing, not rewriting, historical reports whose schema identity drifted.

The scoped durable-reuse result is now decision-grade: **2.5×+ prefill and
100% 64-token parity are measured for the 75%/87.5% exact-prefix workloads.**
The branch is still not merge-ready because the nested tree is unpublished,
transient donation memory is not hard-reserved, legacy artifacts/history retain
private identifiers, and live-fork performance is not self-proving. Cache-free
unrelated prompts are unchanged; exact-cache cold misses use a slower canonical
posture.
