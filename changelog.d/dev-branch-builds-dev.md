### Dev-branch provider lane builds on a dev push

- `.github/workflows/release-dev-branch.yml` now starts on a push to the `dev` branch, with the same `paths:` list as the master push of `release-swift.yml`. Dev builds dev, and master builds master; no workflow dispatches a build of another branch.
- The lane is a caller of the reusable `release-provider.yml` with `environment: dev` and `secrets: inherit`. A dev-branch build is built, signed with the Developer ID, notarized and stapled like a master build, so the installer and the provider self-updater accept it. The version stays `X.Y.Z-dev.branch.<run>`. The ad-hoc build and signing path of the lane is removed.
- The lane has no `workflow_dispatch` and no `ref` input. Its job checks `refs/heads/dev`. It runs only after master's release source gate accepts a `dev` push for environment `dev`.
