### Opt-in: answer before the checkpoint write finishes

- A request that donates a complete SSD checkpoint ends its response only
  after the checkpoint is durable, so the client waits for the write.
  `DARKBLOOM_PREFIX_CACHE_SSD_TERMINAL_BEFORE_PUBLICATION=1` (default off)
  ends an unseeded donor's response as soon as the answer is complete. The
  provider still holds the request's rows, KV reservation and service
  allowance until the write settles, so other requests see no added
  capacity. A follow-up that arrives before the write finishes can't use
  that checkpoint yet: it restores an earlier one, if any, and prefills the
  rest. Seeded requests keep the old order.
- For an installed provider, set it in the shell for `darkbloom start`,
  which writes it into the provider's launchd job; an ordinary `darkbloom
  restart` keeps the saved value. Each such request that retires at least
  1 ms after its answer is logged with that time, which for a donor is how
  long its write held its capacity after the answer (`Early terminal: request
  … retired N ms after its answer`). The 1 ms floor is a timing heuristic: on
  a busy provider a request that wrote no checkpoint can be logged too. The
  line is only in the provider log.
