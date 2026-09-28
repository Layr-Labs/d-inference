# Configure advisory threat-model review

> Last updated: 2026-09-28 · commit `45f5ef178`

The OpenRouter reviewer scans every PR change against the entire canonical threat
model and posts actionable findings in one updatable public PR comment. It includes
complete before/after text for changed files and a separate cross-file integration
pass. Findings and incomplete scans never block merging or request changes.

## Prerequisites

- Repository access to Actions secrets and variables.
- An OpenRouter key with credit and a spend limit suitable for automatic reviews.
- A model supporting structured outputs; the default is `anthropic/claude-opus-5.5`.

## Steps

1. Add repository Actions secret `OPENROUTER_API_KEY` through **Settings → Secrets
   and variables → Actions**, or use `gh secret set OPENROUTER_API_KEY --repo
   Layr-Labs/d-inference` and enter the key interactively. Never commit it.
2. Optionally set repository variable `THREAT_REVIEW_MODEL` to another OpenRouter
   model ID supporting `response_format: json_schema`.
3. Land the workflow through the reviewed PR process. Opening, updating, reopening,
   or marking a PR ready triggers a scan. Drafts are skipped. The workflow must be
   present on the base branch before it can run.
4. Keep **Threat Model Review (advisory)** out of required status checks. No separate
   GitHub PAT is needed: the built-in token has contents read and PR write access.
5. Set an OpenRouter key spend limit and monitor usage. Full scans make multiple
   paid requests, each containing the full threat model. Every new PR revision,
   including a fork update, can trigger another scan.

## Verify

Run the cloud-free suites:

```sh
python3 .github/scripts/test-threat-model-review.py
python3 .github/scripts/test-threat-full-scan.py
```

They cover immutable Git sources, large changes beyond the former cutoffs,
complete source segmentation, missing-patch reconstruction, cross-file findings,
incomplete batches, binary/submodule coverage, and the comment lifecycle. A real
loopback HTTP test exercises source retrieval, OpenRouter requests, and PR delivery
with synthetic credentials. Release Integrity runs both suites in ordinary CI.

After activation, inspect **Actions → Threat Model Review (advisory)** and the PR:

| Outcome | Author feedback |
|---|---|
| Findings | One public bot comment with severity, source links, threat references, trigger, impact, and suggested fix. |
| Complete clean first scan | Actions summary only. |
| Complete clean follow-up | Existing comment updated to clear old findings. |
| Incomplete scan | Public comment explicitly says the scan is incomplete; it never presents missing coverage as clean. |
| PR changed or closed during scan | Stale output is suppressed. |

Legacy comments from the previous reviewer are updated in place. Findings are
unconfirmed and visible to anyone who can read the public PR. Authors and reviewers
must validate them before changing code.

## Scan scope and troubleshooting

`source.complete_files` reads complete before/after Git blobs pinned to the PR's
merge base and head. It rebuilds the diff instead of relying on truncated API
patches, includes new files outside existing threat patterns, and retains mode,
rename, empty-file, and deletion metadata. Symlink blobs are read as data; their
targets are never followed. PR source is never checked out or executed.

`scan.scan` submits every changed-file text segment in batches, with the entire
trusted-base `docs/threat-model.yaml` in every request. Each response must acknowledge
all submitted units. A separate integration pass examines the batch analyses and
findings for interactions across files; large analysis sets are reduced through
additional integration passes without dropping batches. Candidate findings pass through integration review for validation and consolidation;
unsupported candidates and duplicates are removed.

The prompt checks assets, trust boundaries, assumptions, threats and mitigations,
including new attack surfaces and threat-model updates required by a PR. Context
includes complete changed files; unchanged callers elsewhere in the repository are
not automatically retrieved. This is a full PR text scan, not a re-audit of every
repository file or a guarantee that all vulnerabilities will be found.

Resource limits produce an **incomplete** result rather than truncating source:
GitHub's file-list ceiling is 3,000 files, each API JSON response is bounded to
4,000,000 bytes, and the canonical threat model must fit 220,000 characters. Source
units contain up to 32,000 characters split at whole lines; a single longer line
requires manual review. Batches have an 80,000-character encoded-unit budget.
Non-UTF-8/binary files and submodule contents require manual review and are named
in the comment. A request permits 16,384 output tokens; incomplete responses or a
full 32-finding response are treated as incomplete. A report exceeding the single
comment's 60,000-character budget asks the author to split the PR. The process has
a 50-minute scan deadline within a 60-minute workflow timeout.

For an incomplete scan, inspect the listed files and source/model availability,
OpenRouter balance/rate limits, and whether splitting the PR would allow complete
feedback. Raw API responses and credentials are never printed. OpenRouter and the
selected provider receive the threat model, changed source, and review analyses;
their data-handling settings apply. Disable the workflow or remove its key to stop
new paid reviews. Operational failures remain non-blocking.

Implementation: `.github/workflows/threat-model-review.yml`,
`.github/scripts/threat_review/runner.py` (`run`), `source.py` (`Sources`,
`complete_files`), `scan.py` (`scan`), `review.py` (`prepare`, `model_call`,
`validate_findings`), `client.py` (`GitHub`), and `report.py` (`render`).

## Related

- [OpenRouter structured outputs](https://openrouter.ai/docs/guides/features/structured-outputs).
- [GitHub trusted-base PR event](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#pull_request_target).
- [Build](build.md) — local toolchains.
- [Test](test.md) — regression and CI checks.
- [Threat model](../threat-model.yaml) — canonical review input.
