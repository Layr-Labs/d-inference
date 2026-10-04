package trust_test

import (
	attestservice "github.com/eigeninference/d-inference/coordinator/appattest/service"
	"github.com/eigeninference/d-inference/coordinator/internal/provider/application"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func (s *trustFixture) currentAppAttestReleasePolicy() attestservice.ReleasePolicy {
	return application.ReleasePolicy(s.releases.Policy())
}

func (s *trustFixture) providerServingAuthorizationStatus(p *registry.Provider) *protocol.ProviderServingAuthorization {
	return application.ServingStatus(s.registry, s.AppAttestFeature(), p)
}
