package api

import (
	"log/slog"

	"github.com/eigeninference/d-inference/coordinator/api/releases"
)

func (s *Server) newReleaseAPI() *releases.Controller {
	return releases.New(releases.Dependencies{
		Store:              func() releases.Store { return s.store },
		Cache:              func() releases.Cache { return s.readCache },
		Policy:             s.releasePolicyOwner,
		Logger:             func() *slog.Logger { return s.logger },
		ReleaseKey:         func() string { return s.releaseKey },
		CDNURL:             func() string { return s.r2CDNURL },
		BinaryHashEnforced: func() bool { return s.binaryHashEnforce },
		ProvidersWithHash:  func(hash string) int { return s.registry.CountProvidersByBinaryHash(hash) },
		AuthorizeAdmin:     s.isAdminAuthorized,
		BearerToken:        extractBearerToken,
	})
}
