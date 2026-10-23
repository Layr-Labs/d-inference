### Many-file model download progress

- Redraw the foreground model download display (`darkbloom models download` and the `darkbloom start` picker) in place as a compact block: one bar per file being transferred and a total row with files completed, bytes, rate and ETA. A model with more files than the terminal has rows, such as an 88-shard checkpoint, previously redrew below itself several times a second and scrolled without end.
- Fit every row to the terminal width with aligned columns. Narrow windows shorten file names (keeping shard numbers), then drop the per-file rate, before dropping the bar; rows wider than an 80-column terminal previously wrapped and caused the same endless scrolling with only a few files.
- Print each finished file once, as it completes, in aligned columns instead of listing every file again at the end. Output without a terminal no longer prints each file twice.
- Time each file from when its transfer starts, and again after a fallback restart, so shards that waited in the queue no longer report a low rate and an inflated ETA.
