package routerecord

// maxTelemetryReadRows is the hard upper bound on rows returned by the routing
// telemetry readers (InferenceRouteRecordsSince / RejectionRecordsSince). These
// tables grow unbounded over time, so the readers always cap the result set
// (newest-first) to keep an admin query — or a wide `since` window — from
// loading the whole table into memory. Narrow the time window to see older rows.
const MaxTelemetryReadRows = 50000
