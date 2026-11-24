### Provider CI: the plan checks out scripts only and skips its no-op first job

- `Plan the components to test` (`.github/workflows/provider-plan.yml`) keeps its blobless full-history clone but checks out only `scripts/` and the top-level files: about 5 MiB of the tree's 480 MiB of file contents. The classifier diffs commits, never the working tree, and the tree lookup is a script, so the selected components are unchanged. That checkout took 16 s p50 (21 s p90) in 84 runs of 2026-11-23; in run 45344316700 it fetched the history for 6.2 s and then the working tree's contents for 7.5 s.
- `Resolve the commit to test` runs on a dispatch only. On a pull request or a push it did nothing and still held the plan for about 4 s. It is now skipped there, so the plan's second job starts at once, and the skipped job's outputs stay empty, as they were.
- Every other job, every selection and every test runs as before.
