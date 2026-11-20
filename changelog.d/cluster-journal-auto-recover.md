### A pair whose start stopped too early no longer needs `darkbloom cluster recover`

- When a pair's part was stopped seconds after the pair came up (for example by the setup's approval step), every later start could end with "Unresolved native ownership journal … Run `darkbloom cluster recover`" until someone ran that command. The cluster service now runs the same recovery by itself, once, and starts the part again. It still clears nothing while anything from the earlier session runs, and it never stops a process.
- `DARKBLOOM_CLUSTER_JOURNAL_AUTO_RECOVER=0`, exported before `darkbloom start` or `darkbloom cluster`, turns this off.
