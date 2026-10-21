### Threat review failure recovery

- New reviews use the current trusted scanner with the PR base threat model,
  preventing old PR bases from retaining obsolete review code.
- Request native Bedrock JSON output and nonempty batch analysis while retaining
  strict local validation and the existing model, spend and merge policies.
- Recover bounded report/cache write conflicts without repeating paid requests;
  distinguish state, GitHub and OpenRouter failures in content-free diagnostics.
- Give final integration reviewers bounded exact source evidence from their own
  reviewed scope, retaining explicit omissions and human-review decisions.
- Preserve Bedrock cache-read/write input accounting and enforce finding-text
  and analysis limits on raw characters, including whitespace padding.
- Stop further model calls after backup cost-accounting failures even if the
  primary provider recovers, retaining validated findings.
