### Inkling 2 Mini: speculative decoding for requests with logprobs

- Inkling 2 Mini requests that ask for `logprobs` / `top_logprobs` now use the
  model's speculative decoding head, with exact acceptance only. Each token's
  logprob and top logprobs are read from the same target pass that checks the
  drafts, and Inkling checks each position with the arithmetic of a one-token
  step, so tokens, logprobs and the top-logprob list (members, order and ties)
  are the same as without speculation.
- `DARKBLOOM_MTP_LOGPROB_ROWS=0` (or `off`, `false`, `no`) keeps such rows
  target-only; the LaunchAgent forwards it.
