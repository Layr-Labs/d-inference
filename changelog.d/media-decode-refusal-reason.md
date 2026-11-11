### A media decode refusal no longer marks the provider's token budget as full

- A video or audio reader that fails twice with a decoder, hardware or interruption fault, and a Nemotron Super video whose decode allowance runs out, are still refused as a retryable 503 (failure code `capacity`). Their error reason is now `media_memory_unavailable`, not `capacity_busy`.
- The coordinator still sends the request to another provider, up to its three capacity refusals. It no longer reads the refusal as a full token budget, so the provider's budget for the model is not clamped to zero for up to 5 minutes, and the provider gets no capacity strikes.
