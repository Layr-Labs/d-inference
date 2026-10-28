# Public selected-stage loading support

Outtree support, 2026-09-14. Copy the two files under `proposed/` to the same
repository-relative paths, then apply `docs.patch`. This package changes no
runtime, fixture, model metadata or test expectation. Root already owns the
single fixture integration into `Tests/SelectedStageLoading`: V2
`StageLoadCheck.swift` and unchanged `StageLoadCheckMain.swift`.

The runner maps the corrected 30-source list exactly. It uses repository-relative
paths, the existing registered-profile metadata, candidate support and observed
fixture builders. Temporary compiler output is removed by an exit trap. The
optional source-directory argument has the same contract as adjacent runners.
No Swift compiler, runner, native entry, SSH, model payload or candidate output
was executed/read by this support author. Source pins/path checks, bash syntax
and read-only patch applicability are the local validation.

Root reported the separate V2 fixture passed 21 accepted/122 rejected under
Swift 6 warnings-as-errors with empty stderr. The private source map binds that
receipt. Public-runner and native materialization qualification remain pending.
The public page makes no live-gate, partial-load cleanup, tensor-value parity,
provider eligibility, 8K-fit or performance claim from the pure fixtures.

The README patch removes its obsolete "registered 27B materialization remains
unwired" statement when adding the new entry. Two neighboring pages still
contain that older statement: `QWEN_DENSE_LOADING.md` and
`QWEN_DENSE_CONSTRUCTOR_PROBE.md`. Root should replace those historical wiring
statements with a link to the new page during integration; no claim of native
27B loading should replace them. They are outside the requested README/test
insertion patch.
