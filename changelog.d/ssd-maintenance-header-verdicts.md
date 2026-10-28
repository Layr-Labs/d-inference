### Faster SSD cache maintenance after each checkpoint write

- After every checkpoint or attention-block write, cache maintenance walks the
  whole SSD cache root to enforce its TTL and disk budget. It used to open and
  parse the header of every cache file on each pass. It now remembers each
  readable header until the file changes, so a pass parses only new, changed
  or unreadable headers. With 5,000 cache files a pass falls from 1.84 s to
  0.16 s (debug build, M3 Ultra). TTL, budget and ownership decisions are
  unchanged.
