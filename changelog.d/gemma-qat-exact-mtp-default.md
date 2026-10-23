### Gemma QAT sampled MTP acceptance

- Default `gemma-4-26b-qat-4bit` to exact target-prefix MTP acceptance so sampled reasoning retains the target distribution. Explicit acceptance overrides retain their precedence; paged attention, prefix caching and greedy acceptance are unchanged.
- Full-model quality and performance qualification remain required before release.
