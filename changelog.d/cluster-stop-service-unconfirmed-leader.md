### `cluster stop --service`: a leading Mac the other Mac doesn't answer stops its own service

- On a leading Mac whose cluster service restarted, a command that acts as the leader first waits for the service to confirm that this Mac leads. The wait was a fixed 40 s. It now also covers the confirmation window the service publishes, up to 80 s.
- When that wait still ends unconfirmed and the service says the other Mac doesn't answer, `darkbloom cluster stop --service` stops this Mac's cluster service alone, as `--local-only` does, says that the pair wasn't stopped from here, and exits 0. Before this it refused and left this Mac's service running (seen on a DevNet pair whose leading Mac's service had restarted while its disk was full, the other Mac's service off). While the other Mac answers, the stop still refuses, as before.
- `DARKBLOOM_CLUSTER_LEADERSHIP_WINDOW_WAIT=0` keeps the fixed wait, and `DARKBLOOM_CLUSTER_STOP_ALONE_UNCONFIRMED=0` restores the refusal.
