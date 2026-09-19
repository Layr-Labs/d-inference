package service

// Metrics keeps feature instrumentation independent of the API/Datadog adapter.
// Nil hooks are harmless in deterministic unit tests.
type Metrics struct {
	Incr      func(string, []string)
	Count     func(string, int64, []string)
	Gauge     func(string, float64, []string)
	Histogram func(string, float64, []string)
}

func (s *Service) ddIncr(name string, tags []string) {
	if s.metrics.Incr != nil {
		s.metrics.Incr(name, tags)
	}
}

func (s *Service) ddCount(name string, value int64, tags []string) {
	if s.metrics.Count != nil {
		s.metrics.Count(name, value, tags)
	}
}

func (s *Service) ddGauge(name string, value float64, tags []string) {
	if s.metrics.Gauge != nil {
		s.metrics.Gauge(name, value, tags)
	}
}

func (s *Service) ddHistogram(name string, value float64, tags []string) {
	if s.metrics.Histogram != nil {
		s.metrics.Histogram(name, value, tags)
	}
}

func (s *Service) emit(fields map[string]any) {
	if s.emitEvent != nil {
		s.emitEvent(fields)
	}
}
