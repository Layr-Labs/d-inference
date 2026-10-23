### Bounded pipeline token-credit coalescing

- Let nearby token acknowledgments join a plain-pipeline decode batch for at most a two-millisecond scheduling window. Control, new joins, prefills and lane retirement continue, while a complete batch or sole live decode lane advances immediately.
