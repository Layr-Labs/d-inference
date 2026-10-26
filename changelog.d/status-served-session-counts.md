### Status says which requests the served count covers

- `darkbloom status` now prints `Requests served since the daemon started (… ago): N | output tokens: M` instead of `Requests served: N | tokens: M` with no window. The count restarts with the daemon and includes requests that ended early on a coordinator cancel or a dropped connection, which the coordinator may not pay for, and free requests to your own machine. Status prints how many ended early and points to the console's Earnings page for paid jobs.
- The line still starts with `Requests served` and keeps `|` between the two counts. A script that matches the literal `Requests served:` or reads a fixed word position needs updating.
- `darkbloom doctor` describes the same counts as completed since the daemon started rather than "reported this session".
- The daemon state file records `cancellations_partial_complete` beside the served totals.
