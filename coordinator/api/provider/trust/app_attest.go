package trust

import (
	"context"

	attestservice "github.com/eigeninference/d-inference/coordinator/appattest/service"
	"github.com/eigeninference/d-inference/coordinator/internal/provider/application"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// Preserve the server configuration surface while the feature owns its config.
type AppAttestShadowConfig = attestservice.Config

// The API owns HTTP/WS dispatch, shared telemetry and the generic release
// catalog. All App Attest workers and mutable session state belong to Service.
func (s *Owner) AppAttestFeature() *attestservice.Service {
	s.appAttestOnce.Do(func() {
		s.appAttest = attestservice.New(s.trustCoverageCtx, s.appAttestShadow, attestservice.Dependencies{
			Store: s.store, Registry: s.registry, Logger: s.logger,
			Metrics: attestservice.Metrics{Incr: s.observation.Incr, Count: s.observation.Count, Gauge: s.observation.Gauge, Histogram: s.observation.Histogram},
			Emit: func(fields map[string]any) {
				s.observation.Emit(nil, protocol.SeverityInfo, protocol.KindCustom, "App Attest shadow observation", fields)
			},
			SendTrustStatus:      s.sendTrustStatus,
			CurrentReleasePolicy: s.currentAppAttestReleasePolicy,
			RefreshReleasePolicy: s.releases.RefreshAppAttestReleaseCatalog,
		})
	})
	return s.appAttest
}

func (s *Owner) StartAppAttestShadow(ctx context.Context, p *registry.Provider, r *protocol.RegisterMessage, account ...string) *attestservice.Session {
	authenticated := ""
	if len(account) > 0 {
		authenticated = account[0]
	}
	return s.AppAttestFeature().StartSession(ctx, p, r, authenticated)
}

func (s *Owner) AppAttestIdentityCandidate(r *protocol.RegisterMessage, account string) bool {
	return s.AppAttestFeature().IdentityCandidate(r, account)
}

func (s *Owner) providerServingAuthorizationStatus(p *registry.Provider) *protocol.ProviderServingAuthorization {
	return application.ServingStatus(s.registry, s.AppAttestFeature(), p)
}

// Approval and generation close over the same immutable shared release view.
func (s *Owner) currentAppAttestReleasePolicy() attestservice.ReleasePolicy {
	return application.ReleasePolicy(s.releases.Policy())
}
