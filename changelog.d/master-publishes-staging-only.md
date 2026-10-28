### Master release lane publishes no dev release

- A push to `master` no longer publishes a dev release to DevNet. `.github/workflows/release-swift.yml` routes a master push to the `staging` lane only, which still runs only when the `STAGING_ENABLED` repository variable is `true`. A `vX.Y.Z` tag still publishes production.
- The `release-swift.yml` dispatch has no `dev` environment choice. `validation_only=true` runs the `dev` lane as a signed validation build that is never published, in place of the chosen environment.
- `scripts/resolve-provider-release.sh` refuses a dev publication from `master` and a master push routed to dev. DevNet gets its provider releases from the d-inference `dev` branch through `.github/workflows/release-dev-branch.yml`.
- The source gate on `master` (`verify_workflow_source`) admits a push to `dev` for the `dev` environment only, and only for a GitHub-verified commit on `dev` ancestry. The resolver stamps that build `X.Y.Z-dev.branch.N`. A dev push routed to staging or prod and a push from any other branch are refused. The tag and master checks are unchanged.
- `build-and-release` checks the final archived app against the self-updater's designated requirement (Apple anchor, `io.darkbloom.provider`, team `SLDQ2GJ6TL`) before upload.
