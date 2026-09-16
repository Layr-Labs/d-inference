package metrics

import (
	"log/slog"

	"github.com/eigeninference/d-inference/coordinator/datadog"
)

// Sink is where a declared collector's samples go. The coordinator has one real
// implementation (DogStatsD to the local agent) and one that discards, which is
// what a catalog built with no client uses; there is no in-process fallback that
// stores samples, because the agent is the only metric path.
type Sink interface {
	Count(name string, value int64, tags []string)
	Gauge(name string, value float64, tags []string)
	Distribution(name string, value float64, tags []string)
}

// Label is one (key, value) pair for the in-process mirror. The DogStatsD side
// carries `key:value` strings instead; both are rendered from the same declared
// keys and the same ordered values.
type Label struct {
	Name  string
	Value string
}

// Mirror is the in-process registry that backs GET /v1/admin/metrics. It lives
// in package api (api.Metrics), so it arrives here as an interface: this package
// must not import api, and the mirror must not need to know about the catalog.
// A collector with no mirror name never touches it.
type Mirror interface {
	AddCounter(name string, delta int64, labels ...Label)
	ObserveHistogram(name string, value float64, labels ...Label)
}

// dogstatsd adapts *datadog.Client to Sink. The rename of Histogram to
// Distribution is the point: the client's method is named for the caller's
// intent (record a distribution of values) while the wire type is `d`, and this
// package refuses to carry that ambiguity into 400 call sites.
type dogstatsd struct{ client *datadog.Client }

func (d dogstatsd) Count(name string, value int64, tags []string) {
	d.client.Count(name, value, tags)
}

func (d dogstatsd) Gauge(name string, value float64, tags []string) {
	d.client.Gauge(name, value, tags)
}

func (d dogstatsd) Distribution(name string, value float64, tags []string) {
	d.client.Histogram(name, value, tags)
}

// discard is the sink of a catalog built without a client. It is not a "metrics
// disabled" mode anyone selects: it is what tests and the agentless dev path
// get, and it exists so no call site has to nil-check a collector.
type discard struct{}

func (discard) Count(string, int64, []string)          {}
func (discard) Gauge(string, float64, []string)        {}
func (discard) Distribution(string, float64, []string) {}

// sinks is the shared state every declared collector points at: where samples
// go, and where a misuse of the declaration gets reported. One value per
// catalog, so a collector is a name plus a pointer.
type sinks struct {
	dd     Sink
	mirror Mirror
	logger *slog.Logger
}

func (s *sinks) warn(msg string, args ...any) {
	if s == nil || s.logger == nil {
		return
	}
	s.logger.Warn(msg, args...)
}
