### Gemma reopened thought channels

Adopt the opt-in SDK parser fix. `DARKBLOOM_GEMMA_REOPENED_THOUGHTS=1` enables it (the LaunchAgent forwards it to an installed service); unset or `0` retains current behavior. Every reopened thought span routes to reasoning, and stray channel-close markers are absorbed. The collected path shares the streaming state machine. Native, JSON and escape-quoted tool argument data stays opaque to channel routing.

On by default since 0.10.13 (measured on Gemma 4 26B in its ON state); `DARKBLOOM_GEMMA_REOPENED_THOUGHTS=0` restores 0.10.12's parsing.
