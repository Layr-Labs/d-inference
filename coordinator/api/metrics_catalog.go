package api

import (
	"github.com/eigeninference/d-inference/coordinator/metrics"
)

// This file is the seam between the server and the metric catalog
// (coordinator/metrics). The catalog owns every metric's name, type and tag
// keys; the two adapters below are the only things that know how those samples
// reach this package's two sinks.
//
// Both adapters resolve their destination per sample rather than capturing it,
// because the Datadog client is wired after NewServer returns (SetDatadog) and
// because the catalog must not hold a reference that outlives a test server.

// noopCatalog is what s.metrics() returns for a Server that was assembled by
// hand rather than by NewServer, which is how most of this package's tests build
// one. It is built once: a catalog is immutable after construction and this one
// records nowhere, so sharing it is safe and a recording call on such a server
// is a no-op instead of a nil dereference.
var noopCatalog = metrics.Noop()

// metrics returns the declared metric catalog. NewServer always builds one; the
// fallback exists so adding a metric to a code path can never be the reason a
// test that constructs &Server{...} directly panics.
func (s *Server) metrics() *metrics.Metrics {
	if s.catalog != nil {
		return s.catalog
	}
	return noopCatalog
}

// newCatalog builds the catalog for a server: DogStatsD as the metric path, the
// in-process registry as the mirror for the names GET /v1/admin/metrics has
// always served.
func (s *Server) newCatalog() *metrics.Metrics {
	return metrics.NewWithSink(catalogSink{s: s}, catalogMirror{s: s}, s.logger)
}

// catalogSink sends declared samples to DogStatsD. It reproduces exactly what
// the ddIncr/ddCount/ddGauge/ddHistogram shims did — including the nil check
// that makes an unconfigured coordinator drop samples silently rather than fail
// a request path — so migrating a call site to the catalog changes the name's
// declaration, never its delivery.
type catalogSink struct{ s *Server }

func (c catalogSink) Count(name string, value int64, tags []string) {
	if c.s.dd != nil {
		c.s.dd.Count(name, value, tags)
	}
}

func (c catalogSink) Gauge(name string, value float64, tags []string) {
	if c.s.dd != nil {
		c.s.dd.Gauge(name, value, tags)
	}
}

// Distribution submits `|d|`: raw values to the intake, which is what
// datadog.Client.Histogram sends. The name difference is deliberate — see
// metrics.Distribution.
func (c catalogSink) Distribution(name string, value float64, tags []string) {
	if c.s.dd != nil {
		c.s.dd.Histogram(name, value, tags)
	}
}

// catalogMirror writes the subset of declared metrics that also exist in the
// in-process registry behind GET /v1/admin/metrics, under the `_total` names
// that endpoint has always used. The pairing lives in the declaration; this
// adapter only translates the label type, which cannot be shared because the
// catalog must not import api.
//
// It nil-checks the registry for the same reason catalogSink nil-checks the
// Datadog client: a Server assembled field-by-field has neither, and telemetry
// is never the reason a request path panics.
type catalogMirror struct{ s *Server }

func (c catalogMirror) AddCounter(name string, delta int64, labels ...metrics.Label) {
	if c.s.adminMetrics != nil {
		c.s.adminMetrics.AddCounter(name, delta, mirrorLabels(labels)...)
	}
}

func (c catalogMirror) ObserveHistogram(name string, value float64, labels ...metrics.Label) {
	if c.s.adminMetrics != nil {
		c.s.adminMetrics.ObserveHistogram(name, value, mirrorLabels(labels)...)
	}
}

func mirrorLabels(labels []metrics.Label) []MetricLabel {
	if len(labels) == 0 {
		return nil
	}
	out := make([]MetricLabel, len(labels))
	for i, l := range labels {
		out[i] = MetricLabel{Name: l.Name, Value: l.Value}
	}
	return out
}
