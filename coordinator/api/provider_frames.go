package api

import (
	"log/slog"

	"github.com/eigeninference/d-inference/coordinator/inference/dispatch"
	"github.com/eigeninference/d-inference/coordinator/inference/providerframe"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// inferenceFrames binds one shared frame service without reading or copying the
// mutable resources used by its callbacks. Directly constructed servers retain
// the original empty cache and zero unknown-frame counter.
func (s *Server) inferenceFrames() *providerframe.Service {
	s.providerFrameOnce.Do(func() {
		s.providerFrameService = providerframe.New(providerframe.Dependencies{
			Registry: func() providerframe.Registry {
				if s.registry == nil {
					return nil
				}
				return s.registry
			},
			Logger:          func() *slog.Logger { return s.logger },
			Attempts:        s.inferenceAttempts,
			Settlement:      s.inferenceSettlement,
			ClaimSettlement: s.claimSettlement,
			RetainProfile:   s.retainProviderProfile,
			ReconcileOutput: s.reconcileOutputAdmission,
			BackendAttribution: func(p *registry.Provider, model string) dispatch.KVBackendAttribution {
				return s.inferenceDispatch().ProviderKVBackendAttribution(p, model)
			},
			Metrics:  inferenceMetrics{server: s},
			Outcomes: providerFrameOutcomes{server: s},
			Telemetry: providerframe.Telemetry{
				UnknownFrame:   s.emitUnknownFrame,
				ClientGone:     s.emitClientGone,
				PartialSuccess: s.recordPartialSuccessCompletion,
				BackendLatency: s.emitRequestBackendLatency,
			},
			Cache: providerframe.CacheTelemetry{
				Usage:      s.emitModelCacheUsage,
				ExactUsage: s.emitExactCacheUsage,
				Terminal:   s.emitCacheSelectionTerminal,
				TTFT:       s.emitCacheSelectionTTFT,
			},
		})
	})
	return s.providerFrameService
}

type providerFrameOutcomes struct{ server *Server }

func (o providerFrameOutcomes) RouteOutcome(requestID string, attempt int, model string, outcome *store.InferenceRouteOutcome) {
	o.server.updateInferenceRouteOutcomeWithModel(requestID, attempt, model, outcome)
}

func (o providerFrameOutcomes) PendingOutcome(pr *registry.PendingRequest, outcome *store.InferenceRouteOutcome) {
	o.server.updateInferenceRouteOutcomeForPending(pr, outcome)
}
