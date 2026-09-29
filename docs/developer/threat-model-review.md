# Configure advisory threat-model review

> Last updated: 2026-09-28 · commit `d8c07c2bb`

The OpenRouter reviewer scans every PR change against the entire canonical threat
model and posts actionable findings in one updatable public PR comment. It includes
complete before/after text for changed files and a separate cross-file integration
pass independently with Opus 5.5 and GPT-6 Astra, then combines their advice with
model attribution. Findings and incomplete scans never block merging or request changes.

## Prerequisites

- Repository access to Actions secrets and variables.
- An OpenRouter key with credit and a spend limit suitable for automatic reviews.
- Access through that key to `anthropic/claude-opus-5.5` and `openai/gpt-6-astra`,
  both supporting structured outputs.

## Steps

1. Add repository Actions secret `OPENROUTER_API_KEY` through **Settings → Secrets
   and variables → Actions**, or use `gh secret set OPENROUTER_API_KEY --repo
   Layr-Labs/d-inference` and enter the key interactively. Never commit it.
2. Set repository variable `THREAT_REVIEW_MODELS` to
   `anthropic/claude-opus-5.5,openai/gpt-6-astra`. It accepts one or two distinct,
   comma-separated OpenRouter IDs supporting `response_format: json_schema`.
   This overrides legacy `THREAT_REVIEW_MODEL`, which still selects a single
   reviewer when the plural variable is absent. With neither variable set, the
   default is Opus 5.5 plus Astra. No separate OpenAI key is needed.
3. Land the workflow through the reviewed PR process. Opening, updating, reopening,
   marking a PR ready, or retargeting it into `master`/`main` triggers a scan.
   The `edited` event runs only when `changes.base.ref.from` is present; title/body
   edits and drafts are skipped before entering the job's cancellation group.
   The workflow must be present on the base branch before it can run.
4. Keep **Threat Model Review (advisory)** out of required status checks. No separate
   GitHub PAT is needed: the built-in token has contents read and PR write access.
5. Set an OpenRouter key spend limit and monitor usage. Full scans make multiple
   paid requests per model, each containing the full threat model. Two reviewers
   run two full scans, so budget for both models. Every new PR revision,
   including a fork update, can trigger another scan.

## Verify

Run the cloud-free suites:

```sh
python3 .github/scripts/test-threat-model-review.py
python3 .github/scripts/test-threat-full-scan.py
python3 .github/scripts/test-threat-ensemble.py
```

They cover immutable Git sources, large changes beyond the former cutoffs,
complete source segmentation, missing-patch reconstruction, cross-file findings,
incomplete batches, binary/submodule coverage, and the comment lifecycle. A real
loopback HTTP test exercises source retrieval, OpenRouter requests, and PR delivery
with synthetic credentials. Ensemble tests verify independent full scans,
disagreement, exact duplicate attribution, per-model failures, deadline handling,
and Astra-compatible request parameters. Release Integrity runs all three suites
in ordinary CI.

After activation, inspect **Actions → Threat Model Review (advisory)** and the PR:

| Outcome | Author feedback |
|---|---|
| Findings | One public bot comment with severity, source links, threat references, trigger, impact, suggested fix, and which model raised each finding. |
| Complete clean first scan | Actions summary only. |
| Complete clean follow-up | Existing comment updated to clear old findings. |
| Incomplete scan | Public comment explicitly says the scan is incomplete; it never presents missing coverage as clean. |
| One model fails | Findings from the completed reviewer remain visible; the comment names the incomplete reviewer. A clean surviving review does not clear the incomplete status. |
| Incomplete retry of the same head | Earlier findings remain visible, followed by the incomplete retry report and any new partial findings. Identical retry reports do not accumulate. If both reports exceed the comment budget, the existing comment is preserved and the retry report appears in the Actions summary. A complete rerun can replace earlier findings. |
| PR head changed, target branch changed, or PR closed during scan | Stale output is suppressed. |
| Target branch tip advances, with the same PR head and merge base | The review still publishes against its recorded immutable base snapshot; unrelated merges do not silently discard feedback. The merge base is checked before and after live file enumeration and before publication. A changed or unverifiable comparison produces incomplete coverage; new findings from that scan are discarded, while prior same-head findings remain visible. |

Legacy comments from the previous reviewer are updated in place. If several bot
reports exist, the newest canonical report is preferred and updated first;
other matching bot reports become links to it, leaving one active findings comment.
Findings are
unconfirmed and visible to anyone who can read the public PR. Authors and reviewers
must validate them before changing code.

## Scan scope and troubleshooting

`source.complete_files` reads complete before/after Git blobs pinned to the PR's
merge base and head. It rebuilds the diff instead of relying on truncated API
patches, includes new files outside existing threat patterns, and retains mode,
rename, empty-file, and deletion metadata. Findings about a verified empty file
use `line: 0` only on an existing base/head side listed in `metadata_citation_sides`;
the comment links to that file and labels the citation as file metadata. Absent,
nonempty and unread sides cannot use that citation. Ordinary citations may point
to any actual line in the completely retrieved source, including context outside
the diff hunk; patch-only input remains restricted to visible patch lines. Symlink blobs are read as data; their
targets are never followed. PR source is never checked out or executed.

`scan.scan` submits every changed-file text segment in batches, with the entire
trusted-base `docs/threat-model.yaml` in every request. Each response must acknowledge
all submitted units. A separate integration pass examines the batch analyses and
findings for interactions across files; large analysis sets are reduced through
additional integration passes without dropping batches. An unchanged summary count
still advances when its serialized size shrinks, allowing
the next pass to combine summaries. Equal-sized or growing same-count results stop
as incomplete; the shared scan deadline also bounds repeated reductions.
Candidate findings pass through integration review for validation and consolidation;
unsupported candidates and duplicates are removed. Finding references may cite any
ID defined by a canonical block-list `id` field, including assets (`A-*`), adversaries
(`ADV-*`), boundaries (`TB-*`), threats (`T-*`) and security findings (`SEC-*`).
Unknown IDs and IDs only mentioned in prose are rejected; defined non-threat IDs
do not invalidate an otherwise supported finding.

`ensemble.review_models` runs this entire process independently for each model,
in configured order. Models do not see the other reviewer's analysis. The combined
report removes exact duplicate findings and lists both reviewers on them; differing
assessments remain separate for human validation. No majority vote or final model
can veto a finding from the other completed review. Both must finish for a complete
scan. A model failure does not prevent the next review, and a global timeout
preserves already completed reviews while marking remaining ones incomplete.

The prompt checks assets, trust boundaries, assumptions, threats and mitigations,
including new attack surfaces and threat-model updates required by a PR. Context
includes complete changed files; unchanged callers elsewhere in the repository are
not automatically retrieved. This is a full PR text scan, not a re-audit of every
repository file or a guarantee that all vulnerabilities will be found.

Resource limits produce an **incomplete** result rather than truncating source:
GitHub's file-list ceiling is 3,000 files, each API JSON response is bounded to
4,000,000 bytes, and the canonical threat model must fit 220,000 characters. Source
collection also caps combined before/after UTF-8 content at 8,000,000 bytes,
counting repeated uses of a cached blob again because each file can produce its
own diff and evidence. The PR file inventory (including fallback patches) and
cached Git trees each have a separate 8,000,000-byte serialized JSON budget.
Exceeding any aggregate budget stops collection and posts an
incomplete result asking the author to split the PR; no partial scan is called complete.
Source
units contain up to 32,000 characters split at whole lines; a single longer line
requires manual review. Batches have an 80,000-character encoded-unit budget.
Non-UTF-8/binary files and submodule contents require manual review and are named
in the comment. A request permits 16,384 output tokens; incomplete responses or a
full 32-finding response are treated as incomplete. A report exceeding the single
comment's 60,000-character budget asks the author to split the PR. The process has
a shared 50-minute scan deadline within a 60-minute workflow timeout. Models run
sequentially, so a first scan that uses the whole budget leaves the second incomplete.
If that one-shot deadline interrupts final verification or publication, the runner
refreshes the comment identity and retries delivery once with an incomplete status,
retaining completed findings. Refreshing first avoids blindly repeating a POST
whose response was interrupted after GitHub created the comment.

For an incomplete scan, inspect the listed files and source/model availability,
OpenRouter balance/rate limits, and whether splitting the PR would allow complete
feedback. Raw API responses and credentials are never printed. OpenRouter and the
selected providers receive the threat model, changed source, and their review analyses;
their data-handling settings apply. Disable the workflow or remove its key to stop
new paid reviews. Operational failures remain non-blocking.

Implementation: `.github/workflows/threat-model-review.yml`,
`.github/scripts/threat_review/runner.py` (`run`), `source.py` (`Sources`,
`complete_files`), `scan.py` (`scan`), `review.py` (`prepare`, `model_call`,
`validate_findings`), `ensemble.py` (`configured_models`, `review_models`),
`client.py` (`GitHub`), and `report.py` (`render`).

## Related

- [OpenRouter structured outputs](https://openrouter.ai/docs/guides/features/structured-outputs).
- [OpenAI Astra API guidance](https://developers.openai.com/api/docs/guides/latest-model?model=gpt-6-astra) — structured output and supported parameters; sampling parameters are omitted.
- [GitHub trusted-base PR event](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#pull_request_target).
- [Build](build.md) — local toolchains.
- [Test](test.md) — regression and CI checks.
- [Threat model](../threat-model.yaml) — canonical review input.
