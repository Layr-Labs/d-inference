### Release jobs run in GitHub environments

- The jobs that read a release secret, and the desktop release's publication
  job, name a GitHub environment, so its deployment branch and tag policy and
  its required reviewers apply before the job starts: `build-and-release`,
  `stage-release` and `publish-release` of the provider release lane, `signing`
  of `Provider Signing Validation`, and `sign`, `sign-dmg` and `publish` of the
  desktop release.
- The provider lane uses `dev` for a dev-branch release, `staging` for a
  staging release and `prod` for a production release and for the signed
  validation build. The other workflows use `prod`.
- No other job of these workflows names an environment or reads a secret.
- Operators: each job that names an environment with required reviewers waits
  for its own approval, from someone other than the person who started the
  run, and the environment's policy must admit the ref the lane runs on
  (`refs/heads/dev` for `dev`; `refs/heads/master` for `staging`;
  `refs/heads/master`, `v*` and `desktop-v*` tags for `prod`). The secrets
  must exist in the environment before the repository-level copies are
  removed.
- The products handed from one job to the next are kept for 7 days instead of
  3, so a later approval can still download them.
- No release has run through these jobs yet.
