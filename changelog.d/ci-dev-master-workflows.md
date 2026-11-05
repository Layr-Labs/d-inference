### CI has a dev workflow and a master workflow; dev runs only the tests

- Two reusable workflows hold the CI jobs: `provider-plan.yml` (the component classifier, the tested-change lookup and the run's one Darkbloom route request) and `provider-tests.yml` (the provider shards, the cluster jobs and the `Provider Tests` gate). `ci-dev.yml` runs both for pull requests into any branch but `master` (`dev` and stacked branches) and for pushes to `dev`. `ci-master.yml` runs both for pull requests into `master` and pushes to `master`, with Release Integrity and Docs Lint beside them. `ci.yml` is gone.
- Pull requests into `dev` no longer run Release Integrity, Docs Lint, Commit Signatures or Docs Impact. Pull requests into `master` run all of them, as before; Release Integrity keeps its check name, which `master`'s ruleset requires. The `Provider Tests` gate runs the cluster plan audit and the CI plan self-tests on every run, `dev` included.
- The test jobs' checks are now named after the caller's job, for example `Tests / Provider Tests`.
- Release Integrity and Docs Lint read their Linux lanes from the plan's route request, with `blacksmith-4vcpu-ubuntu-2404` as the fallback.
