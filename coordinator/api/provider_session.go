package api

import (
	"context"
	"log/slog"
	"net/http"

	"github.com/eigeninference/d-inference/coordinator/inference/dispatch"
	"github.com/eigeninference/d-inference/coordinator/providercontrol/challenge"
	"github.com/eigeninference/d-inference/coordinator/providercontrol/codeidentity"
	"github.com/eigeninference/d-inference/coordinator/providercontrol/mdmscheduler"
	"github.com/eigeninference/d-inference/coordinator/providercontrol/session"
	"github.com/eigeninference/d-inference/coordinator/providercontrol/trustreuse"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/telemetry/metrics"
	"nhooyr.io/websocket"
)

func (s *Server) providerSessionDependencies() session.Dependencies {
	frames := s.inferenceFrames()
	return session.Dependencies{
		Registry: func() *registry.Registry { return s.registry },
		Store: func() session.Store {
			if s.store == nil {
				return nil
			}
			return s.store
		},
		Logger:                func() *slog.Logger { return s.logger },
		Challenges:            func() *challenge.Session { return s.newProviderChallengeVerifier().NewSession() },
		Verifier:              s.newProviderVerifier,
		Scheduler:             func() *mdmscheduler.Scheduler { return s.mdmScheduler },
		TrustReuse:            func() *trustreuse.Manager { return s.trustReuse },
		CodeIdentity:          func() *codeidentity.Manager { return s.codeIdentity },
		ReleasePolicy:         s.releasePolicyOwner,
		MinimumVersion:        func() string { return s.minProviderVersion },
		Location:              s.attachProviderLocation,
		SupportsDesiredModels: s.providerSupportsDesiredModels,
		CodeLoop:              s.codeAttestLoop,
		CodeRearm:             s.maybeRearmCodeAttest,
		Frames: session.InferenceFrames{
			Accepted: frames.Accepted, Chunk: frames.Chunk,
			Complete: frames.CompleteAt, Error: frames.Error,
		},
		LoadFailure: session.LoadFailurePolicy{Classify: classifyLoadFailure, Permanent: loadFailureIsPermanent},
		Telemetry: session.Telemetry{
			Metrics: func() *metrics.Registry { return s.metrics },
			Incr:    s.ddIncr, Emit: s.emit,
			Heartbeat: session.HeartbeatTelemetry{
				BackendWedge:  s.recordBackendWedgeTelemetry,
				MLXCache:      s.recordMLXCacheTelemetry,
				PrefixCache:   s.recordPrefixCacheTelemetry,
				PagedStorage:  s.recordPagedStorageTelemetry,
				ProcessMemory: s.recordProcessMemoryTelemetry,
			},
			Cache: session.CacheTelemetry{
				Tier:          dispatch.LowCardinalityCacheTier,
				SSDLookup:     s.emitExactCacheSSDLookup,
				SSDDonation:   s.emitExactCacheSSDDonation,
				Receipt:       s.emitCacheReceiptResult,
				ModelReceipt:  s.emitModelCacheReceipt,
				ModelLookup:   s.emitModelCacheLookup,
				ModelDonation: s.emitModelCacheDonation,
			},
		},
	}
}

func (s *Server) newProviderSession() *session.Session {
	return session.New(s.providerSessionDependencies())
}

// The HTTP upgrade stays in API; one Session owns the accepted connection.
func (s *Server) providerReadLoop(ctx context.Context, conn *websocket.Conn, providerID string, r *http.Request) {
	s.newProviderSession().Run(ctx, conn, providerID, r)
}
