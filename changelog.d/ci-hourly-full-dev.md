### CI runs every test of `dev` every hour

- `.github/workflows/ci-dev-hourly.yml` runs from `master`'s schedule at minute 7 of every hour. It dispatches CI (dev) on `dev`, unless a dispatched run is still queued or in progress.
- `dev`'s CI (dev) runs a dispatch with every component selected and reports a failed dispatched run on the issue `Hourly full dev CI failures`.
