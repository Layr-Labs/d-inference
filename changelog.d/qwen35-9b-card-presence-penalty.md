### Qwen 3.5 9B keeps its model card's presence penalty

- Provider 0.10.12 dropped the default `presence_penalty` of 1.5 from the catalog `Qwen3.5-9B` for requests that send none. In production its answers then ran to `max_tokens` about three times as often, and JSON `response_format` answers that ran out failed about twice as often. 0.10.13 restores the model card's 1.5 for those requests, as on the other catalog Qwen 3.5/3.6 builds.
- A request that sends its own `presence_penalty` is unchanged. With `presence_penalty` 0 the 9B still speculates under exact MTP acceptance. A penalty row does not speculate but still donates prefix-cache checkpoints.
- `DARKBLOOM_QWEN35_9B_PRESENCE_PENALTY=0` (or `off`) restores 0.10.12's default. `darkbloom start` passes it to the launchd job.
