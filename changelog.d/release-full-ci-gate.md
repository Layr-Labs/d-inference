### Release runbook: full CI on the release head

- Before a provider release is approved and tagged, the complete CI must pass
  on the release PR's final head and on the `dev` commit the candidate was cut
  from. A failing job is fixed or re-run until it passes; a release isn't
  tagged on a red run.
