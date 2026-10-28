### Master release lane publishes no dev release

- A push to `master` no longer publishes a dev release to DevNet. `.github/workflows/release-swift.yml` routes a master push to the `staging` lane only, which still runs only when the `STAGING_ENABLED` repository variable is `true`. A `vX.Y.Z` tag still publishes production.
- The `release-swift.yml` dispatch has no `dev` environment choice. `validation_only=true` runs the `dev` lane as a signed validation build that is never published, in place of the chosen environment.
- `scripts/resolve-provider-release.sh` refuses a dev publication and a branch push routed to dev. DevNet gets its provider releases from the d-inference `dev` branch through `.github/workflows/release-dev-branch.yml`.
