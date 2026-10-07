package cachemetrics

import (
	"math"
	"strings"

	metriclabels "github.com/eigeninference/d-inference/coordinator/internal/observation/labels"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

type CacheMetricRegistry interface {
	AddCounter(string, int64, ...metriclabels.MetricLabel)
	ObserveHistogram(string, float64, ...metriclabels.MetricLabel)
}

// Model breakdowns are internal operational metrics. The public status and
// existing exact_cache metrics retain their aggregate-only contract. Never use
// a caller's alias, provider identity, request ID, receipt nonce or prompt hash.
func CacheModelLabel(reg *registry.Registry, model string) string {
	if reg != nil {
		if id, ok := reg.CatalogModelID(model); ok && id != "" && len(id) <= 200 && !strings.ContainsAny(id, ",|\n\r\x00") {
			return id
		}
	}
	return "unknown"
}

func CacheModelCount(metrics CacheMetricRegistry, count func(string, int64, []string), name string, value int64, labels ...metriclabels.MetricLabel) {
	if metrics != nil {
		metrics.AddCounter("cache_model_"+name+"_total", value, labels...)
	}
	tags := make([]string, 0, len(labels))
	for _, label := range labels {
		tags = append(tags, label.Name+":"+label.Value)
	}
	count("routing.cache_model."+name, value, tags)
}

// Sum/sample counters work with both Datadog HTTPS and DogStatsD. The admin
// histogram preserves milliseconds for percentiles; the estimate is not a
// measured counterfactual or a claim of successful end-to-end delivery.
func CacheModelTiming(metrics CacheMetricRegistry, count func(string, int64, []string), name string, ms float64, labels ...metriclabels.MetricLabel) {
	if ms < 0 || math.IsNaN(ms) || math.IsInf(ms, 0) || ms >= float64(math.MaxInt64)/1000 {
		return
	}
	CacheModelCount(metrics, count, name+"_us", int64(math.Round(ms*1000)), labels...)
	CacheModelCount(metrics, count, name+"_samples", 1, labels...)
	if metrics != nil {
		metrics.ObserveHistogram("cache_model_"+name+"_ms", ms, labels...)
	}
}

func CacheModelSelectionLabels(reg *registry.Registry, model string, tags []string) []metriclabels.MetricLabel {
	labels := []metriclabels.MetricLabel{{Name: "model", Value: CacheModelLabel(reg, model)}}
	for _, tag := range tags {
		name, value, _ := strings.Cut(tag, ":")
		labels = append(labels, metriclabels.MetricLabel{Name: name, Value: value})
	}
	return labels
}
