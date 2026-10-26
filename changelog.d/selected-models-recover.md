### Selected models recover their residency automatically

- A selected model the startup preload skipped or failed to load for memory, or left untried at the slot cap, is now retried on the capacity tick: after 30 s, backing off to every 10 minutes, at once after any unload, and when a placement hold or an idle threshold ends. Previously nothing retried it, so behind a busy model outside the selection it stayed cold until a restart.
- A retry loads without evicting a selected model. It may first unload only idle models outside the selection (no request in flight, no Autopilot hold or pin, idle for at least two minutes) whose memory makes the room, and it waits while a live Autopilot lease manages residency.
- `darkbloom status` prints `Retrying <model> when memory frees; next check in …` with what blocked the last check, and `Configuration change needs a restart to apply: enabled_models adds/removes …` when the saved filter differs from the one the running daemon started with.
