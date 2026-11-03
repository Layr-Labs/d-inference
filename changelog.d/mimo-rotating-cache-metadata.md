### MiMo image-candidate pairs keep cluster prompt prefixes

- A MiMo V2.6 Flash pair serving the private, local-only image candidate no
  longer fails its requests while the cluster prefix cache is on (the
  default). That candidate is the only MiMo load with contiguous caches. MiMo
  still required the five metadata values that older MLX SDKs wrote for a
  sliding-window cache, while the pinned SDK writes seven (adding the capacity
  origin and a wrapped flag), so requests, text or image, failed at their
  first prompt-prefix capture. Prefixes are now captured and restored. The
  four text serving modes use paged histories with prefix reuse off and were
  not affected.
