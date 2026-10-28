### Cache hits no longer wait for a whole SSD cache sweep

- A TTL or disk-budget sweep removed its whole batch of cache files while
  holding the locks that a cache-hit lookup on the engine's submit thread and
  a donor's index publication also take. Sweeping 2,000 files in a debug build
  on an M3 Ultra held them for about a second. A sweep now removes 16 files
  per hold and rechecks ownership each time, so those waits stayed under 28 ms
  in the same measurement, while the sweep itself took 5-6% longer in the
  background.
