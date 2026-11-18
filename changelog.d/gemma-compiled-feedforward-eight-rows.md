### Gemma 4 26B: faster decode with 8 or more requests at a time

- The compiled feed-forward now also covers decode steps of 8 to 16 rows and
  MTP verification of 4 to 8 rows of two tokens (mlx-swift-lm
  `Gemma4CompiledFeedforwardCache`). Before, it stopped at 7 rows, where the
  experts' assignments start to be sorted. Outputs keep their bits.
- `DARKBLOOM_GEMMA4_COMPILED_FEEDFORWARD_SORTED=0` (or `off`, `false`, `no`)
  keeps those rows on the eager graph; the LaunchAgent forwards it.
