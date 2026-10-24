### Nemotron Super prefix-cache routing

- The managed Nemotron 3.5 Super slot advertises its resident prefix bank to the coordinator (`prefix_cache_memory_models`), bound to the aggregate the provider published for the loaded checkpoint and the checkpoint's prompt-contract identity. Coordinator requests on Super now send lookup and ready receipts and report reused prompt tokens (`prompt_tokens_details.cached_tokens` and `inference_complete` cache usage), so cache-aware routing and cache-read pricing apply to Super. Previously the coordinator never sent Super a cache scope, so its reserved bank served no coordinator request.
- The local endpoint reports Super's reused prompt tokens instead of always `0`.
