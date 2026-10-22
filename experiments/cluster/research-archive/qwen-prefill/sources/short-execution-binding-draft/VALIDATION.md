# CPU validation — 2026-09-14

The checker passed 51 tests on both Python 3.14 and Python 3.9.6. The tests use
fabricated native/runtime records; they do not execute an inference model.
The 21 Python files also passed Python 3.9 syntax parsing. All tested source
bytes remained unchanged during the final runs.

Root execution records, relative to `cluster-research`:

- `runs/short-execution-binding-final-20260914/execution.json` —
  `bf7475eb8c112a1518a355fe1c7092f47fd12e73b996eaa232e9932f22c4d720`.
  Includes the 51-test Python 3.14 run and four real Python CLI invocations
  against fabricated 9B/27B fresh/reused evidence packets. All four results
  are byte-identical after the returned-data isolation fix.
- `runs/short-execution-binding-final-20260914/execution-python39.json` —
  `14497bfc0f679cf2820f2cddd2c72aca1c3372fbec4b6c5844131a73c2c04393`.
  The same 51 tests pass under the peers' Python 3.9 version family.
- `short-execution-binding-race-tests-draft/run-2/execution.json` —
  `d517ac4de0f747492d952e04028e037721cd82a5a349c6498c5c0e6eca0180de`.
  Independently authored 23 file/loader regressions pass. The first test-only
  `/var` versus `/private/var` assertion failure remains in `run-1`; the fix
  normalizes only the disposable test paths, with no runtime change.

Source reviews, also relative to `cluster-research`:

- Parent/observation/result joins:
  `short-execution-parent-contract-review-draft/binding-source-review.json`,
  `2cae360de3e74d8ae76ab8f603bcbc41ac026550df25466701bf8cd4136e6c05`.
- Subsequent returned-data isolation fix:
  `short-execution-parent-contract-review-draft/return-isolation-delta-review.json`,
  `1ff43123c3cdbae400fcbeaaec3c0975abbe426a846f5e1f638d9e66e33889c8`.
- Input snapshots and frozen-oracle loader:
  `short-execution-binding-io-review-draft/source-review.json`,
  `3323fc9ad255c3488f888dee128a29d14652239d1ace1d7eecdfb7f24f0be849`.
  Later changes in those reviewed modules only removed unused imports; the
  final race tests and parent-review supporting pins bind the resulting bytes.

The modularity pass keeps file I/O, manifest identity, parent policy, runtime
DTO validation, oracle loading, result identity and orchestration separate.
Returned reports cannot mutate the shared policy or oracle pin dictionaries.

No actual c079 short-parity output exists at this checkpoint. The 403 current
native/runtime archive members still match the installed snapshot; record
`runs/short-execution-binding-20260914/native-sources-unchanged.json` has SHA
`5e64d522fe54992f66bce714a5ebe0044418359840266f56c4fe75e7b6a6e087`.
This CPU work does not qualify M3 arithmetic, model memory, physical transport,
27B long-prefill admission, provider support or the throughput goal.
