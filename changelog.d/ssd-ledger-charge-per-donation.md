### Attention-block SSD donations write about five times faster

- GPT-OSS and Gemma write one SSD cache file per 256-token block, and each
  block's daily write-budget charge rewrote the shared ledger with a full
  flush. A donation of several blocks now reserves their summed size in one
  charge before its first write. Measured with 64-block donations on an M3
  Ultra (debug build), a donation took 73-78 ms instead of 412-445 ms with 1
  MiB blocks, and 114-118 ms instead of 502-518 ms with 4 MiB blocks.
  Another model's writes are also refused far less often while a donation is
  in flight: when two models donated 64 blocks each at the same moment, 10%
  of the blocks were refused instead of 49%. Charges still precede writes
  and are never refunded, and near the daily cap the leading blocks that fit
  are still written.
