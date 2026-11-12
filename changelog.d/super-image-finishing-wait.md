### Nemotron 3.5 Super: a request that arrives as the previous one finishes waits instead of bouncing

- A Super Mac serves one request at a time (one image at a time when it serves more) and answered any other at once with 429 `queue_full`, which sends the request to another Mac. That included requests arriving after the previous answer had ended but before its cleanup (native retirement, and the release of its image memory) had finished.
- Such a request now waits up to 1 s for that cleanup and is then served. The previous request's memory is released before the next one reserves its own, so memory use is unchanged. A request that arrives while the previous answer is still being generated is still refused at once.
