package api

import (
	"context"
	"log/slog"
	"net/http"
	"time"

	"github.com/eigeninference/d-inference/coordinator/inference/dispatch"
	"github.com/eigeninference/d-inference/coordinator/inference/ingress"
	"github.com/eigeninference/d-inference/coordinator/mediafetch"
	"github.com/eigeninference/d-inference/coordinator/promptcontract"
	"github.com/eigeninference/d-inference/coordinator/ratelimit"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// inferenceIngress shares the live server services with one request owner.
// Mounting routes does not capture mutable store, limiter or profiler settings.
func (s *Server) inferenceIngress() *ingress.Controller {
	if s == nil {
		return nil
	}
	s.ingressOnce.Do(func() {
		s.ingressController = ingress.New(ingress.Dependencies{
			Registry:                 func() *registry.Registry { return s.registry },
			Store:                    func() ingress.Store { return s.store },
			Logger:                   func() *slog.Logger { return s.logger },
			Dispatch:                 s.inferenceDispatch,
			Settlement:               s.inferenceSettlement,
			BillingConfigured:        func() bool { return s.billing != nil },
			FirstContentDeadlineBase: func() time.Duration { return s.firstContentDeadlineBase },
			ServabilityGate:          func() bool { return s.servabilityGate },
			MediaResolver:            func() *mediafetch.Resolver { return s.mediaResolver },
			ConsumerTokens:           func() *ratelimit.TokenLimiter { return s.consumerTokenLimiter },
			ServiceTokens:            func() *ratelimit.TokenLimiter { return s.serviceTokenLimiter },
			KeyTokens:                func() *ratelimit.KeyTokenLimiter { return s.keyTokenLimiter },
			OutputAdmissionEstimator: func() *ratelimit.OutputAdmissionEstimator { return s.outputAdmissionEstimator },
			PromptArtifacts:          func() *promptcontract.Provisioner { return s.promptArtifacts },
			PromptContract:           func() *promptcontract.Client { return s.promptContract },
			PromptPreloader:          func() *promptcontract.PreloadController { return s.promptPreloader },
			ModelShed:                s.modelShed,
			SealedRequest:            isSealedRequest,
			Metrics:                  inferenceMetrics{server: s},
			Observer:                 ingressObserver{server: s},
		})
	})
	return s.ingressController
}

// FirstContentDeadline keeps the public configuration entry point while the
// ingress owner applies the existing request-absolute deadline policy.
func (s *Server) FirstContentDeadline(model string, estimatedPromptTokens int) time.Duration {
	return s.inferenceIngress().FirstContentDeadline(model, estimatedPromptTokens)
}

func SetPromptContextCalibrationFromEnv(raw string) int {
	return ingress.SetPromptContextCalibrationFromEnv(raw)
}

func (s *Server) reconcileOutputAdmission(pr *registry.PendingRequest, actualOutputTokens int) {
	s.inferenceIngress().ReconcileOutputAdmission(pr, actualOutputTokens)
}

type ingressObserver struct{ server *Server }

func (o ingressObserver) NewProfile(r *http.Request, model, publicModel string, stream bool) *registry.RequestProfile {
	return o.server.newRequestProfile(r, model, publicModel, stream)
}
func (ingressObserver) ParsedStream(ctx context.Context, stream bool) {
	if o := requestOutcomeFromContext(ctx); o != nil {
		o.mu.Lock()
		o.record.Stream = &stream
		o.mu.Unlock()
	}
}
func (ingressObserver) DBCall(rp *registry.RequestProfile, start time.Time) { profileDBCall(rp, start) }
func (o ingressObserver) Rejection(info dispatch.Rejection)                 { o.server.recordRejection(info) }
func (o ingressObserver) RequestLocation(r *http.Request) *store.ProviderLocation {
	return o.server.requestLocation(r)
}
func (o ingressObserver) ExactCachePlan(result registry.CachePlanResult) {
	o.server.emitExactCachePlan(result)
}
