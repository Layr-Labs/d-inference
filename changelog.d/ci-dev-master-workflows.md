### CI has a dev workflow and a master workflow; dev runs only the tests

- The CI test jobs (the component classifier, the route job, the provider shards and their summary, the cluster jobs and the `Provider Tests` gate) are one reusable workflow, `provider-tests.yml`. `ci-dev.yml` runs it for pull requests into `dev` and pushes to `dev`; `ci-master.yml` runs it for pull requests into `master` and pushes to `master`, with Release Integrity and Docs Lint beside it. `ci.yml` is gone.
- Pull requests into `dev` no longer run Release Integrity, Docs Lint, Commit Signatures or Docs Impact. Pull requests into `master` run all of them, as before; Release Integrity keeps its check name, which `master`'s ruleset requires.
- The test jobs' checks are now named after the caller's job, for example `Tests / Provider Tests`.
- Release Integrity and Docs Lint no longer ask the Darkbloom route for a runner: a run attempt is routed once, and that request belongs to the test jobs. They run on their former fallback, `blacksmith-4vcpu-ubuntu-2404`.
