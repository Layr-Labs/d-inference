### Gemma 4 26B: speculative decoding for requests with stop strings or penalties

- Gemma 4 26B QAT requests that send `stop` strings, a presence penalty or a
  frequency penalty now use the model's speculative decoding head under the
  same policy as other requests. Drafts for penalty rows are kept only where they match the
  target's own sample with the penalty applied (exact acceptance), and a row
  with `stop` strings ends at the first match exactly as without speculation.
- `DARKBLOOM_MTP_STOP_STRING_ROWS=0` and `DARKBLOOM_MTP_PENALTY_ROWS=0` (or
  `off`, `false`, `no`) keep such rows target-only; the LaunchAgent forwards
  both.
