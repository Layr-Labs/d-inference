### Tensor-parallel shares balanced by each Mac's measured speed

- Time each Mac's own share of a dense Qwen model when it loads in tensor
  parallel (at most about a second and a half, alone, nothing crossing the
  cable), and keep each Mac's newest timing per share and model for 30 days on
  the leading Mac. The next plan balances the shares by those timings: with the
  timings an M3 Ultra and an M5 Max measured, Qwen3.8 27B is planned 1:1
  instead of 2:1 after one load. A Mac short of memory skips the timing, and it
  never fails a load.
- Stop predicting a larger tensor-parallel share faster than a smaller one: a
  Mac's measured shares are no longer drawn toward its whole-model speed, and
  what the pair served corrects all of a Mac's measured shares alike.
- Read the saved share timings in `darkbloom-cluster-plan plan` (or
  `--share-probes FILE`) and name the shares used, as the setup plans.
- A load that serves the speculative head balances its shares on each Mac's measured verify window rather than its single-token step, because its rounds run windows: on the Qwen3.8 27B pair that moves the split from 3:2 to about even.
