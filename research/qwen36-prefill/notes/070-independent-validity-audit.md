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
| First/full token parity | FAIL for decision grade | First-token parity is 100%; partial/B4 two-token sequences match. Identical B2 reports `fullTokenEqualityRate = 0`, and all decision artifacts use only `decodeTokens = 2`, not the documented 64. |
| Three-run medians | PASS | `iterations = 3`; archived summary medians reproduce the tabulated values. |
| Model/corpus identity | PASS | Reports contain a full model artifact SHA-256 and corpus SHA-256, with pre/post filesystem fingerprint checks. |
| Code/run provenance | FAIL | No root/submodule commit or patch hashes, no OS/Swift/power fields, and archived reports use a different factory identity from the checked-in v1 schema. |
| RAM/LRU/pinning | PASS for boundedness | Exact `nbytes` accounting, pre-insert eviction, hard ceiling, deterministic LRU, request-correlated pins, and cancellation release are implemented and tested. |
| Deployment budget equivalence | FAIL | Benchmark cache budget is 19,477,509,628 B and post-donor residency is 4,829,189,120 B; deployment defaults to a 1 GiB ceiling, which cannot retain the measured 32-boundary set. |
| Replayable handoff | PARTIAL | The three nested patches replay from `ab73a827...` to tree `b002398c...`; the gitlink still points at the unpatched base, so a normal recursive clone is not buildable without manual patching. |
| Deployment integration | PARTIAL | A default-off exact-cache slot policy, verified identities, unified-memory carve, re-slicing, status, telemetry, and daemon knobs now exist. The nested tree is unpublished and the deployment-budget profile is unmeasured. |
| Tests/build | FAIL as a complete gate | Archived exact cache/engine, provider report/usage, full provider suite, and release build pass. The archived prompt-fork selection aborts on a missing `metallib`; the new deployment slot wiring has not been run on a Swift-capable host. |

Current-schema validation makes the drift concrete: the partial-prefix report
fails only the factory-identity constraint. The earlier exact-hit and live-fork
reports each also omit `cacheBlockTokens` and use the retired
`exact-full-prompt` match-policy value, producing four validation errors each.

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

1. Produce a new three-iteration M3 Max report with at least 64 generated
   tokens, root and submodule commit/tree IDs, patch SHA-256s when applicable,
   captured fork controls, fork activity deltas, OS/Swift versions, and AC/high
   power posture.
2. Resolve identical-B2 second-token divergence or explicitly remove B2 full
   parity from the acceptance claim and justify that narrower product
   contract. The current hard goal requires correctness at B=2.
3. Publish the nested library changes to a writable remote, update the
   submodule gitlink, and run the documented tests plus release build from a
   fresh recursive clone.
4. Rerun durable partial-prefix scenarios with the actual production cache
   ceiling. If the measured 75%/87.5% retention requires ~4.83 GB, justify and
   configure that carve rather than citing the 1 GiB default.
5. Rerun the prompt-fork planner/ownership/cancellation suite with the correct
   `mlx.metallib`; archive a terminal test summary.
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

Still open:

- completion-quality parity or a replay posture that preserves the cold decode
  schedule;
- self-reported live-fork activity in a new fork performance artifact;
- a deployment-budget-equivalent 75%/87.5% rerun (the measured cache retained
  ~4.83 GB versus the 1 GiB default);
- publishing the nested library tree and updating the gitlink;
- replacing, not rewriting, historical reports whose schema identity drifted.

Until these are complete, the correct statement is: **2.5× is measured for
specific exact-reuse workloads; unrelated cold prompts are unchanged; the
research is not yet decision-grade or merge-ready.**
