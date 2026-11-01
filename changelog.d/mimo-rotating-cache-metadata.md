### MiMo cluster prefix snapshots and contiguous hand-offs

- MiMo V2.6 Flash pairs that keep contiguous caches, such as image candidates,
  again capture and restore cluster prompt prefixes and hand over the producer
  stage in a phase split. Since the MLX SDK began writing seven metadata values
  for a sliding-window cache (adding its capacity origin and a wrapped flag),
  MiMo refused every such cache on these paths: a request failed at its first
  prefix capture or at its hand-off. The four text serving modes use paged
  histories with prefix reuse off and were not affected.
- The checks stay strict. Only the ring the model builds is accepted, and its
  whole metadata, wrapped flag included, must match what the prompt's frames
  give. A ring with a kept prefix, another step or a rewind reserve is refused.
