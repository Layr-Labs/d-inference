package api

import "github.com/eigeninference/d-inference/coordinator/telemetry/metrics"

func metricKey(name string, labels []MetricLabel) string { return metrics.Key(name, labels) }
