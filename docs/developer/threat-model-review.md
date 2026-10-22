# Configure threat-model review and merge clearance

> Last updated: 2026-10-22

The reviewer gives PR authors early Sonnet feedback, escalates selected changes to
Opus and Sol 6.1, and saves completed findings before continuing. Public comments
show coverage, cost, reuse and failures. The default remains advisory. Optional
conditional clearance allows a completed scan without medium/high findings from
a verified active Layr-Labs organization member, or an independent formal manual
override, to satisfy the security workflow requirement. Each automatic CI review
either completes or requires human review instead of a manual paid rerun.
See [Bedrock and merge-policy rollout](https://github.com/Layr-Labs/darkbloom-platform/blob/48a198c71a2d30feec5597bacf1101120f7f955d/docs/operations/threat-review-rollout.md).
Paid scanning is disabled when `THREAT_REVIEW_ENABLED` is not `true`.

## Prerequisites

- Actions administration and a reviewed workflow on the default branch.
- An OpenRouter key with access to `anthropic/claude-sonnet-5.5`,
  `anthropic/claude-opus-5.5` and `openai/gpt-6.1-sol`. Retain a provider-side key
  spending limit as an independent backstop. Provider credits and key limits are
  managed separately from the durable repository budget policy.
- A writer permitted to update `codex/threat-review-state` under branch
  restrictions and signed-commit rules. Contents write permission alone does
  not bypass repository rules.

## Set up and activate

1. Keep repository variable `THREAT_REVIEW_ENABLED` absent or `false` while
   validating. Legacy `THREAT_REVIEW_MODEL` and `THREAT_REVIEW_MODELS` are ignored;
   models and price ceilings are reviewed code in `context.py` and `paid.py`.
2. Configure Actions secret `OPENROUTER_API_KEY`. Never put a key in source, a PR
   or a shell argument. An exhausted key needs a separate billing decision.
3. Initialize state once from a trusted checkout, with an authorized maintainer's
   `GH_TOKEN` already in the environment:

   ```sh
   python3 .github/scripts/threat-review-state.py \
     --repository Layr-Labs/d-inference --base <full-trusted-base-commit-sha>
   ```

   This creates the dedicated branch and `ledger.json`; it never resets an
   existing ledger. Verify the Contents API commits satisfy signature rules. If
   the initializer cannot sign with the chosen identity, seed the empty ledger
   with a maintainer-signed Git commit; never weaken the signature rule or
   overwrite an existing ledger.
4. Confirm the workflow writer can update the state branch. If the built-in
   Actions token is excluded by repository rules, use a dedicated GitHub App
   installed only on this repository with **Contents: read/write**. Set its ID
   in `THREAT_REVIEW_APP_ID` and its private key in Actions secret
   `THREAT_REVIEW_APP_PRIVATE_KEY`. The pinned token action requests only this
   repository and Contents write, then revokes the token when the job finishes.
   With separate approval, allow that App through a rule restricted to the state
   branch; preserve signed-commit and all other branch protections. GitHub does
   not accept its built-in Actions integration as an installed bypass App.
   An existing authorized writer can alternatively use
   `THREAT_REVIEW_STATE_TOKEN`. The writer token is used only for state storage;
   PR comments use the built-in token. Missing state or permission errors stop
   paid calls. The workflow never creates Apps or changes repository rules.
5. Run the offline checks below. Run **Actions → Threat Model Review (advisory)
   → Run workflow** with `preflight=true` on the reviewed branch. The preflight
   verifies a signed state write/read and available OpenRouter key/account funds
   without admitting a PR, changing the ledger, or calling a paid model. A failed
   preflight prints a generic public failure; maintainers inspect branch-rule
   insights and the provider console for private access/funding details.
6. When authorized to start the pilot, set `THREAT_REVIEW_ENABLED=true`. This
   repository variable can be set before merge so activation takes effect as
   soon as the workflow lands on the default branch. It admits
   at most **ten distinct PRs** and **$25 total** by default. For an approved
   ongoing rollout, set `THREAT_REVIEW_BUDGET_MODE=daily`: this removes only the
   lifetime dollar and PR-count limits while retaining every per-day and
   per-attempt cap. Unset or `pilot` retains the pilot; other values fail closed.
7. In advisory mode, keep **Threat Model Review (advisory)** out of required checks. Opening,
   reopening, marking ready or retargeting a PR starts immediately. Follow-up
   pushes wait 75 seconds; another push cancels the older job. Drafts and
   title/body-only edits are skipped before entering the cancellation group in
   advisory mode. Conditional-clearance mode reevaluates edits so a skipped run
   cannot replace a failed required workflow.

Manual dispatch supports only the unpaid activation preflight. Paid PR scans run
on automatic PR events; GitHub job reruns do not start paid work. A new push starts
a fresh automatic review for its new revision. There is no continuation schedule
or manual depth request. PR text and labels cannot request extra spend. Scanner code comes
from the current trusted default branch, so older PR base SHAs cannot roll back
merged fixes. The canonical threat model is fetched separately as an immutable
Git blob at the exact PR base SHA and read as data. PR head code is never checked
out or executed.

## Verify

```sh
python3 .github/scripts/test-threat-model-review.py
python3 .github/scripts/test-threat-full-scan.py
python3 .github/scripts/test-threat-ensemble.py
python3 .github/scripts/test-threat-budget.py
python3 .github/scripts/test-threat-bedrock.py
python3 .github/scripts/test-threat-diagnostics.py
python3 .github/scripts/test-threat-integration-scope.py
```

Release Integrity runs all seven suites using Python 3.9+ and loopback sockets,
without external services, real keys or paid calls. The budget suite exercises
real local HTTP, conflicting SHA writes, reconciliation, permissions, cache
invalidation, escalation, partial failures and comment delivery. Earlier suites
protect immutable-source collection, validation and legacy report helpers.

Integration calls also receive up to 16,000 JSON-encoded bytes of exact source
units already validated in that model's source passes. This lets a stateless
final reviewer check the analyses against source instead of requesting human
review merely because only summaries were supplied. Patches and metadata have
priority, followed by head and base source. Units retain their numbered lines
and are never clipped; omitted units and replay completeness are explicit.
Replay completeness describes that model's selected scope, not the whole PR.
The original source acknowledgments remain the coverage authority, and the
integration response acknowledges its summary units separately. Cached source
results reconstruct the same scope; integration cache identity includes the
replayed content. Content-free diagnostics record replayed/omitted unit counts.
Material uncertainty still requires human review; no model flag is overridden.

| Pilot check | Expected behavior |
|---|---|
| First feedback | Progress, then Sonnet findings or clean first-pass feedback before deeper work. |
| Risky or uncertain changes | Selected Opus review for auth, attestation, encryption, billing, workflows, findings or model uncertainty. |
| Critical or disputed changes | Independent Sol 6.1 source review for cryptography, attestation, workflows, high-severity findings or disagreement with Opus, followed by integration of its selected source analyses. |
| Repeat push | Identical analysis reused; changed inputs invalidate source and integration results. |
| Failure or budget exhaustion | Completed findings retained; final comment explicitly requires human review. No manual paid rerun. One bounded analysis/acknowledgment repair within the original CI run is the only response-recovery exception. |
| Head changes during a call | Original-head results saved; stale findings not posted as current. |
| Clean review | Explicit comment, never a security approval. |
| Cost | Reported dollars separated from unknown-cost reservations, plus request count, reused batches and provider cache-hit tokens. |

Compare actual spend, useful findings, false positives, deferred coverage and
second-opinion value across the ten PRs before proposing a larger rollout. A
green workflow is not evidence that scanning completed.

## Bedrock primary and OpenRouter backup

`BEDROCK_SCAN_ENABLED=true` selects `.github/scripts/threat_review/bedrock.py`
(`BedrockCalls`). Configure exactly three application profile aliases in
`BEDROCK_SCAN_PROFILES`: `sonnet`, `opus`, and `sol`. Model selection remains
Sonnet 5.5 with selective Opus 5.5 and Sol 6.1; legacy model variables do not
override that strategy. CI sets `BEDROCK_SCAN_CALL_POLICY=workload`: `budget_scan.py`
admits the actual Sonnet source batches, each selected Opus/Sol source pass and
every integration round before running that stage. The allowance includes one
shared response-repair slot. Integration can require more than one round; later
rounds receive an allowance only while the summaries converge. Cache reuse avoids
native calls but does not admit additional stages.

The workflow defaults to a **500-call emergency ceiling**, separate from the calculated
allowance. An oversized stage is refused before its first call, retains completed
work and requires human review. Native requests remain bounded to 180,000 encoded
bytes and default to **16,384 output tokens** in workload mode. The existing
analysis, finding and citation validation bounds still apply to the response.
CI no longer reads the old fixed `BEDROCK_SCAN_MAX_CALLS` repository variable.
Standalone bounded probes retain `fixed` policy by default and use that variable
(default 12, range 1–100) and default to 4,096 output tokens.
Maintainers can tighten workload limits without a code change through Actions
variables `BEDROCK_SCAN_MAX_WORKLOAD_CALLS` (1–500, default 500) and
`BEDROCK_SCAN_MAX_OUTPUT_TOKENS` (256–16,384, workload default 16,384). An unset
variable uses the generous default; invalid values stop before paid work.
The call ceiling is a backstop, not a request target: stage admission allocates
only the actual scheduled work plus one shared repair.
Each native workload request has a 600-second response timeout to allow larger
output; fixed probes retain 240 seconds. SDK retries remain disabled, and the
50-minute whole-scan deadline can interrupt either timeout.
These workload bounds are not a repository-wide dollar cap. AWS charges
are reconciled through dedicated profile tags and the usage metadata artifact.
Fork PRs keep the capped OpenRouter route unless a maintainer explicitly sets
`BEDROCK_SCAN_ALLOW_FORKS=true`; they do not
receive AWS capacity by default.

Bedrock requests include native `outputConfig.textFormat` JSON-schema constraints,
in addition to the original schema in the prompt. `structured_output.py` projects
unsupported length/count/numeric bounds into descriptions for the provider; local
validation still enforces every original bound, coverage ID, citation and review
decision. Empty or whitespace-only analysis is invalid even for a clean batch.
Finding title/detail and analysis limits count raw characters, including whitespace
padding, in both the budgeted scanner and the legacy review path.
The budgeted scanner permits **one response repair request per entire scan** when
a fresh completed response has valid fields, citations and a boolean decision,
but its analysis string is blank/too long or its string-list acknowledgment does
not match the primary IDs. It saves validated findings first, then requests the
same model and source again with an explicit repair marker. The corrected response
must pass every original check; coverage is never inferred or silently repaired.
The ordinary call, time, request and dollar limits apply; workload admission
reserves the one shared repair slot within its emergency ceiling. Fixed probes
receive no extra allowance. Original findings and uncertainty are retained even if the
corrected response omits them. Both failure types share the one-request allowance.
A second invalid response, invalid cached entry, unknown accounting or failed
checkpoint cannot authorize another repair. Failed repairs leave the scan incomplete.
Sol also sets the required `additionalModelRequestFields.text.format.strict=true`
([AWS model contract](https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-openai-gpt-6-1-sol.html));
that model-specific field is not sent to Claude.
Native schema rejection stops the attempt instead of silently downgrading to
prompt-only output or switching models. Verify the configured profiles with the
bounded smoke workflow before claiming live compatibility.

Explicit availability rejections or unavailable AWS credentials can invoke the
same model once through OpenRouter, with its existing durable caps below. Each
switch is recorded and visible in the comment. Whole-scan deadlines, ambiguous
transport failures, refusals, truncation and invalid model responses never
trigger fallback. Budget exhaustion cannot be bypassed through the backup.
Missing backup cost, failed settlement or a cost overrun stops the entire
attempt, including a subsequently recovered Bedrock primary; validated findings
are retained before stopping.
Missing native usage or a failed native response-usage write also retains advice
only after ordinary strict validation, then stops before caching, repair,
fallback or another request. The affected call remains unknown and cannot grant
merge clearance; its original model, stage and request ID remain in diagnostics.
Source, prompts, reasoning and keys are excluded from AWS usage records.
Reports and usage records preserve uncached, cache-read and cache-write input
tokens separately using the [Converse usage fields](https://docs.aws.amazon.com/bedrock/latest/APIReference/API_runtime_TokenUsage.html).
Sol can place nearly all input in cache-write usage; `inputTokens` alone does not
represent that input. Invalid cache counts leave usage unknown, and older saved
reports without a cache breakdown show it as unavailable.
Unknown usage stays unknown; Bedrock token totals are not presented as actual
dollars. No external gateway or long-lived AWS credential is used.

Automatic clearance requires a live organization membership lookup for the PR
author through `.github/scripts/threat_review/membership.py` (`active_member`).
It checks the immutable Layr-Labs organization ID and author ID, active membership
state and a human account. Repository write access, PR `author_association`,
pending invitations and bot accounts never substitute for membership. Missing
credentials, lookup failures and mismatched identities require independent human
review. An external author can still use the explicit formal human-review path;
a clean model verdict alone cannot waive that approval.

The existing review App needs **Organization permissions → Members: read-only**,
including installation-owner approval of that permission. The workflow requests
a separate short-lived token with only that permission for the final gate. The
state-writer token retains its explicit repository Contents permission and does
not receive membership permission. Neither token is exposed to models or PR code.
Membership is fetched anew each time the gate runs; this is not a webhook that
instantly revokes a completed check after a later organization membership change.
After removing a member with a pending PR, require independent human review
before merging; do not rely on an earlier membership check. Human overrides continue to verify the reviewer's current repository
permission and the exact current commit.

Conditional clearance disables reuse of prior cached verdicts. It evaluates a
result file produced by the current trusted scan and matching workflow run/attempt,
not public comments, artifacts
from PR jobs, or state-branch cache entries. Human overrides also reread current
GitHub reviews and permissions. See the rollout runbook for author auto-merge
and the exact override format.

## OpenRouter budget behavior and recovery

| Limit | Amount |
|---|---:|
| Sonnet per workflow attempt | $1 |
| Opus and Sol 6.1 combined per attempt | $3 |
| PR per UTC day across attempts and pushes | $5 |
| Repository per UTC day across PRs | $25 |
| Default `pilot` mode, no automatic reset | $25 and ten distinct PRs |
| Approved `daily` mode | No lifetime/PR-count cap; all other caps above remain |

`THREAT_REVIEW_BUDGET_MODE` is a trusted repository Actions variable used by
preflight and both OpenRouter routes (direct reviews and Bedrock backup). Moving
to `daily` preserves the existing ledger, all charges, unknown reservations and
the circuit breaker. Returning to `pilot` restores its lifetime limits against
the full retained history; it does not restart the pilot. The ledger remains
bounded to 1,000 requests and 500,000 bytes; reaching capacity stops spending
and needs maintainer maintenance, never an automatic reset.

Preflight checks writer access, signatures, provider funding and room for a new
PR's $1 normal attempt under the selected policy. This is a read-only capacity
snapshot, not a reservation or proof that a whole scan fits. Every actual request
rechecks the budget atomically. Preflight fails on an exhausted pilot even when
the provider has credits.

`state.py` reserves integer microdollars in one ledger **before** transport.
GitHub Contents SHA compare-and-swap rejects stale concurrent writes; retries
reread and recheck every cap. Different report/cache files share the same branch
and can also conflict. Explicit HTTP 409 writes retry with jittered backoff, up to
twelve attempts, without repeating a paid call. Each delay is bounded to 0.5–8
seconds (at most 63.5 seconds total sleep); the whole-scan deadline still applies.
Cache entries remain immutable. Exhausted report/cache retries record the actual
attempt count and limit. Persistent contention remains an incomplete review.
Missing state, permission failures and ambiguous writes
cannot authorize a request. Interrupted or unreconciled reservations never
expire and also count against later days until reconciled from billing evidence.

`paid.py` sets provider price ceilings, disallows fallbacks and per-request fees,
caps output at 4,096 tokens, and bounds input with UTF-8 bytes plus a framing/schema
allowance. Reservations assume cold cache and allow two times the input price for
cache writes. Oversized requests are deferred. Response `usage.cost` settles the
reservation; missing or invalid usage saves valid findings but stops more calls
in that run. Charges above the reservation open a persistent circuit breaker.
Sonnet 5.5 uses price ceilings of $2 input and $10 output per million tokens;
Sol 6.1 uses $2 input and $10 output per million tokens,
verified against the [OpenRouter model catalog](https://openrouter.ai/api/v1/models).
Price/provider behavior changes require review; retain the independent key cap.
Never delete or reset the ledger to work around a limit.

To pause, set `THREAT_REVIEW_ENABLED=false` and cancel active review jobs. Pending
calls may still incur cost; their reservations remain. Inspect the ledger and
linked reports, reconcile unknown charges against provider billing, and fix
credentials, permissions or invalid responses before resuming. HTTP statuses and fixed local validation-failure reasons are
shown without raw error bodies or model responses. Cache/checkpoint failures halt further spending.

### Diagnose a failed or deferred review

1. Check whether the comment says **Scan completed; human review required** or
   **Review not completed**. A completed scan can require a human decision for
   medium/high findings or unresolved final-review uncertainty. This is distinct
   from a transport, coverage, validation or budget failure; neither state grants
   automatic merge clearance.
2. For an incomplete scan, download the run's `threat-review-diagnostics-*`
   artifact. `diagnostics.py` records fixed failure codes, the model, source or
   integration stage, batch hash and expected coverage. JSON failures include
   a syntax category, line/column/offset, response length/hash and prefix class.
   Field failures identify missing schema fields and count unexpected fields
   without exposing their names. Findings and raw response text are excluded.
   Coverage mismatches include missing, unexpected and duplicate unit counts;
   analysis-length and decision-type failures have separate codes.
   The artifact also records distinct scanner and canonical-context commit SHAs.
   `STATE_WRITE_FAILED` identifies report/cache/ledger writes and HTTP status;
   `GITHUB_API_ERROR` identifies the API operation, while
   `OPENROUTER_API_ERROR` identifies completion transport. An initial report-write
   failure has lifecycle phase `initial_checkpoint`, before any model request.
3. Correlate Bedrock failures with `bedrock-usage-*`: the call number, allowlisted
   AWS error code, request ID, stop reason and latency distinguish access errors,
   refusal/truncation, invalid JSON and local validation. Missing metadata stays
   unavailable; it is never invented. The smoke test also writes safe failure
   metadata to its existing usage artifact.
4. Hand the current PR to an independent human reviewer; do not rerun its paid scan.
   Fix diagnosed scanner defects with offline and isolated provider validation
   before a reviewed update. Subsequent automatic PR events use the merged fixes.
   Except for the single analysis/acknowledgment repair described above, invalid responses
   do not trigger an automatic paid retry or provider switch. `response_repairs`
   records the original validation code, model, batch, request ID and
   pending/completed/failed status without response text. Comments show the
   repair count separately from terminal failures. `PR_CLOSED` distinguishes a
   closed/merged PR from a model failure, while `PR_REVISION_CHANGED` identifies
   work superseded by a new head or target. Both halt further spending and
   prevent outdated findings from being published as current advice.
   These artifacts are content-free diagnostics suitable for a public repository,
   not raw-response recordings; use the AWS request ID with authorized provider
   diagnostics when additional evidence is needed.

`BEDROCK_WORKLOAD_LIMIT` identifies a stage that cannot fit below the emergency
ceiling. Diagnostics include the planned calls, ceiling and unadmitted stage;
the preceding call is not blamed for a planning failure. `BEDROCK_CALL_LIMIT`
identifies exhaustion of the admitted allowance, including fixed standalone
probes. Neither is a model-format failure. CI allocates **50 minutes** to the
scanner (`THREAT_REVIEW_TIMEOUT_SECONDS=3000`) inside a **60-minute** job, leaving
time to save findings, publish the handoff and evaluate clearance before the
job or one-hour credentials expire. Standalone entry points default to 900
seconds; validated configuration is 60–3,000 seconds. `SCAN_TIMEOUT` requires
human review, with no continuation job or manual paid retry. More capacity does
not prove a scan will finish or be clean.

The local artifact is atomically refreshed before provider calls and remote
checkpoints. An interrupted run can retain the last model, stage, batch and
phase even when no final error is available. A `provider_call` phase does not
prove whether the provider completed or charged the request. If the local
artifact cannot be written, Actions logs `DIAGNOSTICS_WRITE_FAILED` without
filesystem details; findings, report delivery and merge evaluation still proceed.
The final result file is replaced atomically and binds the repository, revisions
and current workflow run/attempt. A failed final write records
`RESULT_WRITE_FAILED`, preserves earlier findings and diagnostic codes, and exits
unsuccessfully. It cannot become a generic setup error or permit stale results
to grant clearance. Native accounting failures use `BEDROCK_USAGE_MISSING` or
`BEDROCK_USAGE_RECORD_FAILED` and retain unknown usage rather than inventing zero.

## Scope, reuse and saved findings

Immutable merge-base/head blobs supply complete before/after text and rebuilt
patches, including rename, mode and empty-file metadata. Every source unit is
scheduled for Sonnet, followed by cross-file integration. Responses must
acknowledge all submitted units; source findings must cite visible evidence.
Large changes may exhaust a budget: the comment shows reviewed unit counts and
pending integration instead of claiming full coverage. Existing limits remain:
3,000 files, 8 MB aggregate source, 32,000-character line-aligned units and
80,000-character batches. Split patches carry continuation hunk headers so
each fragment retains its original base/head citation lines. Binary, LFS and
submodule changes need manual review.

`change_context.py` supplies each source batch with changed-line coordinates and
a bounded patch excerpt for its files, so a HEAD-only excerpt can distinguish
changed lines from unchanged surroundings. Incomplete range maps and truncated
excerpts are labeled; context overflow stops before spending. This context does
not expand citation permissions beyond the supplied source units. Reviewers must
report hypothetical deployment mismatches as unverified contracts, not established
vulnerabilities without supporting evidence.

Sol integrates its own selected batch analyses before deciding whether local
questions remain unresolved. This costs at least one additional request when
Sol runs; all existing request, runtime and spending limits still apply. A limit
or validation failure during integration preserves prior findings and leaves the
scan incomplete. Final uncertainty is stored separately in `manual_review_reasons`;
it still denies automatic clearance. Reports missing this field also deny clearance.
An unresolved Sonnet cross-file integration question also requires human review:
independent local depth passes do not receive that question and cannot clear it.
Each model's integration may cite only the source lines that model reviewed;
cached source results rebuild the same evidence scope, and integration cache
identity includes that scope.
Primary summary IDs are listed in `expected_covered_units` and constrained by the
integration response schema. Replayed evidence uses `source_id`; it supplies
unchanged text and citation coordinates without adding acknowledgment targets.

Each request receives an index of **all** canonical definition entries, the
preamble, and up to eight lexically relevant complete definition blocks within
18,000 characters. Oversized blocks are identified in model context. This is a
bounded PR review with selected threat detail, not a verbatim full-threat-model
audit or an automatic scan of unchanged callers. Anthropic requests mark the
stable prefix for caching; hits are measured, never assumed for admission.

Local analyses are cached by exact inputs, model, schema, prompt, threat text and
trusted base. Integration also includes the entire changed-source fingerprint:
identical summaries cannot reuse stale cross-file conclusions. A base change
conservatively invalidates all results, including unchanged-dependency assumptions.
Models do not see each other's source verdicts. Findings retain attribution;
a later clean pass does not silently veto a prior candidate. Humans validate them.
The `budgeted-v3` cache version invalidates earlier analyses whose prompts lacked
the change context and final-integration policy; it does not reset the budget ledger.

Validated findings are checkpointed after every batch before caching or more
spend. Reports include exact head/base, progress and the previous public comment,
and link to immutable state-branch commits. Later heads and incomplete retries
cannot erase historical advice. One updatable comment links to the saved report;
oversized reports use a bounded summary with finding/manual-review counts
and that link, retaining full details in the saved report. If storage fails, old
findings stay inline when they fit, and local results remain in the Actions summary. Raw responses, keys
and prompts are not stored in ledger/reports. Cached analyses and findings are
public like the PR. Bedrock receives source and threat context in primary mode;
OpenRouter and its provider receive them when that route is used.

Implementation: `.github/workflows/threat-model-review.yml`,
`.github/scripts/threat-model-review.py`, and `.github/scripts/threat_review/`:
`budget_runner.py`, `budget_scan.py`, `context.py`, `paid.py`, `state.py`,
`preflight.py`, `bedrock.py`, `merge_policy.py`, plus shared
source, validation, transport and rendering helpers. Advisory mode remains
nonblocking; human-review handoffs do not activate conditional clearance or
author auto-merge. Those require the separate reviewed rollout.

## Related

- [OpenRouter provider price ceilings](https://openrouter.ai/docs/guides/routing/provider-selection).
- [OpenRouter prompt caching](https://openrouter.ai/docs/guides/best-practices/prompt-caching).
- [GitHub Contents API](https://docs.github.com/en/rest/repos/contents).
- [GitHub trusted-base PR event](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#pull_request_target).
- [Build](build.md), [test](test.md), and [canonical threat model](../threat-model.yaml).

Source excerpts include original line numbers, with annotation size included in the
batch limit. Review summaries target 2,000 characters below the unchanged 4,000
character validation limit. An unresolved `needs_deeper_review` request from the
final Sol integration requires independent human review without relabeling completed
scan execution as a coverage failure;
a zero-finding response alone cannot clear that uncertainty.
