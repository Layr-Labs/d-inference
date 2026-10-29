### Opt-in: answer before the checkpoint write finishes

- A request that donates a complete SSD checkpoint ends its response only
  after the checkpoint is durable, so the client waits for the write.
  `DARKBLOOM_PREFIX_CACHE_SSD_TERMINAL_BEFORE_PUBLICATION=1` (default off)
  ends an unseeded donor's response as soon as the answer is complete. The
  provider still holds the request's rows, KV reservation and service
  allowance until the write settles, so other requests see no added
  capacity. A follow-up that arrives before the write finishes prefills in
  full. Seeded requests keep the old order.
