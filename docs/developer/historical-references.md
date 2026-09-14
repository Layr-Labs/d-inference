# Open historical source references

> Last updated: 2026-09-14 · commit `a16c87ff2`

Use this procedure to read the original source behind a frozen report when a
file has moved or disappeared from the current tree. Reports keep their
original text and source paths; their freshness stamp identifies the source
snapshot.

## Prerequisites

Use a browser or a local Git checkout containing the stamped commit. A shallow
clone may need `git fetch --unshallow origin`; check first with
`git rev-parse --is-shallow-repository`. CI's Docs Lint job checks out full
history (`.github/workflows/ci.yml`, `docs`).

## Steps

1. Read the `commit` in the document's freshness stamp. Use that commit for
   source citations and line anchors. The current renamed file may have
   different contents or line numbers.
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
exact target in the stamped commit. Missing historical objects or targets
remain errors. Current documentation and links to documentation pages still
require current targets.

## Related

- [Documentation rules](../AGENTS.md)
- [Build](build.md)
- [Test](test.md)
