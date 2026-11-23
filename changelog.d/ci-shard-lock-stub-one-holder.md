### Provider CI: the build-database test always has exactly one holder

- `scripts/test-provider-test-shards.py`'s check that processes starting together without `--disable-build-manifest-caching` find the build database locked could fail at random: its stand-in for SwiftPM took the lock with SQLite's `BEGIN EXCLUSIVE` and no wait, which refuses every process when they start at the same moment (one peer's shared read blocks the others), so all three exited 1 instead of exactly two.
- The stand-in now takes the lock with an exclusive create of `.build/build.db.holder`, so exactly one process holds it until all have tried. Test-only; the runner and SwiftPM's flags are unchanged.
