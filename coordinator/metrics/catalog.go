package metrics

import (
	"log/slog"

	"github.com/eigeninference/d-inference/coordinator/datadog"
)

// Metrics is the coordinator's metric catalog. One value is built at startup and
// handed to whatever records samples; the subsystem fields below are the whole
// public surface, and a call site never names a metric with a string.
//
// Every field is non-nil after New or Noop, so nothing has to nil-check a
// collector on a request path. A catalog built with no Datadog client discards
// its samples but still validates label arity, which is what tests use.
type Metrics struct {
	Billing      *BillingMetrics
	Store        *StoreMetrics
	Trust        *TrustMetrics
	Session      *SessionMetrics
	MDMScheduler *MDMSchedulerMetrics

	sinks *sinks
	// declared is registration order, which is the order Document() prints and
	// the order a duplicate is detected in.
	declared []*declaration
	byName   map[string]*declaration
}

// New builds the catalog against the live DogStatsD client and the in-process
// registry that backs GET /v1/admin/metrics. Both may be nil: a nil client
// discards (the agentless dev path), a nil mirror simply means no declaration's
// mirror name is used.
//
// It panics on a duplicate metric name. That is a static property of the
// declarations — no input reaches it — so the catalog test that calls New is
// enough to keep it from ever happening in a running process, and a duplicate
// silently merging two unrelated series into one is worse than not starting.
func New(client *datadog.Client, mirror Mirror, logger *slog.Logger) *Metrics {
	var dd Sink = discard{}
	if client != nil {
		dd = dogstatsd{client: client}
	}
	return NewWithSink(dd, mirror, logger)
}

// NewWithSink builds the catalog over a caller-supplied sink. It exists because
// the coordinator's Datadog client is wired after the server is constructed
// (SetDatadog), so the server passes a sink that resolves the client per sample
// rather than one that captures it — the same late binding the string-literal
// call sites had, where every one of them nil-checked s.dd.
func NewWithSink(dd Sink, mirror Mirror, logger *slog.Logger) *Metrics {
	if dd == nil {
		dd = discard{}
	}
	m := &Metrics{
		sinks:  &sinks{dd: dd, mirror: mirror, logger: logger},
		byName: make(map[string]*declaration),
	}
	m.Billing = newBillingMetrics(m)
	m.Store = newStoreMetrics(m)
	m.Trust = newTrustMetrics(m)
	m.Session = newSessionMetrics(m)
	m.MDMScheduler = newMDMSchedulerMetrics(m)
	return m
}

// Noop is a catalog that records nowhere. It is the constructor for tests and
// for any caller that has no Datadog client, and it exists so "metrics are off"
// never means "the code path is different".
func Noop() *Metrics { return New(nil, nil, nil) }
