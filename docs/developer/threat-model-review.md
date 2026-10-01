# Configure budgeted advisory threat-model review

> Last updated: 2026-10-01

The reviewer gives PR authors early Sonnet feedback, escalates selected changes to
Opus and Sol 6.1, and saves completed findings before continuing. Public comments
show coverage, cost, reuse and failures. Reviews never block merges. Paid scanning
is **disabled by default**, including when legacy model variables remain set.

## Prerequisites

- Actions administration and a reviewed workflow on the default branch.
- An OpenRouter key with access to `anthropic/claude-sonnet-5.5`,
  `anthropic/claude-opus-5.5` and `openai/gpt-6.1-sol`. Retain a provider-side key
  spending limit as an independent backstop. This change does not add credits,
  raise a limit or enable paid scanning.
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
   Actions token is excluded by repository rules, supply Actions secret
   `THREAT_REVIEW_STATE_TOKEN` using an authorized identity limited to this
   repository with **Contents: read/write**. It is used only for state storage;
   PR comments still use the built-in token. Do not weaken default-branch
   protections. For the built-in Actions writer, a separately approved rule can
   permit GitHub Actions only on the state branch while retaining signed-commit
   and default-branch protections. Missing state or permission errors stop paid
   calls. The code never mints credentials or changes repository rules.
5. Run the offline checks below. Run **Actions → Threat Model Review (advisory)
   → Run workflow** with `preflight=true` on the reviewed branch. The preflight
   verifies a signed state write/read and available OpenRouter key/account funds
   without admitting a PR, changing the ledger, or calling a paid model. A failed
   preflight reports storage and funding failures separately.
6. When authorized to start the pilot, set `THREAT_REVIEW_ENABLED=true`. This
   repository variable can be set before merge so activation takes effect as
   soon as the workflow lands on the default branch. It admits
   at most **ten distinct PRs** and **$25 total**, with no automatic renewal.
7. Keep **Threat Model Review (advisory)** out of required checks. Opening,
   reopening, marking ready or retargeting a PR starts immediately. Follow-up
   pushes wait 75 seconds; another push cancels the older job. Drafts and
   title/body-only edits are skipped before entering the cancellation group.

Maintainers can request depth through **Actions → Threat Model Review (advisory)
→ Run workflow**, supplying a PR number targeting the default branch. Current
GitHub write/maintain/admin permission is checked before spending, and all caps
still apply. PR text and labels cannot request extra spend. Only trusted
base/default-branch code runs; PR blobs are data, never checked out or executed.

## Verify

```sh
python3 .github/scripts/test-threat-model-review.py
python3 .github/scripts/test-threat-full-scan.py
python3 .github/scripts/test-threat-ensemble.py
python3 .github/scripts/test-threat-budget.py
```

Release Integrity runs all four suites using Python 3.9+ and loopback sockets,
without external services, real keys or paid calls. The budget suite exercises
real local HTTP, conflicting SHA writes, reconciliation, permissions, cache
invalidation, escalation, partial failures and comment delivery. Earlier suites
protect immutable-source collection, validation and legacy report helpers.

| Pilot check | Expected behavior |
|---|---|
| First feedback | Progress, then Sonnet findings or clean first-pass feedback before deeper work. |
| Risky or uncertain changes | Selected Opus review for auth, attestation, encryption, billing, workflows, findings or model uncertainty. |
| Critical or disputed changes | Independent Sol 6.1 source review for cryptography, attestation, workflows, high-severity findings, disagreement with Opus or maintainer request. |
| Repeat push | Identical analysis reused; changed inputs invalidate source and integration results. |
| Failure or budget exhaustion | Completed findings retained; unfinished coverage explicit; no automatic paid retries. |
| Head changes during a call | Original-head results saved; stale findings not posted as current. |
| Clean review | Explicit comment, never a security approval. |
| Cost | Reported dollars separated from unknown-cost reservations, plus request count, reused batches and provider cache-hit tokens. |

Compare actual spend, useful findings, false positives, deferred coverage and
second-opinion value across the ten PRs before proposing a larger rollout. A
green workflow is not evidence that scanning completed.

## Budget behavior and recovery

| Limit | Amount |
|---|---:|
| Sonnet per workflow attempt | $1 |
| Opus and Sol 6.1 combined per attempt | $3 |
| PR per UTC day across attempts and pushes | $5 |
| Repository per UTC day across PRs | $25 |
| Entire pilot, no automatic reset | $25 and ten distinct PRs |

`state.py` reserves integer microdollars in one ledger **before** transport.
GitHub Contents SHA compare-and-swap rejects stale concurrent writes; retries
reread and recheck every cap. Missing state, write failures and ambiguous writes
cannot authorize a request. Interrupted or unreconciled reservations never
expire and also count against later days until reconciled from billing evidence.

`paid.py` sets provider price ceilings, disallows fallbacks and per-request fees,
caps output at 4,096 tokens, and bounds input with UTF-8 bytes plus a framing/schema
allowance. Reservations assume cold cache and allow two times the input price for
cache writes. Oversized requests are deferred. Response `usage.cost` settles the
reservation; missing or invalid usage saves valid findings but stops more calls
in that run. Charges above the reservation open a persistent circuit breaker.
Sol 6.1 uses price ceilings of $2 input and $10 output per million tokens,
verified against the [OpenRouter model catalog](https://openrouter.ai/api/v1/models).
Price/provider behavior changes require review; retain the independent key cap.
Never delete or reset the ledger to work around a limit.

To pause, set `THREAT_REVIEW_ENABLED=false` and cancel active review jobs. Pending
calls may still incur cost; their reservations remain. Inspect the ledger and
linked reports, reconcile unknown charges against provider billing, and fix
credentials, permissions or invalid responses before resuming. HTTP statuses are
shown without raw error bodies. Cache/checkpoint failures halt further spending.

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

Validated findings are checkpointed after every batch before caching or more
spend. Reports include exact head/base, progress and the previous public comment,
and link to immutable state-branch commits. Later heads and incomplete retries
cannot erase historical advice. One updatable comment links to the saved report;
oversized reports use a bounded summary with finding/manual-review counts
and that link, retaining full details in the saved report. If storage fails, old
findings stay inline when they fit, and local results remain in the Actions summary. Raw responses, keys
and prompts are not stored in ledger/reports. Cached analyses and findings are
public like the PR. OpenRouter and its provider receive source and threat context.

Implementation: `.github/workflows/threat-model-review.yml`,
`.github/scripts/threat-model-review.py`, and `.github/scripts/threat_review/`:
`budget_runner.py`, `budget_scan.py`, `context.py`, `paid.py`, `state.py`,
`preflight.py`, plus shared
source, validation, transport and rendering helpers. The scan deadline is 15
minutes inside a 20-minute workflow timeout.

## Related

- [OpenRouter provider price ceilings](https://openrouter.ai/docs/guides/routing/provider-selection).
- [OpenRouter prompt caching](https://openrouter.ai/docs/guides/best-practices/prompt-caching).
- [GitHub Contents API](https://docs.github.com/en/rest/repos/contents).
- [GitHub trusted-base PR event](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#pull_request_target).
- [Build](build.md), [test](test.md), and [canonical threat model](../threat-model.yaml).
