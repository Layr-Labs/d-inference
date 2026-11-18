### Faster generation via speculative decoding on Qwen models

- The Qwen 3.5/3.6 builds (`Qwen3.5-9B`, `qwen3.5-35b-a3b`,
  `qwen3.6-35b-a3b-vl-mtp-mxfp8`) apply their model card's presence penalty
  1.5 to requests that send none, and a request with a penalty never used the
  model's speculative decoding head, so almost no production request did. Rows
  with a presence or frequency penalty now speculate: each drafted position is
  checked against the target's own sample with the penalty applied over the
  answer so far plus the earlier drafts, and kept only when it matches (exact
  acceptance), so the penalty stays and answers follow the same distribution.
  One decoding request at a time speculates on these builds.
- These builds' default draft acceptance is now exact for rows without a
  penalty too (it was typical on the 35B builds); `mtp_acceptance_by_model`
  still overrides it.
- `DARKBLOOM_MTP_PENALTY_ROWS=0` (or `false`, `no`, `off`) keeps penalty rows
  target-only, as in 0.10.15; the LaunchAgent forwards it.
