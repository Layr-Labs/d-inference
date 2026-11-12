### A media request a Mac can't hold now is refused as `media_memory_unavailable`

- A media request that this Mac's memory can't hold right now is refused as a retryable 503 with the reason `media_memory_unavailable` (it was `capacity_busy`), so Darkbloom sends it to another Mac without counting this Mac's capacity as full.
