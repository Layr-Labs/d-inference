package datadog

// HistogramOrGauge records a snapshot through the configured metric transport.
// DogStatsD-only deployments retain agent-side histogram aggregation. With an
// API key, the HTTPS series API is authoritative and receives the latest value
// for each tag set as a gauge.
//
// Histogram now has an HTTPS leg of its own (metrics_distribution.go), so this
// no longer exists to keep these callers reachable without an agent. It stays
// because a gauge is the right type for what they submit — a heartbeat's latest
// memory or cache reading, where the question is "what is it now", not "how is
// it distributed" — and because a metric name already submitted as a gauge
// cannot be reinterpreted as a distribution without breaking every query on it.
func (c *Client) HistogramOrGauge(name string, value float64, tags []string) {
	if c == nil {
		return
	}
	if c.httpMetrics() {
		c.Gauge(name, value, tags)
		return
	}
	c.Histogram(name, value, tags)
}
