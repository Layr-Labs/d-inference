### CI (master): Release Integrity runs its checks at the same time

- Release Integrity's 52 offline checks (and the new runner's own tests) run in one step through `scripts/run-concurrent-checks.py`, one per CPU of the runner at a time, longest first, instead of one after another across ten steps.
- Each check's output prints whole, in the listed order, with its exit status and duration. The step fails, naming each failed check, once every check has run. No check is retried, skipped or given a new time limit, and each gets its own `TMPDIR`.
