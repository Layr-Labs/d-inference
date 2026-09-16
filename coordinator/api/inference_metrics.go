package api

type inferenceMetrics struct{ server *Server }

func (m inferenceMetrics) Incr(name string, tags []string) { m.server.ddIncr(name, tags) }
func (m inferenceMetrics) Count(name string, value int64, tags []string) {
	m.server.ddCount(name, value, tags)
}
func (m inferenceMetrics) Histogram(name string, value float64, tags []string) {
	m.server.ddHistogram(name, value, tags)
}

func (m inferenceMetrics) Enabled() bool { return m.server.dd != nil }
func (m inferenceMetrics) Gauge(name string, value float64, tags []string) {
	m.server.ddGauge(name, value, tags)
}
