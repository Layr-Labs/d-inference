### Inkling 2 Mini thinking off without a thought (opt-in)

- New provider switch `DARKBLOOM_INKLING_THINKING_OFF_SKIPS_THOUGHT`, off by default. With it on, an Inkling 2 Mini request that turns thinking off is kept from opening a thought with its thought marker, so the reply starts with its answer or call instead of a withheld thought and its first visible token arrives sooner. A thought that still starts another way is withheld as before.
- With it off, nothing changes: thinking off renders effort 0, at which the model may still think, and that thought is withheld.
