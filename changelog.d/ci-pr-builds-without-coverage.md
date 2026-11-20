### Provider CI: pull requests build and test without coverage instrumentation

- Pull request runs build the provider test products without `--enable-code-coverage` and skip the report-only coverage steps (profile collection, merge, report and upload). Every test, parity check and suite audit still runs.
- Pushes and dispatches still build instrumented and report each shard's coverage. A pull request's tested-change record now says it reported no coverage (`v0`), so a push of the same tree that selects the provider lane runs it again, with coverage, instead of skipping.
- The Swift test build caches by flavor (`coverage-` or `plain-` after the recipe prefix). A pull request restores its own flavor first, then a push's coverage build of the same recipe, whose C and C++ objects stay valid.
