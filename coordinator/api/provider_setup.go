package api

import (
	"context"
)

func (s *Server) CloseProviderConnections(ctx context.Context) bool {
	return s.providers.CloseProviderConnections(ctx)
}
func (s *Server) WaitProviderHandlers(ctx context.Context) bool {
	return s.providers.WaitProviderHandlers(ctx)
}
func (s *Server) InitializeTrustReuseJournal() error { return s.trust.InitializeTrustReuseJournal() }
func (s *Server) SeedTrustReuseCache(ctx context.Context) error {
	return s.trust.SeedTrustReuseCache(ctx)
}
func (s *Server) SeedCodeAttestCache(ctx context.Context) { s.trust.SeedCodeAttestCache(ctx) }
