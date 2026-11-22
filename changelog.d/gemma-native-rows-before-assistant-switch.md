### Gemma 4 26B: a switch for the checkpoint layout before the assistant attaches

- `DARKBLOOM_GEMMA_NATIVE_ROWS_BEFORE_ASSISTANT=0` (or `off`, `false`, `no`)
  restores the earlier prefix-cache checkpoint layout of Gemma 4 26B QAT: the
  assistant's two access layers stay native only while the MTP assistant is
  attached. MTP stays on. Unset, the current layout applies. The LaunchAgent
  forwards the switch.
