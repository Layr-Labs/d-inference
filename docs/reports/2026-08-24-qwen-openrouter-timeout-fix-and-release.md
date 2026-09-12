# Qwen OpenRouter Timeout Fix and Release Record

> Last updated: 2026-08-24 · commit `b41435f18`

Date: 2026-08-24  
Candidate branch: `fix/qwen-ttft-release`  
Candidate HEAD inspected: `87fbe90c53de7fdf68849b11d4342fc880c400fa`  
Recommended next provider version: **`0.8.11`**

## Status at record creation

This is an engineering and release-candidate record, not evidence of shipment.

- Latest provider tag: `v0.8.10`.
- Candidate `ProviderCore.version`: `0.8.11`.
- Candidate coordinator `LatestProviderVersion` fallback: `0.8.11`.
- The source constants identify the unshipped candidate; no `v0.8.11` tag,
  signed bundle, or registered release exists.
- No tag, push, release registration, coordinator deployment, provider
  deployment, or production mutation was performed.
- The branch HEAD predates the current dirty integration. Release readiness is
  judged from the final reviewed candidate SHA and its tests, not historical PR
  status.
- `origin/master` contains provider image-limit change #666 after the
  `v0.8.10` tag. A `v0.8.11` cut from current master will include that
  post-tag change unless release scope explicitly excludes it.

[PR #681]: https://github.com/Layr-Labs/d-inference/pull/681
[PR #631]: https://github.com/Layr-Labs/d-inference/pull/631

## Sources and evidence quality

| Source | What it establishes | Qualification |
|---|---|---|
| [PR #631] | Request-absolute first-content clock design; production `client_gone` correlation; focused Go test report | Historical design/incident evidence only; current candidate code and tests supersede its old check state |
| [PR #681] | Routing-rate defect, FCFS prefill experiment, provider admission design, unit tests, and scheduler simulation | Candidate code is on this branch; the packaged signed-candidate command now exists, but no owned-hardware signed report has been captured |
| [`2026-08-19-solo-prefill-stripe-experiment.md`](2026-08-19-solo-prefill-stripe-experiment.md) | M4 Max Qwen 8K solo and 4×8K measurements | Earlier measured tree, not the final release artifact |
| [`coordinator-deploy.md`](../operations/coordinator-deploy.md) | OpenRouter uptime accounting, `error-0` timing, coordinator and provider release procedures | Operational source of truth; live production environment must still be verified |
| Current branch and worktree inspection | Exact code/version/protocol state described below | Snapshot at the timestamp above; uncommitted integration work can change |

Claims below are labeled as measured, simulated, PR-reported, or required
release evidence. They are not silently promoted between categories.

### Mutable worktree observations

The uncommitted source state inspected by this report was first fingerprinted at
`2026-08-24T21:40:46Z` against
`87fbe90c53de7fdf68849b11d4342fc880c400fa`. The owned `CHANGELOG.md` and this
report are excluded:

- root tracked/submodule diff SHA-256
  (`git diff --binary --submodule=diff`):
  `cee69086cb4d04ee1bbfa6ab306e2597e3fae0d061ff704d6d7ac4d28edb5ba2`;
- root untracked-source manifest SHA-256:
  `8beb0a7b3ed6e82c3f6f51ec528bb00c904ea91e9b00ce9420ede55905e163d6`;
- dirty `libs/mlx-swift-lm` base:
  `ab73a827c9dde6f8802507003aa0be71605aab8e`;
- dirty `libs/mlx-swift-lm` tracked-diff SHA-256:
  `9f0ea0b839dd2e17813db05c01dda84fe74c813397f5ca22cb386c7c2fa69289`.

Root untracked blob manifest:

```text
cbf4cb472fd853a5394ae17b2992c11adf73cbfa  coordinator/api/first_token_clock.go
05fc30d6822f903394e5cfd0a1be38a6d5c425a6  coordinator/api/first_token_clock_test.go
b2e3f4c9a30f9c8872144705da4e234a859a5f9b  provider-swift/Tests/ProviderCoreTests/FirstContentDeadlineTests.swift
2d3225bec72fa358c5d61b27d2bea95f5660cc13  provider-swift/Tests/ProviderCoreTests/SchedulerPrefillDecisionBenchmarkTests.swift
```

Dirty submodule untracked blob manifest:

```text
8e133c2d113cbcdf44ff8714eef66f9613e29a34  Libraries/MLXLMCommon/ContinuousBatchingV2/FirstTokenDeadlineAdmissionV2.swift
7b9f7f7accfc470f156111f6509b45a602346eb8  Tests/MLXLMTests/CBv2FirstTokenDeadlineAdmissionTests.swift
```

The submodule changed during documentation review. A second observation at
`2026-08-24T21:44:04Z` recorded:

- root tracked/submodule diff SHA-256:
  `8d74fd30281cd3626fad09a17423bf6b0f644ac4a6ce37bb7b4e012fbbd4abb1`;
- unchanged root untracked-source manifest SHA-256:
  `8beb0a7b3ed6e82c3f6f51ec528bb00c904ea91e9b00ce9420ede55905e163d6`;
- submodule tracked-diff SHA-256:
  `41068c11dd80f5d5631be5e0a5cdf95047860e50cae4f69ee68ed3ee8ebba4dc`;
- submodule untracked blobs:
  `c706e10072f85ecf69e036ee8612d0596dc0c69b` and
  `15e97d68b250952e60eb1d82d481fcecaec6554f`.

These are timestamped observations, not a claim that a concurrently edited
worktree is frozen. A later mismatch is expected and is itself evidence for the
clean-commit blocker. The reviewed integration commit and tree ID, not any
mutable-worktree hash above, must become the release identity.

## Incident evidence

### External symptom

- PR #681 reports Qwen3.6 35B OpenRouter timeouts being scored as approximately
  **10–11% downtime**.
- PR #631 reports approximately **11,000 `client_gone` rows in 24 hours**
  fitting `10,000 ms + 1 ms × prompt_tokens` within ±250 ms while the
  coordinator could continue waiting up to 600 seconds after
  `inference_accepted`.
- The deploy runbook independently records that OpenRouter drops connections at
  approximately 10 seconds when no response bytes arrive, with observed samples
  at 9.99–10.4 seconds. OpenRouter uptime is documented as
  `success / (success + error-0 + 5xx)`, excluding 429/422/400.

The PR #631 telemetry query and PR #681 OpenRouter dashboard slice were not
rerun while writing this record. Their raw query text, time range, and result
export must be attached in the evidence ledger before release.

### Provider-side burst mechanism

The earlier M4 Max Qwen experiment measured:

- one 8K prefill at **5,350.2 ms**, approximately **1,531 tok/s**, for the
  trust + solo-stripe posture;
- four concurrent 8K prefills at **24.98 seconds each** under fair
  512-token interleave;
- approximately one-request aggregate prefill throughput under the burst,
  because rows execute separate forwards.

The failure is scheduling, not insufficient aggregate work rate. Fair
interleave makes every row finish at the burst makespan. FCFS uses the same
32,768 prompt tokens but creates a completion staircase.

PR #681's real-`SchedulerV2` simulation at 1,531 tok/s reports:

| Policy | Row TTFTs | Deadline outcome |
|---|---|---|
| Unlimited partial-prefill interleave | 21,403 / 21,403 / 21,403 / 21,403 ms | 0 of 4 land |
| FCFS partial-prefill cap of 1 | 5,351 / 10,702 / 16,052 / 21,403 ms | first 3 land; fourth misses |
| FCFS plus submit-time admission | first 3 admitted; fourth refused | no local timeout; fourth can be redispatched |

This table is the original PR #681 simulation, not a candidate-binary
wall-clock result. The current integration carries the coordinator's actual
remaining clock to the provider and also includes atomic queue/rate projection:
`EngineV2Bridge` records a queue-excluded isolated-prefill EWMA and passes a
conservative rate plus the unchanged monotonic deadline into the engine's
atomic first-token admission API. Forecast rejection is default-off behind
`DARKBLOOM_PREFILL_DEADLINE_MODE=enforce`, so the early fourth-row redispatch
claim still requires enabled-mode candidate evidence.

There is also a material assumption the original simulation does not prove:
cap=1 removes same-length packed-prefill cohorts that cap=0 can present to
Qwen. Equal scheduler token counts do not imply equal Metal wall time. A new
deterministic decision matrix exposes packed-prefill eligibility, staggered
arrivals, mixed long-first head-of-line cost, and active-decode contention, but
the live-model half remains required release evidence.

### Coordinator-side routing mechanism

Before PR #681, `buildCandidateWithReason` priced the base prompt-prefill cost
with static `snap.prefillTPS`. Adjacent TTFT calculations resolved through
`resolvePrefillTPS`, which prefers the slot's measured prefill EWMA. Selection
and deadline estimation therefore used different models of the same provider.

PR #681 reports a 36-case sweep in which provider selection changed in all
36 cases, 10 pre-fix selections breached the approximate deadline while a
compliant provider was available, and the worst selection was approximately
133 seconds versus an available 13-second provider. This is generated
regression/sweep evidence, not a production A/B.

### Coordinator-side clock mechanism

`inference_accepted` is an acknowledgment, not a content token. PR #631 made
the first-content clock request-absolute from `ReceivedAt`, but its reviewed
revision had open paths where:

- a claimed provider write can outlive the request clock;
- queue wait is not bounded by the request clock;
- a write-deadline expiry can surface incorrectly on generic endpoints;
- stall-breaker accounting can omit an attributable initial race window.

Those findings prevent the historical PR revision from being treated as
complete evidence. The current worktree integrates the absolute clock across
queueing, provider-writer handoff, speculative dispatch, terminal arbitration,
cancellation, and endpoint response mapping; it still needs final immutable-SHA
and mixed-version/E2E verification.

## First-principles invariant

The system must enforce one monotonic first-content budget across every layer:

1. Define the external target from request receipt, not from a later phase:
   `D_external ≈ received_at + 10,000 ms + 1 ms × prompt_tokens`.
2. The coordinator uses an internal deadline inside that external target.
   The checked-in production reference sets the live base to 9,000 ms. The
   authoritative `/etc/d-inference/env` value must be recorded before rollout.
3. At every queue, encryption, dispatch, provider-write, acceptance, preamble,
   and speculative-race boundary:
   `remaining = max(0, D_coordinator - now)`.
   No boundary may replace `remaining` with a fresh full timeout.
4. Only a content-bearing first token satisfies the clock. HTTP 200,
   keepalives, role-only deltas, response-created frames, and
   `inference_accepted` do not.
5. Routing cost and TTFT estimation must use the same measured-preferred
   prefill signal, with a static fallback only when no observation exists.
6. A provider receiving an exact positive remaining budget converts it once to
   a monotonic deadline. It must not begin a new expensive pre-content phase
   after that deadline.
7. A forecast may reject before actual expiry only if its service-rate and
   queue semantics are independently proven. A projection that adds queued
   work cannot divide by a load-inclusive rate because that counts queue wait
   twice. The integrated default-off forecast uses a separately sampled,
   queue-excluded isolated-prefill EWMA and forms its verdict atomically from
   the engine's current queue snapshot.
8. When the remaining budget is absent, compatibility behavior is fail-open;
   the coordinator's request clock remains authoritative.
9. Expiry after dispatch must cancel and remove provider work before client
   refund/terminal settlement. No orphan generation or later settlement may
   survive a returned 429.
10. A local clock expiry is not automatically provider sickness. Provider
   breakers are charged only when that provider received a complete
   attributable wait window.
11. A pre-content deadline refusal uses transient capacity semantics. A genuine
    fault remains a 5xx; this work must not hide faults by relabeling them as
    capacity.

The desired outcome is not "make every prefill faster." It is: serve content
inside the absolute clock, redispatch before the clock when another provider
can serve, or return a retryable capacity response without leaking work.

## Current worktree integration

### PR #681: present on candidate branch, not shipped

Coordinator:

- `coordinator/registry/scheduler.go` resolves prefill TPS once and uses it for
  both the base request cost and long-prompt term.
- `coordinator/registry/long_prompt_test.go` proves default-threshold routing
  selects the provider with the better observed rate and preserves cost
  breakdown accounting.

Provider:

- `EngineV2Factory.maxConcurrentPartialPrefills` defaults to `1` globally for
  every production CBv2 model.
- `DARKBLOOM_CBV2_MAX_PARTIAL_PREFILLS=0` is the immediate rollback to
  historical unlimited interleave. Other explicit non-positive or unparseable
  values also fail open to unlimited behavior; an absent value keeps cap 1.
- `EngineV2Bridge` keeps the wire-facing load-inclusive
  `observed_prefill_tps` unchanged and separately records a queue-excluded
  isolated-prefill EWMA for atomic first-token projection.
- The provider passes the conservative isolated-prefill rate, optional decode
  rate, and unchanged absolute deadline into the engine's atomic admission API.
  Forecast enforcement remains default-off unless
  `DARKBLOOM_PREFILL_DEADLINE_MODE=enforce` is selected.
- The original scheduler simulation proves TTFT ordering and equal prompt-token
  work, not equal hardware throughput. Cap=1 makes Qwen packed-prefill cohorts
  scheduler-ineligible. v0.8.11 nevertheless flips the global production
  default to cap 1 by explicit release decision; cap 0 is the rollback.

### Absolute first-content clock: integrated in the current worktree

The current integration:

- preserves one request-absolute `FirstContentDeadline` through all endpoint
  paths;
- bounds coordinator queue wait and queued/in-flight provider writes;
- launches speculative backup from the absolute speculative point;
- gives already-buffered content priority over simultaneous timer expiry;
- cancels dispatched work before returning the common retryable
  `429` + `Retry-After` + `rate_limit_exceeded` response;
- keeps coordinator-owned expiry out of provider-fault breakers while
  preserving provider-attributable stall accounting;
- covers chat completions, completions, Responses, and Anthropic Messages.

The remaining blockers are evidence and release-state blockers, not missing
clock wiring: freeze the dirty worktree into one reviewed immutable SHA, rerun
focused/full coordinator and provider tests, execute mixed-version and system
E2E coverage, and validate the signed artifact and canary.

### Current deadline/protocol integration: wired but uncommitted

The inspected worktree adds `first_content_budget_ms` as optional outer
`inference_request` metadata in:

- `coordinator/protocol/messages.go`;
- `provider-swift/Sources/ProviderCore/Protocol/Messages.swift`;
- coordinator provider-wire construction;
- Go and Swift round-trip/omission tests.

The field carries positive milliseconds remaining for the dispatch attempt.
Zero or unavailable values are omitted. The local provider integration:

- converts the relative value exactly once at frame receipt to
  `ContinuousClock.Instant`;
- rechecks it before decrypt, after admission suspensions, after model load,
  around cache/KV reservation, and immediately before engine submission;
- releases accepted/pre-submit resources before returning transient capacity.

These checks prevent a new pre-submit phase from starting after expiry. They do
not install a provider-local watchdog after `engine.submit`; the coordinator's
absolute timer and cancellation path remain authoritative for submitted work.

The current coordinator production path stamps one absolute
`FirstContentDeadline` and defers outer-frame construction until the provider
writer dequeues the data-lane item. `providerInferenceFrameBuilder` recomputes
the positive millisecond remainder at that handoff and refuses an expired
frame, so writer queue time cannot be hidden from the provider.

Dedicated provider deadline tests and an opt-in production-CBv2 Qwen evaluation
harness now exist locally. The harness compares cap 0 with cap 1, binds output
to config and checkpoint aggregate hashes, excludes the local model path,
records source/binary/build/hardware/OS/power/thermal identity, and applies
explicit throughput and TTFT criteria. The Swift-test entry remains unsigned;
the packaged `darkbloom benchmark --scheduler-prefill-decision` entry can emit
signed model-family evidence only after its app/signature/hash/version preflight.
Complete mixed-version execution tests remain required.

## Explicit non-goals

- No claim that Qwen prefill tok/s is improved.
- No change to model weights, model registration, aliases, templates, MTP,
  vision, prefix-cache policy, billing prices, or provider payouts.
- No change to OpenRouter's external deadline or uptime formula.
- No blanket conversion of faults to 429. Panics, backend crashes, corrupt
  models, and unknown failures remain visible 5xx classes.
- No minimum-provider-version increase solely for this change.
- No removal or semantic change to `observed_prefill_tps`; it remains
  load-inclusive on the wire.
- No claim that forecast-based "cannot land" refusal is enabled by default.
  The atomic forecast API, queue-excluded EWMA, and provider wiring are
  integrated, but `DARKBLOOM_PREFILL_DEADLINE_MODE` defaults to `off`; exact
  remaining-budget conservation applies independently.
- No provider-local promise to terminate a row already submitted before its
  propagated deadline. Post-submit termination remains the coordinator
  cancellation contract unless a separately reviewed provider watchdog is
  added.
- No claim that FCFS preserves wall-clock aggregate throughput. It preserves
  scheduler prompt-token work but can disable packed prefill and delay a short
  prompt behind a long one.
- No claim that global FCFS has passed release-candidate evidence. The factory
  defaults every CBv2 model to cap 1 by explicit release decision, with exact
  cap 0 as the immediate operational rollback.
- No attempt to fix the separate coordinator-side queue/load-inclusive
  double-count noted in PR #681 unless it is explicitly added, reviewed, and
  measured as separate scope.
- No promise that a provider refusal always yields success. Redispatch depends
  on another eligible provider; otherwise the caller receives bounded
  transient capacity.
- No production tag, release, deploy, traffic mutation, or provider-fleet
  mutation as part of documentation work.
- No redesign of the release workflow's upload/register sequencing in this
  candidate. Its canary limitation is recorded below.

## Protocol compatibility

PR #681 by itself has no new message type or required wire field. It preserves
the existing queue-full error vocabulary and keeps
`observed_prefill_tps` semantics unchanged.

The current integration adds one optional scalar:

```text
inference_request.first_content_budget_ms: positive integer milliseconds
```

Compatibility requirements:

| Coordinator | Provider | Required behavior |
|---|---|---|
| Old | Old | Existing behavior |
| Old | New | Field absent; new provider fails open and continues to honor its local safety gates |
| New | Old | Old provider ignores the unknown outer field; coordinator clock and cancellation remain authoritative |
| New | New | Provider converts the positive remaining attempt budget once to a monotonic deadline and refuses new expired pre-submit phases; coordinator remains final authority after submit |

Release gates:

- Go and Swift names, signedness, units, optionality, and outer-envelope
  placement are byte-for-byte symmetric.
- Non-positive values are omitted, never transmitted as a deadline.
- Missing field decodes as zero/nil and does not reject a request.
- Unknown future outer fields remain tolerated.
- The coordinator computes and assigns the field at actual data-lane wire
  handoff, after coordinator and writer queueing, for every primary, retry, and
  speculative attempt. A context that expires before handoff drops the frame.
- The provider carries one absolute local instant through all suspension
  points before submission; no load/cache/engine layer reconstructs a fresh
  relative timeout.
- After engine submission, the coordinator's absolute timer must cancel the
  attempt and the provider must honor that cancel. The optional field does not
  replace this path.
- No prompt content or token count is added to plaintext metadata; the field is
  only a duration. Request-body encryption is unchanged.
- No capability floor is required if real old-provider decoding confirms
  unknown-field tolerance. If that test fails, sending must be version-gated
  before release.

The PR #631 statement "no protocol/interface changes" does not describe the
current candidate. The optional field is declared and tested as an additive
protocol change.

## Test matrix

### Evidence already observed

| Area | Observed result | Release interpretation |
|---|---|---|
| PR #681 coordinator regression | Focused routing test reported passing and failing without the fix | Useful regression evidence |
| PR #681 provider suites | 18/18 focused tests for its original predicted gate reported passing | The atomic gate is integrated default-off, but historical PR results do not replace final-candidate reruns |
| PR #681 scheduler burst | Real `SchedulerV2` simulation reports three admits and one refusal | Simulation only |
| Real Qwen cap-0/cap-1 attempt | Aborted after approximately 27 minutes when battery reached 13%; no JSON artifact was produced | Not evidence; retain as a failed attempt |
| PR #631 focused Go tests | PR body reports the selected clock tests passing | Stale until rebased integration reruns |
| PR #631 coordinator CI | Coordinator lint/tests and provider tests passed on `f7a77c9` | Superseded by unresolved review findings |
| PR #631 E2E | `TestIntegration_NonStreamingInference` expected 200 and received 429 after a 5.014-second first-response timeout | Must be resolved or explicitly re-specified |
| PR #631 threat review | Failed because the workflow's Anthropic API key returned 401 | Infrastructure failure; rerun still required |
| PR #681 GitHub status | Merge blocked/review required; only Vercel authorization failures were present, with no completed full backend CI set | Full candidate CI is absent |
| Current coordinator API/registry packages | Focused writer-handoff integration tests passed locally (`api` 97.938s, `registry` 1.767s) on 2026-08-24 | Useful current-worktree evidence, not full coordinator CI |
| Current protocol integration | Schema mirrors, production writer-dequeue refresh, provider consumption, atomic admission, and focused deadline tests exist locally | Wiring is integrated; final immutable-SHA mixed-version and E2E evidence remains required |
| Current FCFS policy evaluator | Normal unit tests are defined for matrix arithmetic, the 5% throughput floor, TTFT criteria, model-hash binding, and path privacy; the live suite remains opt-in | Those unit tests must pass on the final candidate even when the live suite skips; no live artifact exists |

### Required pre-release matrix

| Layer | Required command or exercise | Pass condition |
|---|---|---|
| Source hygiene | `git diff --check` and clean release worktree | No whitespace errors; only reviewed release files |
| Version integrity | `./scripts/check-release-version.sh 0.8.11` | Provider and coordinator constants equal `0.8.11` |
| Installer embedding | `./scripts/sync-install-embed.sh check` | Embedded installer matches source |
| Coordinator focused | Clock, routing, queue, write, speculative, cancellation, breaker, and protocol tests | All pass, including regression failure when fixes are removed |
| Coordinator full | `make coordinator-test` | All packages pass |
| Coordinator build | `make coordinator-build-linux` | Linux amd64 production binary builds |
| Provider focused | Exact pre-submit deadline propagation/cleanup, coordinator-cancel after submit, FCFS wiring, decision matrix, protocol symmetry, update/error mapping | All pass |
| Provider full | `make provider-test` and `make provider-build` | Full Swift tests and build pass |
| Mixed-version | old/new and new/old coordinator/provider matrix | No decode failure; absent field fails open; deadline cancellation remains correct |
| System E2E | `make e2e-integration` with production-like deadline configuration | All endpoint families pass; no orphan work or double settlement |
| Real Qwen FCFS research | Packaged signed-candidate command on representative Apple Silicon | All five workloads under caps 0 and 1 pass the policy criteria; signed Qwen output is model-family evidence, not global certification |
| Other CBv2 models | Required for this global default-on candidate: representative latency/throughput/head-of-line matrix for every affected family, unless policy is reviewed and model-scoped | No material regression or unexplained head-of-line failure |
| Release artifact | Dev `release-swift.yml` run | Build, signing, notarization, post-sign hashes, packaged smoke, upload, and dev registration pass |
| Rollback | Coordinator image fallback, FCFS escape, optional-field omission, and release-deactivation drill | Previous service restored without incompatible state or release-discovery ambiguity |

The PR #631 E2E failure must not be waived as "expected" without proving the
test's deadline/configuration differs from production policy. It may reveal a
stale test, a too-short default, or a real cold-start regression; only evidence
can distinguish those cases.

## Canary gates

### Gate A: source and artifact

- The reviewed release-PR tree ID equals the final squash-merged master tree
  ID; pre-merge test evidence names that tree.
- The final candidate SHA is fixed and equals dev workflow `headSha`, deployed
  coordinator `build_commit`, provider tag target, and production workflow
  `headSha`.
- `ProviderCore.version`, `LatestProviderVersion`, requested workflow version,
  binary `--version`, app plist versions, and tag all equal `0.8.11`.
- Full local/CI matrix is green.
- Dev release workflow records signed binary, bundle, and metallib hashes after
  signing/notarization.
- `GET /v1/releases/latest` in dev returns the exact recorded dev bundle.

### Gate B: owned Apple Silicon CBv2 canary

Run v0.8.10 and the signed candidate on the same representative host, model,
power posture, model cache posture, prompt corpus, and concurrency schedule.
Record `pmset -g batt` and power mode. Low Power Mode results are a separate
posture and cannot be compared to High Power Mode controls.

Minimum exercises:

- 10 cold 1×8K prompts per arm;
- a two-provider burst in which the fourth row can be redispatched;
- short prompt behind a long prefill queue;
- absent deadline metadata fail-open;
- expired positive deadline before decrypt, after model load, after cache/KV
  reservation, and before engine submit;
- a row submitted just before expiry, proving coordinator cancellation stops it
  if no content arrives;
- production factory default resolves to cap 1;
- exact cap-0 override restores unlimited partial-prefill interleave;
- coordinator cancellation after deadline.

Pass conditions:

- no provider crash, restart, Metal allocation failure, or memory-growth trend;
- no content-bearing first token after its coordinator absolute deadline is
  counted as success;
- no in-flight request remains after a terminal deadline 429;
- no post-429 billing settlement occurs for the cancelled attempt;
- with an eligible peer, speculation/failover either produces content or the
  coordinator returns 429 before the external deadline;
- no engine submission begins after an already-expired propagated deadline,
  and coordinator cancellation stops a row that was submitted before expiry
  but remains pre-content at the absolute deadline;
- kill switches restore their documented pre-change behavior.

### FCFS default-on release gate

This gate is required before shipping v0.8.11 because the candidate now makes
cap 1 the production default for every CBv2 model. The aborted battery run did
not produce an artifact and does not satisfy any part of this gate.

Run at least 10 iterations of 4×4K, 4×8K, staggered 4×8K, mixed long-first, and
active-decode-plus-4×4K under caps 0 and 1 on the same representative host,
checkpoint, backend, source SHA, binary, power mode, and thermal posture.
The local Swift-test harness is exploratory evidence only. The final evidence
must be captured again against the externally built, signed provider candidate
and bind the provider binary hash and checkpoint aggregate hash.

Pass conditions:

- cap-1 median aggregate prompt throughput is at least 95% of cap 0 for every
  workload;
- cap 1 produces a strict TTFT staircase and improves mean median-row TTFT by at
  least 25% for both equal-length burst workloads;
- at least three 4×8K cap-1 rows land inside
  `10,000 ms + 1 ms × prompt_tokens`, and cap 1 lands more rows than cap 0;
- the 1K row behind the long-first mixed queue remains inside its own
  `10,000 ms + 1 ms × prompt_tokens` budget;
- packed-prefill support and execution counters are recorded for every live
  cell; scheduler eligibility alone is not execution evidence;
- all affected non-Qwen CBv2 families pass representative burst,
  short-behind-long, latency, and throughput comparisons, unless a separately
  reviewed implementation scopes the policy by model;
- no debug, unsigned, skipped, aborted, path-leaking, identity-free, or
  incomplete run is accepted as release evidence.

### Gate C: dev environment

Hold at least 30 minutes and observe at least 100 Qwen requests spanning prompt
buckets and burst traffic.

Pass conditions:

- zero unexpected 5xx from the candidate paths;
- zero `client_gone` events clustered on the external deadline line;
- zero provider breaker/cooldown events caused only by coordinator clock expiry;
- zero orphaned requests after deadline responses;
- no decrease in final request success versus the immediately preceding
  comparable window;
- transient queue-full/refusal counts are explainable by successful redispatch
  or a final bounded 429;
- old and new providers remain simultaneously routable.

### Gate D: production coordinator

Deploy the reviewed coordinator image first through the human-only drain/swap
runbook. Hold at least 30 minutes and 100 relevant requests before creating the
provider tag.

Pass conditions:

- health remains green and provider registry repopulates;
- no deployment 5xx window;
- no increase in `error-0 + 5xx`;
- first-content timeout responses use 429 with `Retry-After`;
- provider writes/queue waits terminate at the absolute clock;
- the previous immutable marker-safe image remains available.

### Gate E: production provider release

The current workflow uploads and immediately registers the release as latest.
Registration exposes it to install, startup update, manual update, and
background auto-update discovery. Background update starts after an initial
five-minute delay, then checks every 30 minutes, with a default rollout jitter
up to five minutes. This is not a hard production canary partition.

Therefore:

- the dev/owned-hardware canary is mandatory before the prod tag;
- the prod tag is the rollout start, not an artifact-only staging action;
- an operator must watch the first upgraded providers continuously;
- any gate violation below triggers immediate discovery stop and rollback.

A true limited production canary requires a separate upload/sign phase from
release registration or an explicit provider allowlist. That control does not
exist in the inspected workflow and is a release-management blocker if a
strict production partition is required.

## Rollback controls

### Coordinator

- Record the exact candidate image digest and previous marker-safe fallback
  digest before swap.
- Preserve the complete production environment and persistent-data mount.
- On a coordinator regression, use the human-only fallback-container procedure
  in [`coordinator-deploy.md`](../operations/coordinator-deploy.md). Do not use
  a mutable tag or an image predating required database migration markers.
- The candidate adds no intended database migration, so rollback compatibility
  depends on keeping unrelated migrations out of the integration commit.

### Provider behavior

- Partial-prefill cap 1 is the provider default. Set
  `DARKBLOOM_CBV2_MAX_PARTIAL_PREFILLS=0` and restart to immediately restore
  historical unlimited interleave. Unsetting the variable re-enables cap 1.
- Provider deadline admission is already off by default. Unset
  `DARKBLOOM_PREFILL_DEADLINE_MODE` (or set exact `off`) to disarm an
  `enforce` experiment.
- The legacy `DARKBLOOM_PREFILL_DEADLINE_BASE_MS` predictor is not the control
  for the integrated atomic API. Exact
  `DARKBLOOM_PREFILL_DEADLINE_MODE=off` disables forecast enforcement; the
  coordinator's absolute expiry and cancellation remain authoritative.
- To stop propagated-deadline behavior before a provider patch is available,
  roll the coordinator back to an image that omits the optional field. New
  providers then take the documented absent-field fail-open path.
- Both experimental controls are per-provider, not coordinator-wide instant
  fleet switches.

### Provider release discovery

`./scripts/admin.sh releases deactivate 0.8.11` deactivates the release row and
causes the highest remaining active semver to become latest. Before using it:

- verify `v0.8.10` is still active and its artifact is available;
- understand that binary-hash enforcement rejects non-forced deactivation
  while connected providers use the candidate hash;
- treat any forced deactivation as a separate explicit human decision.

The convenience command cannot send `force`. If urgent containment is
explicitly human-approved after a 409 `release_in_use`, the executable force
path is:

```bash
./scripts/admin.sh raw DELETE /v1/admin/releases \
  '{"version":"0.8.11","platform":"macos-arm64","force":true}'
./scripts/admin.sh releases latest macos-arm64
```

Require the second command to report `0.8.10`. Forced deactivation removes the
candidate hash from the active-release policy and can prevent candidate
providers from reconnecting; that is containment, not a downgrade.

Deactivation stops new discovery; it does **not** downgrade providers already
running `0.8.11`, because the self-updater only moves to a newer semantic
version. It also cannot recall a bundle an updater already downloaded before
deactivation. Inventory active update attempts, wait through or stop controlled
canary processes before forcing, and assume any staged candidate may still
install. A fleet rollback after installation therefore requires either:

- the local update-recovery path when startup validation itself fails;
- controlled manual rollback of owned canaries; or
- a strictly newer patch release, normally `0.8.12`, containing the reviewed
  revert.

For a latency regression that starts successfully, the reliable fleet control
is a roll-forward patch. Prepare the revert commit and tag text before
publishing `v0.8.11`.

## Release blockers recorded on 2026-08-24

1. **The release worktree is not clean.** Concurrent integration edits must be
   reviewed as code and frozen into one immutable candidate SHA.
2. **The final coordinator/provider, mixed-version, protocol, E2E, and release
   builds are not yet all green on that immutable SHA.**
3. **No signed v0.8.11 candidate artifact or valid FCFS decision report
   exists.** The aborted 27-minute battery run produced no artifact and
   certifies nothing; default-on FCFS cannot clear its release gate from
   simulation or an unsigned debug run.
4. **Candidate source constants are `0.8.11`, but no shipped `v0.8.11`
   artifact exists.** The latest provider tag and release remain `v0.8.10`;
   source-version alignment is necessary but is not shipment evidence.
5. **The authoritative production first-content base is not captured here.**
   A sanitized environment reference is not proof of the live value.
6. **Production registration is immediately global discovery.** There is no
   built-in artifact-only production stage or provider allowlist.
7. **Post-tag scope must be explicit.** Current master includes post-v0.8.10
   changes that will be part of any release cut from master.

Missing FCFS evidence is a v0.8.11 blocker because FCFS is now default-on
globally. The required signed-candidate Qwen matrix and representative non-Qwen
comparisons remain outstanding.

No release should proceed while any blocker above remains unresolved or
explicitly accepted by the human release owner with attached evidence.

## Exact human release steps

These steps are instructions for a human release owner. They were not executed
while preparing this record.

### 1. Finish and review integration

1. Resolve every current correctness finding with regression tests.
2. Verify the optional budget is refreshed at provider-writer wire handoff for
   primary, queued, retry, and speculative dispatch.
3. Preserve provider pre-submit checks and coordinator post-submit absolute
   cancellation; test both ownership boundaries.
4. Keep provider deadline enforcement default-off, FCFS cap 1 default-on, and
   the exact cap-0 rollback wired and tested.
5. Run mixed-version tests before introducing any version floor.
6. Confirm the release diff contains only the intended v0.8.11 scope.
7. Put all unmerged release work into one reviewed release PR. Squash-merge it
   onto current master; do not rewrite already-pushed post-v0.8.10 history.

### 2. Finalize the recommended patch version

The next patch is **v0.8.11**. The candidate branch already sets both source
constants to `0.8.11`:

- `provider-swift/Sources/ProviderCore/ProviderCore.swift`
  (`ProviderCore.version`);
- `coordinator/api/server.go` (`LatestProviderVersion`).

Verify they remain aligned on the final reviewed SHA; do not bump them again.

Convert the `CHANGELOG.md` candidate section into a shipped `v0.8.11` entry in
that same final release PR only when the release owner is ready to create the
immutable release SHA. Preserve this report as the evidence schema. If a
post-merge gate fails before tagging, restore the changelog's candidate status
in a new commit; never amend or retag.

### 3. Validate and publish one immutable source SHA

Run on the final, committed release-PR head:

```bash
git fetch origin --tags
git status --short
git log --oneline v0.8.10..HEAD

./scripts/check-release-version.sh 0.8.11
./scripts/sync-install-embed.sh check
git diff --check

make coordinator-test
make coordinator-build-linux
make provider-test
make provider-build
make e2e-integration

# Optional local FCFS policy evaluation. This is not signed-candidate evidence.
DARKBLOOM_QWEN_FCFS_LIVE=1 \
DARKBLOOM_QWEN_FCFS_MODEL_PATH="$QWEN_MODEL_PATH" \
DARKBLOOM_QWEN_FCFS_MODEL_ID="$QWEN_MODEL_ID" \
DARKBLOOM_QWEN_FCFS_EXPECTED_MODEL_HASH="$QWEN_MODEL_HASH" \
DARKBLOOM_QWEN_FCFS_SOURCE_SHA="$(git rev-parse HEAD)" \
DARKBLOOM_QWEN_FCFS_ITERATIONS=10 \
DARKBLOOM_QWEN_FCFS_OUTPUT="$QWEN_REPORT_PATH" \
  swift test --package-path provider-swift \
  --filter SchedulerPrefillDecisionLiveTests

git rev-parse HEAD^{tree} | tee /tmp/v0.8.11-reviewed-tree
```

`git status --short` must be empty. The local FCFS harness refuses to start off
AC power, in Low Power Mode, or under serious/critical thermal pressure. Its
unsigned output can diagnose policy behavior but cannot clear the v0.8.11
default-on release gate. The matrix must be rerun against the externally built,
signed candidate and include the cross-model evidence required above.

After extracting the notarized workflow artifact onto the owned AC-powered
Apple Silicon host, run the signed app main executable itself:

```bash
"$SIGNED_APP/Contents/MacOS/darkbloom" benchmark \
  --scheduler-prefill-decision \
  --model "$QWEN_MODEL_ID" \
  --expected-model-aggregate-sha256 "$QWEN_MODEL_AGGREGATE_SHA256" \
  --expected-registered-binary-sha256 "$REGISTERED_DARKBLOOM_SHA256" \
  --expected-version 0.8.11 \
  --source-sha "$candidate_sha" \
  --decision-iterations 10 \
  --kv-backend auto \
  --output "$QWEN_SIGNED_REPORT"
```

`REGISTERED_DARKBLOOM_SHA256` must be the exact post-sign hash registered for
the release, not a locally rebuilt binary. The command accepts only the
canonical registry model ID and resolves its Hugging Face snapshot internally;
there is no model-path option and no path in the JSON. Exit `0` means the
packaged identity and Qwen policy criteria passed, `1` means measured policy
criteria failed, and `2` means identity/evidence was invalid or insufficient.
Even exit `0` leaves `releaseCandidateCertified=false`: the owned-hardware
10-iteration Qwen artifact and representative signed non-Qwen family matrices
both remain mandatory before release.

Squash-merge the reviewed release PR. Then fetch the resulting master without
making any further source change:

```bash
git fetch origin --tags
git switch master
git pull --ff-only origin master

candidate_sha="$(git rev-parse HEAD)"
test "$candidate_sha" = "$(git rev-parse origin/master)"
test "$(git rev-parse HEAD^{tree})" = "$(< /tmp/v0.8.11-reviewed-tree)"
test -z "$(git status --porcelain)"
git diff --check v0.8.10..HEAD
./scripts/check-release-version.sh 0.8.11
```

Record `candidate_sha` and the tree ID. From this point through coordinator
deployment and provider tagging, no commit may move `origin/master`.

### 4. Publish and canary in dev

The squash merge above has already pushed the final commit to remote master and
triggered the dev coordinator deployment plus production image build. Dispatch
the dev provider workflow against that remote ref, then identify its exact run:

```bash
before_run_id="$(gh run list \
  --workflow release-swift.yml \
  --event workflow_dispatch \
  --limit 1 \
  --json databaseId \
  --jq '.[0].databaseId // 0')"

gh workflow run release-swift.yml \
  --ref master \
  -f environment=dev \
  -f version_override=0.8.11

run_id=""
for _ in $(seq 1 30); do
  run_id="$(gh run list \
    --workflow release-swift.yml \
    --event workflow_dispatch \
    --commit "$candidate_sha" \
    --limit 20 \
    --json databaseId,headSha \
    --jq "[.[] | select(
      .databaseId > $before_run_id and
      .headSha == \"$candidate_sha\"
    )] | first | .databaseId // empty")"
  test -n "$run_id" && break
  sleep 2
done
test -n "$run_id"
test "$(gh run view "$run_id" --json headSha --jq .headSha)" = "$candidate_sha"
gh run watch "$run_id" --exit-status
```

Require the dev coordinator to run the same commit, then verify the registered
bundle and every published hash:

```bash
dev_commit=""
for _ in $(seq 1 60); do
  dev_commit="$(curl -fsS https://api.dev.darkbloom.xyz/health \
    | jq -r .build_commit)"
  test "$dev_commit" = "$candidate_sha" && break
  sleep 10
done
test "$dev_commit" = "$candidate_sha"

release_json="$(curl -fsS \
  'https://api.dev.darkbloom.xyz/v1/releases/latest?platform=macos-arm64')"
printf '%s' "$release_json" | jq -e '.version == "0.8.11"'

artifact_dir="$(mktemp -d)"
curl -fsSL "$(printf '%s' "$release_json" | jq -r .url)" \
  -o "$artifact_dir/bundle.tar.gz"
tar xzf "$artifact_dir/bundle.tar.gz" -C "$artifact_dir"
test "$(shasum -a 256 "$artifact_dir/bundle.tar.gz" | awk '{print $1}')" = \
  "$(printf '%s' "$release_json" | jq -r .bundle_hash)"
test "$(shasum -a 256 "$artifact_dir/bin/darkbloom" | awk '{print $1}')" = \
  "$(printf '%s' "$release_json" | jq -r .binary_hash)"
test "$(shasum -a 256 "$artifact_dir/bin/mlx.metallib" | awk '{print $1}')" = \
  "$(printf '%s' "$release_json" | jq -r .metallib_hash)"
rm -rf "$artifact_dir"
```

Wait for the signed-artifact checks, owned-hardware deadline/default-on
canary, and 30-minute dev gate to pass. Keep the workflow run ID, run log, dev
health JSON, release JSON, and canary output as immutable evidence.

### 5. Deploy the coordinator first

Do not push another commit. Locate the repository-triggered production image
build for `candidate_sha`:

```bash
if ! git fetch origin master; then
  echo "failed to refresh origin/master" >&2
  exit 2
fi
if [[ "$(git rev-parse origin/master)" != "$candidate_sha" ]]; then
  echo "origin/master no longer matches candidate_sha" >&2
  exit 2
fi
gcloud builds list \
  --project=darkbloom-mainnet \
  --filter="substitutions.COMMIT_SHA=$candidate_sha" \
  --limit=5
```

A human operator then performs the drain, immutable-image swap, environment
preservation, health verification, and fallback capture from
[`coordinator-deploy.md`](../operations/coordinator-deploy.md). Production
mutation is human-only; agents may perform read-only verification.

In the VM shell used for that runbook, set `CANDIDATE_VERSION=0.8.11`,
`CANDIDATE_COMMIT` to the exact `candidate_sha` above, and `CANDIDATE_DIGEST` to
the exact digest printed by the runbook's artifact check. The canonical
procedure validates all three, derives the one commit-tagged `CANDIDATE_IMAGE`,
and requires health to match the version and full commit. Read-only verification
for this release is below. A missing full-commit image tag blocks deployment; do
not fall back to the build pipeline's historical seven-character tag.

```bash
health_json="$(curl -fsS https://api.darkbloom.dev/health)"
printf '%s' "$health_json" | jq -e \
  --arg sha "$candidate_sha" \
  '.status == "ok" and
   ((.draining // false) == false) and
   .version == "0.8.11" and
   .build_commit == $sha and
   .build_date != "unknown"'
```

Hold the production coordinator canary gate before tagging the provider.

### 6. Create the annotated provider tag

Verify `HEAD` is the exact reviewed and deployed master commit, then:

```bash
git status --short
git fetch origin master
test "$(git rev-parse HEAD)" = "$candidate_sha"
test "$(git rev-parse origin/master)" = "$candidate_sha"
./scripts/check-release-version.sh 0.8.11

before_prod_run_id="$(gh run list \
  --workflow release-swift.yml \
  --event push \
  --limit 1 \
  --json databaseId \
  --jq '.[0].databaseId // 0')"

git tag -a v0.8.11 -m "$(cat <<'EOF'
v0.8.11: conserve first-content deadlines

- Keep the coordinator first-content clock request-absolute.
- Route with measured prefill while defaulting partial-prefill concurrency to one
  and preserving the exact cap-0 rollback.
- Propagate optional remaining first-content budget metadata across mixed versions.
EOF
)"

git push origin v0.8.11
```

The tag triggers the production `release-swift.yml` workflow. Approve the
protected production environment only after confirming the tag resolves to the
deployed reviewed SHA.

### 7. Verify release publication

```bash
prod_run_id=""
for _ in $(seq 1 30); do
  prod_run_id="$(gh run list \
    --workflow release-swift.yml \
    --event push \
    --commit "$candidate_sha" \
    --limit 20 \
    --json databaseId,headSha \
    --jq "[.[] | select(
      .databaseId > $before_prod_run_id and
      .headSha == \"$candidate_sha\"
    )] | first | .databaseId // empty")"
  test -n "$prod_run_id" && break
  sleep 2
done
test -n "$prod_run_id"
test "$(gh run view "$prod_run_id" --json headSha --jq .headSha)" = \
  "$candidate_sha"
gh run watch "$prod_run_id" --exit-status
gh release view v0.8.11

prod_release_json="$(curl -fsS \
  'https://api.darkbloom.dev/v1/releases/latest?platform=macos-arm64')"
printf '%s' "$prod_release_json" | jq -e '.version == "0.8.11"'

release_dir="$(mktemp -d)"
gh release download v0.8.11 \
  --pattern 'darkbloom-bundle-macos-arm64.tar.gz' \
  --dir "$release_dir"
test "$(shasum -a 256 \
  "$release_dir/darkbloom-bundle-macos-arm64.tar.gz" | awk '{print $1}')" = \
  "$(printf '%s' "$prod_release_json" | jq -r .bundle_hash)"
rm -rf "$release_dir"
```

Confirm:

- workflow build/sign/notarize/package/smoke/upload/register steps passed;
- release version is `0.8.11`;
- binary, bundle, and metallib hashes match workflow output;
- URL is the versioned R2 path, not only `releases/latest`;
- GitHub release points to the same tag and artifact;
- first upgraded providers report the expected version and binary hash.

### 8. Observe or roll back

Run the production provider gate continuously from first discovery through at
least 30 minutes and 100 Qwen requests. On any rollback trigger:

1. stop new discovery by deactivating the release row under the controls above;
2. if normal deactivation returns 409 and containment cannot wait, obtain
   explicit approval and use the documented force request;
3. restore the coordinator fallback image if the coordinator change is causal;
4. prepare and publish a strictly newer reviewed revert patch for already
   upgraded or already-staged providers.

## Evidence ledger

Replace each "Awaiting execution" value with the actual immutable output,
artifact, URL, or query export. Keep failed attempts; do not overwrite them.

This ledger is a schema, not permission to mutate the tagged checkout.
Evidence captured before the final squash may be filled into the release PR.
Evidence produced after `candidate_sha` is fixed must first live in immutable
workflow artifacts, release assets, query exports, or an append-only release
record. Copy it into this report only in a later docs-only commit that names the
tag and commit SHA. Never amend the release commit or move the tag to include
evidence.

### Ledger A: source identity

- Status: Awaiting execution
- Recorded at:
- Operator:
- `origin/master` SHA:
- Candidate/tag SHA:
- Reviewed release tree ID:
- Final master tree ID:
- Record-creation source diff SHA-256:
  `cee69086cb4d04ee1bbfa6ab306e2597e3fae0d061ff704d6d7ac4d28edb5ba2`
- Record-creation untracked manifest SHA-256:
  `8beb0a7b3ed6e82c3f6f51ec528bb00c904ea91e9b00ce9420ede55905e163d6`
- Later concurrent-worktree observation SHA-256:
  `8d74fd30281cd3626fad09a17423bf6b0f644ac4a6ce37bb7b4e012fbbd4abb1`
- Final pre-integration worktree patch SHA-256:
- Final untracked-file manifest SHA-256:
- `git describe --tags --always`:
- `git status --short`:
- `git log --oneline v0.8.10..HEAD`:
- Reviewed diff URL:
- Scope verdict:

### Ledger B: version and release sync

- Status: Awaiting execution
- `ProviderCore.version`:
- `LatestProviderVersion`:
- Requested workflow version:
- Built binary `--version`:
- `CFBundleVersion`:
- `CFBundleShortVersionString`:
- Annotated tag:
- `./scripts/check-release-version.sh 0.8.11` output:
- `./scripts/sync-install-embed.sh check` output:
- Verdict:

### Ledger C: PR and CI state

- Status: Awaiting execution
- PR #631 final SHA:
- PR #631 review decision:
- PR #631 required checks:
- PR #631 E2E run URL:
- PR #631 threat-review run URL:
- PR #681 final SHA:
- PR #681 review decision:
- PR #681 required checks:
- Combined integration CI URL:
- Verdict:

### Ledger D: coordinator tests

- Status: Awaiting execution
- Command:
- Started at:
- Completed at:
- Exit code:
- Focused clock/routing/protocol output:
- `make coordinator-test` output artifact:
- `make coordinator-build-linux` output artifact:
- Regression-without-fix evidence:
- Verdict:

### Ledger E: provider tests

- Status: Awaiting execution
- Command:
- Started at:
- Completed at:
- Exit code:
- Focused FCFS/deadline/protocol output:
- Stale-predictor-test removal evidence:
- Deterministic decision-matrix JSON:
- Opt-in live Qwen decision-matrix JSON:
- Cross-model CBv2 matrix artifacts:
- `make provider-test` output artifact:
- `make provider-build` output artifact:
- Regression-without-fix evidence:
- Verdict:

### Ledger F: system and mixed-version E2E

- Status: Awaiting execution
- Testbed SHA/config:
- Deadline environment:
- Old coordinator/new provider result:
- New coordinator/old provider result:
- New coordinator/new provider result:
- Chat completions result:
- Completions result:
- Responses result:
- Anthropic Messages result:
- Cancellation/orphan-settlement result:
- E2E run URL or output artifact:
- Verdict:

### Ledger G: incident baseline

- Status: Awaiting execution
- Query owner:
- Query text/export:
- UTC time range:
- Qwen request count:
- Success count/rate:
- `client_gone` count/rate:
- 429 count/rate:
- 5xx count/rate:
- Deadline-line fit:
- OpenRouter dashboard capture:
- Verdict:

### Ledger H: Qwen hardware A/B

- Status: Awaiting execution
- Host model/RAM/macOS:
- Power source and mode:
- Thermal state:
- Model ID/hash:
- Baseline binary/tag/hash:
- Candidate binary/tag/hash:
- Prompt corpus/hash:
- Iteration count:
- 1×8K baseline/candidate TTFT distribution:
- 4×4K baseline/candidate row TTFT distribution:
- 4×8K baseline/candidate row TTFT distribution:
- Staggered 4×8K baseline/candidate distribution:
- Mixed long-first baseline/candidate distribution:
- Active-decode-plus-4×4K distribution:
- Aggregate prefill tok/s:
- Packed-prefill eligible/supported/executed counters:
- Refusal and redispatch counts:
- Other CBv2 model-family results or Qwen-only scope proof:
- Crash/restart/memory observations:
- Raw report artifact:
- Verdict:

### Ledger I: dev signed artifact and canary

- Status: Awaiting execution
- Workflow run ID:
- Workflow run URL:
- Workflow head SHA:
- Dev `/health` build commit:
- Binary hash:
- Bundle hash:
- Metallib hash:
- Downloaded-artifact hash comparison:
- Signing identity:
- Notarization result:
- Dev release JSON:
- Canary start/end:
- Request count:
- Success/error-0/429/5xx:
- Provider restart/cooldown count:
- Orphan request/settlement count:
- Verdict:

### Ledger J: production coordinator canary

- Status: Awaiting execution
- Human approval reference:
- Source SHA:
- Candidate image digest:
- Fallback image digest:
- Pre/post environment digest:
- Deployment start/end:
- Health version/build-commit output:
- Provider reconnect duration:
- Request count:
- Success/error-0/429/5xx:
- First-content timeout response sample:
- Rollback drill result:
- Verdict:

### Ledger K: production provider publication

- Status: Awaiting execution
- Human approval reference:
- Tag object and commit SHA:
- Workflow run ID/head SHA:
- Workflow run URL:
- GitHub release URL:
- Production release JSON:
- Binary hash:
- Bundle hash:
- Metallib hash:
- First provider upgraded at:
- Provider count by version over time:
- First 100 Qwen outcomes:
- Rollback trigger observed:
- Verdict:

### Ledger L: final release decision

- Decision: Awaiting execution
- Decision time:
- Release owner:
- Accepted blockers/exceptions:
- Canary evidence reviewed:
- Rollback owner:
- Rollback patch/branch:
- Final rationale:
