### CI runs every test of `dev` every hour

- `.github/workflows/ci-dev-hourly.yml` runs from `master`'s schedule at minute 7 of every hour. It dispatches CI (dev) on `dev`, unless a dispatched run is still queued or in progress.
- A dispatched CI (dev) run selects every component and never skips a tested tree: every provider and cluster shard, the focused and release build checks and the non-blocking GPU shards. It uses the lanes, sizes and caches of a push to `dev`, and saves caches as that push does, so the 1.87 GB MiMo audio codec stays cached on `dev`. Dispatched runs share one concurrency group: a new dispatch never cancels a running one.
- When a job of a dispatched run fails, `Report hourly failures` comments on the open issue `Hourly full dev CI failures` (and opens it when none is open) with the run, the commit and the failed jobs.
