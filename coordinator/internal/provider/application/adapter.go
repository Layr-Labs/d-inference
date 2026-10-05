package application

import (
	"github.com/eigeninference/d-inference/coordinator/api/releases"
	attestservice "github.com/eigeninference/d-inference/coordinator/appattest/service"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// ServingStatus combines the application authority with the independent legacy
// and owner-serving authorities. It never promotes advisory application state.
func ServingStatus(reg *registry.Registry, service *attestservice.Service, p *registry.Provider) *protocol.ProviderServingAuthorization {
	status := service.Status(p)
	if status != nil && status.Path != "none" {
		return status
	}
	if p != nil && reg.ProviderLegacyServingAuthorized(p) {
		return &protocol.ProviderServingAuthorization{Protocol: 1, Path: "legacy", Reason: "legacy_verification_active", SessionID: p.ID}
	}
	if reg.ProviderOwnerServingAuthorized(p) {
		if status == nil {
			status = &protocol.ProviderServingAuthorization{Protocol: 1, SessionID: p.ID}
		}
		status.Path, status.Reason = "self_route", "owner_serving_authorized"
	}
	return status
}

// ReleasePolicy keeps approval and generation on one immutable release view.
func ReleasePolicy(snapshot *releases.PolicyView) attestservice.ReleasePolicy {
	if snapshot == nil {
		return attestservice.ReleasePolicy{}
	}
	return attestservice.ReleasePolicy{Generation: snapshot.Generation, Known: snapshot.Known(),
		ContainsQualifiedRelease: snapshot.ContainsQualifiedRelease,
		Approves: func(p *registry.Provider, status *protocol.AppAttestStatus) bool {
			return snapshot.AppAttestReleaseApproved(p, status)
		}}
}
