### Inkling 2 Mini serves long prompts

- Every Inkling 2 Mini request whose prompt plus `max_tokens` passed 41,432 tokens failed at once with HTTP 500 ("Inference generation failed"; streamed, a 200 then an error chunk). The DSpark drafter's per-request pool was granted less than the paged pool's segments charge.
- The SDK now grants that pool what its segments charge, so Inkling 2 Mini serves its checkpoint's context.
- A paged pool that still cannot be reserved is refused as retryable capacity (HTTP 503) instead of an untyped 500.
