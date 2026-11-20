### Prefix cache: faster checkpoint restores

- A prefix-cache hit restored from an SSD checkpoint now reads and authenticates the checkpoint's chunks ahead of the copy into memory, on several threads, instead of one chunk at a time. The restored state is the same bytes as before; only the time to the first token on a hit changes.
- The read-ahead memory is charged with the restore's other scratch memory. When memory is tight, the restore runs the earlier way rather than being refused.
- `DARKBLOOM_PREFIX_CACHE_PARALLEL_STAGE=0` turns it off; the LaunchAgent forwards it.
