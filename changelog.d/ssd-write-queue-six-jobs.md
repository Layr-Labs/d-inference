### Deeper SSD prefix-cache write queue

- Both SSD prefix-cache writers now hold up to six donations (`writeQueueMaxJobs = 6`, was 2) before dropping a new one as `write_queue_full`. More of the prefixes donated while the single SSD writer is busy are now written, so later requests can reuse them instead of recomputing them.
- Memory stays within the existing bounds: queued attention blocks must still fit the unchanged queued-byte cap (1,280 MiB at the default stage cap), and a queued complete checkpoint keeps its donor state and I/O scratch charged to the engine admission or process memory ledger, as before.
- A request that donates complete checkpoints ends its stream and releases its KV memory only after they are written or refused. Under a write backlog each of them can now wait behind up to five other checkpoints instead of one, and up to six donors (was two) can wait at once, each still holding its KV memory.
