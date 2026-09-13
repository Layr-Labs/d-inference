package datadog

// HistogramOrGauge records a snapshot through the configured metric transport.
// DogStatsD-only deployments retain agent-side histogram aggregation. With an
// API key, the HTTPS series API is authoritative and receives the latest value
// for each tag set as a gauge; it does not provide histogram percentiles.
//
// This is opt-in: Histogram remains DogStatsD-only for existing callers. The
// presence of a Statsd client cannot select the transport because opening a UDP
// socket succeeds even when no agent is listening.
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
