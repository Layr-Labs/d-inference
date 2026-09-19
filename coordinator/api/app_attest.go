package api

import (
	"context"

	attestservice "github.com/eigeninference/d-inference/coordinator/appattest/service"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// Preserve the server configuration surface while the feature owns its config.
type AppAttestShadowConfig = attestservice.Config

func readAppAttestShadowConfig() AppAttestShadowConfig { return attestservice.ConfigFromEnvironment() }

// The API owns HTTP/WS dispatch, shared telemetry and the generic release
// catalog. All App Attest workers and mutable session state belong to Service.
func (s *Server) appAttestFeature() *attestservice.Service {
	s.appAttestOnce.Do(func() {
		s.appAttest = attestservice.New(s.trustCoverageCtx, s.appAttestShadow, attestservice.Dependencies{
			Store: s.store, Registry: s.registry, Logger: s.logger,
			Metrics: attestservice.Metrics{Incr: s.ddIncr, Count: s.ddCount, Gauge: s.ddGauge, Histogram: s.ddHistogram},
			Emit: func(fields map[string]any) {
				s.emit(nil, protocol.SeverityInfo, protocol.KindCustom, "App Attest shadow observation", fields)
			},
			SendTrustStatus:      s.sendTrustStatus,
			CurrentReleasePolicy: s.currentAppAttestReleasePolicy,
		})
	})
	return s.appAttest
}

func (s *Server) startAppAttestShadow(ctx context.Context, p *registry.Provider, r *protocol.RegisterMessage, account ...string) *attestservice.Session {
	authenticated := ""
	if len(account) > 0 {
		authenticated = account[0]
	}
	return s.appAttestFeature().StartSession(ctx, p, r, authenticated)
}

func (s *Server) appAttestIdentityCandidate(r *protocol.RegisterMessage, account string) bool {
	return s.appAttestFeature().IdentityCandidate(r, account)
}

func (s *Server) providerServingAuthorizationStatus(p *registry.Provider) *protocol.ProviderServingAuthorization {
	return s.appAttestFeature().Status(p)
}

// Approval and generation close over the same immutable shared release view.
func (s *Server) currentAppAttestReleasePolicy() attestservice.ReleasePolicy {
	snapshot := s.releaseTrustPolicy.Load()
	if snapshot == nil {
		return attestservice.ReleasePolicy{}
	}
	return attestservice.ReleasePolicy{Generation: snapshot.Generation, Known: len(snapshot.ByBinaryHash) > 0,
		Approves: func(p *registry.Provider, status *protocol.AppAttestStatus) bool {
			return appAttestReleaseApproved(snapshot, p, status)
		}}
}
