# Configure private threat-model review

> Last updated: 2026-09-28 · commit `f7eda79fa1`

The OpenRouter review sends possible security regressions to **private draft
repository security advisories**. It never posts findings on public PRs, logs,
job summaries, annotations, or artifacts. Findings and operational failures are
advisory and never block merging. The workflow must land on the base branch first.

## Prerequisites

- Repository access to Actions secrets and variables.
- An OpenRouter key with credit and a spend limit suitable for automatic PR reviews.
- A model supporting structured outputs; default: `anthropic/claude-sonnet-4.6`.
- A fine-grained GitHub token restricted to this repository with **Repository
  security advisories: read and write**, created by a repository administrator
  or security manager. Complete any required organization approval for the token.
  An appropriately scoped GitHub App installation token is also supported, but
  its short lifetime requires a separate token-renewal integration.

## Steps

1. Add Actions secret `OPENROUTER_API_KEY` under **Settings → Secrets and variables
   → Actions**. Add the GitHub advisory credential as `THREAT_REVIEW_ADVISORY_TOKEN`.
   Never paste either token into a PR, comment, or source file. To use interactive
   terminal prompts, run each command separately:

   ```sh
   gh secret set OPENROUTER_API_KEY --repo Layr-Labs/d-inference
   gh secret set THREAT_REVIEW_ADVISORY_TOKEN --repo Layr-Labs/d-inference
   ```

2. Optionally set repository variable `THREAT_REVIEW_MODEL` to an OpenRouter model
   ID supporting `response_format: json_schema`. Otherwise the default applies.
3. Land the workflow through the normal reviewed PR process. Opening, updating,
   reopening, or marking a PR ready triggers the review. Draft PRs are skipped.
   Only trusted base code executes; fork patches are read as data through the API.
4. Open **Security → Advisories** as a repository administrator or security manager.
   Other maintainers/authorized users must be explicitly invited as advisory
   collaborators by an administrator; ordinary repository read/write access does
   not by itself grant access to every draft. See [GitHub advisory permissions][access].
5. Keep **Threat Model Review (advisory)** out of required checks and rulesets.
   `continue-on-error: true` and fixed non-failing operational outcomes keep the
   live model review non-blocking. Missing reporting credentials skip the model
   request; there is no public fallback.

## Verify

Run the cloud-free privacy and review regressions:

```sh
python3 .github/scripts/test-threat-model-review.py
```

The suite uses synthetic credentials and a real loopback HTTP server. It verifies
GitHub diff reads → OpenRouter review → private draft creation, credential separation,
redacted errors, identical public clean/findings status, no public comment writes,
stale revision suppression, deletion/rename citations and bounded context/output.
Ordinary CI Release Integrity runs these deterministic implementation tests; they
are separate from the non-blocking live review.

After activation, maintainers should verify a genuine finding in **Security →
Advisories** and confirm that a signed-out browser cannot access that draft.
The workflow logs and job summary expose only fixed completion/skipped/unavailable
messages, without finding counts, titles, paths, descriptions, or advisory IDs/links.
Clean reviews create nothing; private reporting failures never fall back to a PR
comment or downloadable artifact. The public workflow's execution remains visible.

## Triage and lifecycle

Each successful run with findings creates a new draft labeled **Unconfirmed
automated threat review**, pinned to the exact PR/head/base revision. Treat it as
an unverified historical snapshot, not a claim that the current PR is vulnerable.
Validate the findings, invite authorized collaborators, and close obsolete or
false-positive drafts manually. Re-runs may produce duplicate drafts.

The automation never updates existing drafts: an administrator could have published
one since its creation, and updating it would expose new findings. It never
publishes advisories, requests CVEs, creates private forks, changes collaborators,
or assigns confirmed affected releases. Publication is a separate human decision.
Existing comments from the older, removed public reviewer are not migrated or
removed by this workflow; historical public disclosures cannot be made private by
changing the new reporting destination.

## Scope and troubleshooting

The base revision supplies both the implementation and `docs/threat-model.yaml`.
PR patches are untrusted data. Neither head code nor head dependencies execute
with secrets. The default workflow GitHub token has only contents/PR read access;
the separate advisory credential is used solely for the draft-creation endpoint.
The model has no tools and receives neither credential. OpenRouter and its selected
provider receive the base threat model and bounded public PR patches; their data
handling settings still apply.

Each run makes at most one model request with 4,096 output tokens, an
80,000-character total patch budget, 12,000 characters per patch, and a
220,000-character threat-model limit. PRs over 500 files are skipped. Missing or
truncated patches are coverage limits recorded in any private report. A changed
head/base detected before delivery suppresses stale output. This is a partial
review aid, not a complete security assessment.

For **Review unavailable**, verify both secrets, token expiration and organization
approval, advisory write permission, OpenRouter balance/rate limits, and structured
output support. API errors and model responses are deliberately not printed. Never
enable response-body logging or upload report artifacts to diagnose this on the
public repository. Disable the workflow or remove either secret to stop reviews.

Implementation: `.github/workflows/threat-model-review.yml`,
`.github/scripts/threat_review/runner.py` (`run`, `summarize`), `client.py`
(`GitHub`, `PrivateAdvisories.create`), `review.py` (`prepare`, `review`,
`validate_findings`), and `report.py` (`render`).

[access]: https://docs.github.com/en/code-security/reference/permissions/repository-security-advisory

## Related

- [GitHub draft advisory API](https://docs.github.com/en/rest/security-advisories/repository-advisories#create-a-repository-security-advisory)
- [OpenRouter structured outputs](https://openrouter.ai/docs/guides/features/structured-outputs)
- [GitHub trusted-base PR event](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#pull_request_target)
- [Build](build.md) — local toolchains.
- [Test](test.md) — regression and CI checks.
- [Threat model](../threat-model.yaml) — canonical review input.
