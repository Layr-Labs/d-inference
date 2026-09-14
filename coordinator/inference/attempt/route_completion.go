package attempt

// errorClassClientGoneAfterCommitCompleted is the route-outcome error_class for a
// request whose consumer disconnected after commit and whose provider then
// completed (provider paid, consumer charged). It is shared by the route-outcome
// writer (completeRouteOutcome) and the partial_success metric so the wire class
// can never drift between the stored outcome and the dashboard counter.
const ErrorClassClientGoneAfterCommitCompleted = "client_gone_after_commit_provider_completed"
