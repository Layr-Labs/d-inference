# Open historical source references

> Last updated: 2026-09-29

Use this procedure to read the original source behind a frozen report when a
file has moved or disappeared from the current tree. Reports keep their
original text and source paths. Freshness stamps contain only dates; immutable
source URLs, body evidence, and committed document history identify source
snapshots.

## Prerequisites

Use a browser or a local Git checkout containing complete document history and
the referenced source commits. A shallow clone may need
`git fetch --unshallow origin`; check first with
`git rev-parse --is-shallow-repository`. CI's Docs Lint job checks out full
history (`.github/workflows/ci.yml`, `docs`).

## Steps

1. Prefer the immutable source URL or explicit source revision in the record's
   body. For a migrated record, recover its most recent old freshness header
   within the current link's continuous history, following renames and stopping
   at the record's creation, copy boundary, or a break in link continuity:

   ```bash
   git log --follow -p -- docs/reports/2026-08-25-v0.8.12-prefill-deadline-admission.md
   ```

   Use the exact `commit` from that legacy header for the original source
   citations and line anchors. A newly created date-only record instead uses
   the commit that introduced the particular Markdown link. Inspect the patch,
   not just a prose mention or fenced Markdown sample; a later reintroduction
   is a new link and cannot reuse a legacy header from before the break. Resolve
   relative links from the document's location at each commit: an adjusted link
   can retain its destination across a rename, while unchanged text can point
   somewhere different. Never guess a commit from the freshness date. The
   current renamed source file may have different contents or line numbers.
2. Open the original source snapshot in GitHub, then follow the path from the
   report. These snapshots cover the source links affected by the provider
   folder reorganization:

   | Report | Original source snapshot |
   |---|---|
   | [v0.8.12 prefill admission](../reports/2026-08-25-v0.8.12-prefill-deadline-admission.md) | [e0a0d16d9](https://github.com/Layr-Labs/d-inference/tree/e0a0d16d9cedaa01d836ae88d021fcb9718c6556) |
   | [Admission calibration baseline](../reports/2026-09-06-admission-calibration-baseline.md) | [bbf6f83d4](https://github.com/Layr-Labs/d-inference/tree/bbf6f83d4bbe66ae1a78c8f5cec898e3fbff5783) |

3. To read a file locally, use `git show` with the original path. For example:

   ```bash
   git show e0a0d16d9:provider-swift/Tests/ProviderCoreTests/ConfigTests.swift
   ```

   This reads the historical blob without changing your checkout. The same
   source is available through its
   [immutable GitHub link](https://github.com/Layr-Labs/d-inference/blob/e0a0d16d9cedaa01d836ae88d021fcb9718c6556/provider-swift/Tests/ProviderCoreTests/ConfigTests.swift).

## Verify

Run `make docs-check` after a source move. When a frozen record's relative
source link no longer resolves in the working tree, the checker requires that
exact target at the recovered legacy commit or the date-only link's introduction
commit (`scripts/docs-historical-source.py`, `source_exists`). Historical link
extraction ignores fenced samples; their presence cannot backdate a real link.
The current checker still validates link-shaped text inside samples, so preserve
frozen examples and use immutable source URLs for new samples of retired paths.
Unresolvable or malformed legacy stamps, absent link provenance, shallow history, and missing
historical objects or targets remain errors. For an uncommitted new record with
a retired source path, cite an immutable source URL rather than borrowing an
unrelated older commit. Current documentation and links to documentation pages
still require current targets.

## Related

- [Documentation rules](../AGENTS.md)
- [Build](build.md)
- [Test](test.md)
