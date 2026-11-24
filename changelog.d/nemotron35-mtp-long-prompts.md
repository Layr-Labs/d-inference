### Nemotron 3.5 MTP serves long prompts

- With MTP on, a Nemotron 3.5 Lightning request whose prompt plus `max_tokens` reached about 166,000 tokens could fail at once: the MTP assistant's per-request paged pool was granted less than the paged pool's segments charge. The SDK now grants that pool what its segments charge, as it does for Inkling 2 Mini's drafter.
- A pool that still cannot be reserved is refused as retryable capacity (HTTP 503), not as an untyped 500.
