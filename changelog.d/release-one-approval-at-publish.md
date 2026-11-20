### A production release asks one approval, for publication

- A production release signs, notarizes and stages (`build-and-release`,
  `stage-release`) in the GitHub environment `prod-build`, which admits
  `refs/heads/master` and `v*` tags and has no required reviewers, so the
  tag's run, or a retained-build recovery on `master`, reaches staging by
  itself.
- Publication (`publish-release`), which registers the release with the
  coordinator, still runs in `prod` and waits for one approval from someone
  other than the person who started the run.
- Dev, staging and the signed validation build keep one environment for every
  job, as before. No secret moved; `prod-build` must never hold the release
  registration key.
