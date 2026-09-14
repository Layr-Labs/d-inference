package api

import (
	"context"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/providercontrol/verification"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// Existing direct API fixtures reach the real owner without duplicating state,
// cryptographic gates, restore behavior or scheduler attempt observations.
type mdmVerifyOutcome = verification.Outcome

const (
	mdmVerifyGranted        = verification.Granted
	mdmVerifyTransient      = verification.Transient
	mdmVerifyTerminal       = verification.Terminal
	providerRestoreAttempts = verification.RestoreAttempts
)

func (s *Server) verifyProviderAttestation(ctx context.Context, id string, p *registry.Provider, msg *protocol.RegisterMessage) error {
	return s.newProviderVerifier().VerifyRegistration(ctx, id, p, msg)
}

func (s *Server) restorePersistedProviderState(ctx context.Context, p *registry.Provider, serial, key string) error {
	return s.newProviderVerifier().Restore(ctx, p, serial, key)
}

func (s *Server) stageDurableMDAChain(p *registry.Provider, serial string) {
	s.newProviderVerifier().StageMDA(p, serial)
}

func (s *Server) attachCachedMDAProof(id string, p *registry.Provider, result attestation.VerificationResult) bool {
	return s.newProviderVerifier().AttachCachedMDA(id, p, result)
}

func (s *Server) verifyProviderViaMDM(ctx context.Context, id string, p *registry.Provider, result attestation.VerificationResult) mdmVerifyOutcome {
	return s.newProviderVerifier().VerifySecurityInfo(ctx, id, p, result)
}

func (s *Server) verifyAppleDeviceAttestation(ctx context.Context, id string, p *registry.Provider, result attestation.VerificationResult, udid string) {
	s.newProviderVerifier().VerifyMDA(ctx, id, p, result, udid)
}
