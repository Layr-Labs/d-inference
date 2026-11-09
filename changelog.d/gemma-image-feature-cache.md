### Gemma image feature cache

- Add opt-in, bounded RAM reuse of evaluated Gemma still-image encoder features within a loaded model and authenticated vision scope. Repeated images skip the tower/projector while current text and image ordering retain their own prompt and spans.
- Charge pending snapshots, hashing/hydration scratch and pinned readers against process, slot and scope budgets, with scope-aware eviction, expiry and lifecycle fences. Shutdown cancels owned preparations before draining; invalid requests preserve committed entries. Missing scope or budget and unsupported adapters remain uncached.
- Add optional `vision_cache_scope` metadata and bounded image-work profile counters. Feature hits do not reduce prompt/KV token usage or produce prefix-cache credit. Default activation and performance claims await actual-model qualification.
