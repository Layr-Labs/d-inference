### Faster model weight verification

- Weight hashes read each file on a separate thread one 4 MiB chunk ahead of
  SHA-256, so the uncached reads added for Nemotron Super no longer leave the
  hash waiting on the disk. Every full hash gets faster: startup registration,
  download and prefetch verification, and the fresh hashes before and after
  each load of a model with SSD prefix caching. On an M3 Ultra a full hash of
  `EigenLabs/Qwen3.8-27B-4bit-mtp` takes 2.9 s instead of 4.7 s, with the same
  digest. Weights still bypass the file cache, and the digests are unchanged.
