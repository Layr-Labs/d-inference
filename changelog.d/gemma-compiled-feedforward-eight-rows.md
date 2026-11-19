### Gemma 4 26B: faster decode with many requests at once

- The compiled feed-forward (mlx-swift-lm #450) now also covers decode steps
  of 8 to 16 rows and MTP verification of 4 to 8 rows of two tokens. Before,
  it stopped where the experts' assignments start to be sorted (8 decode rows,
  4 verification rows). Output is bit-identical.
- `DARKBLOOM_GEMMA4_COMPILED_FEEDFORWARD_SORTED=0` (or `off`, `false`, `no`)
  keeps those steps on the eager graph; the LaunchAgent forwards it.
