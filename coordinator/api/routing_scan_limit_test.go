package api

// Routing-scan concurrency limit tests (2026-09-01 congestion collapse).
//
// Server.routingScanSem bounds how many provider-selection scans may run
// concurrently: excess dispatch goroutines park on the channel instead of
// piling CPU-bound fleet scans onto saturated cores, and one that cannot
// acquire within its remaining first-content budget sheds as a
// capacity-shaped retryable 429 (errRoutingScanSaturated / reason
// routing_saturated) — never a 5xx, never another scan.
