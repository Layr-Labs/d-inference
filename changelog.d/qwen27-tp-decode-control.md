### Qwen tensor-parallel decode control in the selection sum

- A Qwen tensor-parallel pair's plain decode step now carries the next step's
  plan and report in its own sealed selection sum, so the step pays one sealed
  sum and one host read fewer than before. Tokens, logits and native state are
  unchanged; assisted (MTP) rows, prompt steps and idle steps keep their own
  exchange.
- Owner answers, cancellations and joins now apply one step later while plain
  rows decode. A row decodes its next token once the owner answered the token
  before it, so an answer that arrives while a step computes no longer leaves
  the row idle for a step. Rank 0 still publishes a token only after the
  owner's answer to the one before it. A token selected before a stop answer is
  never published, so streamed text, usage and logprobs are unchanged.
- A clean stop the owner asks for (a stop string, for example) can cost one
  more forward, which is discarded. On a one-lane pair every such stop after a
  request's first token does (assisted rows excepted), and that request's
  finish arrives one decode step later than before.
- Both ranks of a pair must run this build: the load agreement binds the new
  control wire (`qwen-tp-independent-history-batch-v2-folded-control`).
- `darkbloom-cluster-tp-check qwen-decode` times the batch driver's decode on
  two ranks over the loopback ring, with the control exchanged or folded, and
  checks that both retire the same tokens.
