package observation

import cachemetrics "github.com/eigeninference/d-inference/coordinator/internal/observation/cachemetrics"

func (s *Owner) cacheModelLabel(model string) string {
	if s == nil {
		return cachemetrics.CacheModelLabel(nil, model)
	}
	return cachemetrics.CacheModelLabel(s.registry, model)
}
func (s *Owner) cacheModelCount(name string, value int64, labels ...MetricLabel) {
	var metrics cachemetrics.CacheMetricRegistry
	if m := s.Metrics(); m != nil {
		metrics = m
	}
	cachemetrics.CacheModelCount(metrics, s.Count, name, value, labels...)
}
func (s *Owner) cacheModelTiming(name string, ms float64, labels ...MetricLabel) {
	var metrics cachemetrics.CacheMetricRegistry
	if m := s.Metrics(); m != nil {
		metrics = m
	}
	cachemetrics.CacheModelTiming(metrics, s.Count, name, ms, labels...)
}
func (s *Owner) cacheModelSelectionLabels(model string, tags []string) []MetricLabel {
	return cachemetrics.CacheModelSelectionLabels(s.registry, model, tags)
}
