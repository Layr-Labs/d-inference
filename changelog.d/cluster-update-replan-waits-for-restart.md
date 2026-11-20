### Two-Mac pairs: an update no longer leaves the pair stopped when the leader re-plans too early

- A pair's update installs the release on both Macs before it restarts their cluster services. If the leading Mac's old service noticed the new release in between, it started setting the pair up again, the restart ended that halfway, and the pair stayed "■ Stopped" until someone ran `darkbloom start`. Now the leading Mac waits while its own update is restarting (the restarted service sets the pair up again), and a service ended halfway puts the pair's start back when it runs again.
- `DARKBLOOM_CLUSTER_UPDATE_REPLAN_GUARD=0`, exported before `darkbloom start` or `darkbloom cluster`, turns this off.
