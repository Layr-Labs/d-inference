### Inkling 2 Mini thinking off without a thought (opt-in)

- New provider switch `DARKBLOOM_INKLING_THINKING_OFF_SKIPS_THOUGHT`, off by default. With it on, an Inkling 2 Mini request that turns thinking off cannot open a thought: the reply starts with its answer or call instead of a withheld thought, so the first visible token and the whole reply arrive sooner.
- With it off, nothing changes: thinking off renders effort 0, at which the model may still think, and that thought is withheld.
