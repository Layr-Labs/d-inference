### Dev-branch provider lane builds on a dev push

- `.github/workflows/release-dev-branch.yml` now starts on a push to the `dev` branch, with the same `paths:` list as the master push of `release-swift.yml`. It builds and publishes the pushed dev commit. Dev builds dev, and master builds master; no workflow dispatches a build of another branch.
- The lane has no `workflow_dispatch` and no `ref` input. Both checkouts use the pushed commit, so the shared build step's source check holds. Before this change, the first dispatch failed at that check because the dispatching `master` commit differed from the built commit.
- Both jobs check `refs/heads/dev`. The build job holds no secret. The publish job runs the dev commit's publication scripts with only the `DEV_*` repository secrets and never runs the built binary.
