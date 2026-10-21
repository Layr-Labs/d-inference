### Provider start and terminal hangups

- Stop the interactive model picker (`darkbloom start`, `darkbloom switch`) when its terminal goes away. It previously kept reading a closed input and used a full processor core until the process was killed; it now cancels as Esc does, restores the terminal mode and leaves the provider unchanged.
- Drain a provider started by hand (`start --local`, or `start --foreground` in a terminal) when its terminal window closes, the same cooperative stop as Ctrl-C and `SIGTERM`, instead of ending the process at once. The launchd-run provider and a start made with `SIGHUP` ignored (for example under `nohup`) behave as before.
