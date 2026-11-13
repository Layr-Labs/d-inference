### Gemma reopened thought channels

Adopt the opt-in SDK parser fix. `DARKBLOOM_GEMMA_REOPENED_THOUGHTS=1` enables it for a foreground provider; unset or `0` retains current behavior. Every reopened thought span routes to reasoning, and stray channel-close markers are absorbed. The collected path shares the streaming state machine. Native, JSON and escape-quoted tool argument data stays opaque to channel routing.
