package api

import "github.com/eigeninference/d-inference/coordinator/telemetry/metrics"

// Keep the existing API metric types as aliases while collection is owned by
// telemetry/metrics. There is one registry and one set of synchronization rules.
type MetricLabel = metrics.Label
type Metrics = metrics.Registry
type GaugeFunc = metrics.GaugeFunc
type MetricsSnapshot = metrics.Snapshot
type Histogram = metrics.Histogram
type HistogramSnapshot = metrics.HistogramSnapshot

func NewMetrics() *Metrics                      { return metrics.New() }
func NewHistogram(buckets []float64) *Histogram { return metrics.NewHistogram(buckets) }
func DefaultBuckets() []float64                 { return metrics.DefaultBuckets() }
