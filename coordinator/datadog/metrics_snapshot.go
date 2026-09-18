package datadog

// LockedGauge records a value as a gauge for metric names that are already
// stored in Datadog as gauges and therefore cannot become anything else.
//
// This is not a modelling preference — it is a compatibility constraint, and it
// is the only reason this entry point exists instead of a call to Gauge. A
// metric name Datadog has already typed as a gauge cannot be reinterpreted as a
// distribution: the submission is rejected for that name and every existing
// query on it breaks. The `provider.mlx_*` names shipped on master as gauges, so
// they are pinned here.
//
// Everything else that reports a per-heartbeat snapshot uses Histogram (a
// DogStatsD distribution) instead. A gauge is the wrong type for a fleet-wide
// reading: datadog-go aggregates gauges client-side per (name, tag set), and
// these are tagged only by chip family and provider version, so one flush window
// keeps a single arbitrary provider's value and drops the rest — no fleet
// average, maximum or percentile is recoverable. New snapshot metrics must not
// be added here; add them as distributions.
func (c *Client) LockedGauge(name string, value float64, tags []string) {
	c.Gauge(name, value, tags)
}
