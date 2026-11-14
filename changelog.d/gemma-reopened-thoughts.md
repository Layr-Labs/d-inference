### Gemma reopened thought channels

Adopt the opt-in SDK parser fix. `DARKBLOOM_GEMMA_REOPENED_THOUGHTS=1` enables it (the LaunchAgent forwards it to an installed service); unset or `0` retains current behavior. On a service Mac, change it with `darkbloom start`, which re-installs the service plist (`darkbloom restart` keeps the old value). Every reopened thought span routes to reasoning, and stray channel-close markers are absorbed. The collected path shares the streaming state machine. Native, JSON and escape-quoted tool argument data stays opaque to channel routing.
