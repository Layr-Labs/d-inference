### Cache hits no longer wait for a whole SSD cache sweep

- A TTL or disk-budget sweep removed its whole batch of cache files while
  holding the locks that a cache-hit lookup on the engine's submit thread
  and a donor's index publication also take. Sweeping 2,000 files in a debug
  build on an M3 Ultra held them for about a second. A sweep now removes 16
  files per hold and rechecks ownership each time, so those waits stayed at
  30 ms or less in the same measurement (28.4 ms at worst), while the sweep
  itself took up to 12% longer in the background.
