### Two-Mac pairs: the service log says when the leading Mac waits for its own update's restart

- While a pair's update installs a release and restarts the cluster services, the leading Mac doesn't set the pair up again until its restart. Its `~/.darkbloom/cluster-setup/service.log` now says so once: "this Mac's update to … restarts the cluster service next: setting the cluster up again waits for that restart". `DARKBLOOM_CLUSTER_UPDATE_REPLAN_GUARD=0` turns off the wait and the line.
