### Cluster member restarts re-register when the coordinator comes back

- A cluster member (leader or follower) that starts while its coordinator is briefly away keeps its reconnects inside its registration wait: a retry the backoff would place after the wait is made at its end and is given its own terms, as is an attempt already under way when the wait ends, so a coordinator that returns before the wait ends is reached and its in-time acceptance is honoured.
- A wait in which the coordinator was never reached now says so ("The coordinator could not be reached …") instead of "Coordinator did not accept the control-only member role."; the role check itself is unchanged.
