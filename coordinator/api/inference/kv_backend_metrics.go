package inference

import (
	"github.com/eigeninference/d-inference/coordinator/internal/inference/backend"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/metrics"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

type kvBackendAttribution = backend.Attribution

func newUnknownKVBackendAttribution() kvBackendAttribution { return backend.Unknown() }
func usableMetricSample(v float64) bool                    { return metrics.UsableSample(v) }

func (s *Owner) providerKVBackendAttribution(p *registry.Provider, model string) kvBackendAttribution {
	if s == nil {
		return backend.Unknown()
	}
	return backend.ResolveProvider(p, model)
}

func (s *Owner) emitRequestBackendLatency(model string, attr kvBackendAttribution, ttftMs, decodeTPS float64) {
	if s != nil {
		s.NewMetrics().BackendLatency(model, attr, ttftMs, decodeTPS)
	}
}

func (s *Owner) NewBackendLatch() *backend.Latch {
	if s == nil {
		return backend.NewLatch(nil)
	}
	return backend.NewLatch(s.registry)
}

func (d *dispatchState) backendLatch() *backend.Latch {
	if d.servedKVSlot == nil {
		d.servedKVSlot = d.s.NewBackendLatch()
	}
	return d.servedKVSlot
}

func (d *dispatchState) attributionLatchFrozen() bool {
	_, sticky := d.terminalEvidence.Select(d.currentTerminalFailure(), false)
	return sticky || d.unservable || d.terminalClientError
}

func (d *dispatchState) kvBackendAttribution() kvBackendAttribution {
	_, sticky := d.terminalEvidence.Select(d.currentTerminalFailure(), false)
	return d.backendLatch().Resolve(d.pr, d.attributionLatchFrozen(), sticky)
}

func (d *dispatchState) exhaustedKVBackendAttribution(failure dispatchTerminalFailure, stickyFault bool) kvBackendAttribution {
	if stickyFault {
		return failure.Slot().Attribution()
	}
	return d.kvBackendAttribution()
}
