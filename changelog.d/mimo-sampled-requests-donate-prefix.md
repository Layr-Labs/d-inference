### Sampled MiMo V2.6 requests now leave prefix checkpoints

- A MiMo request that cannot speculate recorded no MTP prompt history, so it
  wrote no complete-prefix checkpoint. That covers every sampled request
  (temperature above 0, the catalog default) and greedy requests with a `stop`
  string or a penalty. Repeats and later turns of such conversations prefilled
  from scratch unless a speculating greedy request had left a checkpoint. The
  SDK's MiMo head now records that history, as the Qwen 3.5, Nemotron Super
  and Qwen4 heads already do, so these requests write the same checkpoints a
  speculating request writes.
- Answers are unchanged: text was identical with and without the change in
  every seeded and greedy case checked. Measured with the same SDK change on
  0.10.17 in local mode (M5 Ultra, full model), a sampled repeat of a
  ~9.8K-token prompt reused 8,192 tokens (1.9 s instead of 6.4 s), a greedy
  repeat with a `stop` string took 2.0 s instead of 6.4 s, and a 19.7K-token
  sampled repeat's time to first token fell from 14.1 s to 1.4 s. An uncached
  sampled prompt took 0.4–4 % longer.
- Media requests are unchanged and still record nothing.
