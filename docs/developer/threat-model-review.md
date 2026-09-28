# Configure advisory threat-model review

> Last updated: 2026-09-28 · commit `ae4925180`

The OpenRouter review flags possible security regressions on pull requests with a
single updatable comment. Deleted-line citations use the PR diff’s merge base;
added-line citations use its exact head. It is advisory: findings never request changes, approve
code, or fail a merge gate. The workflow must be present on the base branch before
it can run on PR events.

## Prerequisites

- Repository access to Actions secrets and variables.
- An OpenRouter key with credit and a spend limit suitable for automatic PR reviews.
- A model supporting OpenRouter structured outputs; the default is
  `anthropic/claude-sonnet-4.6`.

## Steps

1. Add the repository Actions secret `OPENROUTER_API_KEY` in GitHub's
   **Settings → Secrets and variables → Actions**. Alternatively, run
   `gh secret set OPENROUTER_API_KEY --repo Layr-Labs/d-inference` and enter the key
   at its interactive prompt. Never commit the key or include it in a PR/comment.
2. Optionally set the Actions repository variable `THREAT_REVIEW_MODEL` to an
   OpenRouter model ID. Omitting it selects the default above. The model must support
   `response_format: json_schema`; unsupported models produce an unavailable review.
3. Land the workflow through the normal reviewed PR process. Opening, updating,
   reopening, or marking a PR ready triggers the review. Draft PRs are skipped.
   Fork patches are read through the GitHub API; fork code is never checked out.
4. Keep **Threat Model Review (advisory)** out of required status checks and rulesets.
   The workflow uses `continue-on-error: true`, and the review entry point reports
   operational failures in the Actions summary without returning a failing status.

## Verify

Run the cloud-free regression suite:

```sh
python3 .github/scripts/test-threat-model-review.py
```

It uses synthetic fixtures, test credentials, and a temporary loopback HTTP server.
It covers clean/findings/error outcomes, missing keys, stale heads, deletion/rename
citations, output bounds, redirects, pagination, and comment replacement.
The ordinary CI Release Integrity job runs these deterministic tests. Their failures
are code regressions, separate from advisory model findings or service outages.

After activation, inspect **Actions → Threat Model Review (advisory)**. A findings
result creates or updates one bot comment with pinned file/line citations. A clean
first review writes only the Actions summary. If a later review finds nothing,
the existing comment is updated so old findings are not presented as current.
An unavailable review updates an existing comment to say that the new head was not
reviewed; it does not claim the previous issues are resolved.

## Scope and troubleshooting

The trusted base revision supplies both the review implementation and
`docs/threat-model.yaml`. PR patches are untrusted data, including changes to the
threat model itself. Neither head code nor head dependencies execute with secrets.
The prompt is read-only; the model has no tools and receives no API credentials.
OpenRouter and its selected provider receive the base threat model and bounded PR
patches. Repository/provider data-handling settings apply.

`threat_review.review.prepare` includes new files outside existing threat patterns
and marks missing/truncated patches as limited coverage. Each run makes one model
request with at most 4,096 output tokens, an 80,000-character total patch budget,
12,000 characters per patch, and a 220,000-character threat-model limit. PRs over
500 files are skipped. A later run cancels an earlier run for the same PR; a changed
head/base detected before publication suppresses stale output. This is a partial
review aid, not a complete security assessment.

Missing keys, rate limits, timeouts, malformed responses, and unverifiable citations
appear as **Review unavailable** in the Actions summary. A missing/truncated patch
is not evidence that a change is safe. To disable reviews, disable this workflow in
Actions or remove the secret. No existing merge requirements need changing.

Implementation: `.github/workflows/threat-model-review.yml`,
`.github/scripts/threat_review/runner.py` (`run`), `review.py` (`prepare`, `review`,
`validate_findings`), `client.py` (`GitHub`, `request_json`), and `report.py` (`render`).
OpenRouter contract: [structured outputs](https://openrouter.ai/docs/guides/features/structured-outputs).
GitHub event contract: [pull_request_target](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#pull_request_target).

## Related

- [Build](build.md) — local toolchains.
- [Test](test.md) — regression and CI checks.
- [Threat model](../threat-model.yaml) — canonical review input.
