### Inkling 2 Mini serves long prompts

- Every Inkling 2 Mini request whose prompt plus `max_tokens` passed 41,432 tokens failed at once with HTTP 500 ("Inference generation failed"; streamed, a 200 then an error chunk). The DSpark drafter's per-request pool was granted less than the paged pool's segments charge.
- The SDK now grants that pool what its segments charge, so Inkling 2 Mini serves long prompts.
- Inkling 2 Mini serves a 524,288-token window (prompt plus output), half its checkpoint's 1,048,576: the largest window measured with the drafter on. An output that would pass it is cut to what the prompt leaves, and a prompt of 524,288 tokens or more is refused as a context error (HTTP 400 `context_length_exceeded`) before any memory is allocated for it. `/v1/models` reports 524,288.
- A paged pool that still cannot be reserved is refused as retryable capacity (HTTP 503) instead of an untyped 500.
