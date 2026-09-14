package api

import (
	"net/http"

	"github.com/eigeninference/d-inference/coordinator/api/catalog"
)

// catalogController shares one alias lock and the API's existing cache across
// every catalog route and runtime sync. Lazy binding also supports focused API
// fixtures that construct a Server before using catalog operations.
func (s *Server) catalogController() *catalog.Controller {
	s.catalogOnce.Do(func() {
		s.modelCatalog = catalog.New(catalog.Dependencies{
			Store:  func() catalog.Store { return s.store },
			Models: s.registry, Cache: s.readCache, Logger: s.logger,
			AdminKey: func() string { return s.adminKey },
			SelfRouteAccount: func(r *http.Request) (string, bool) {
				policy := s.resolveSelfRoutePolicy(r)
				return policy.ownerAccountID, policy.enabled
			},
			SyncCatalog: s.SyncModelCatalog,
		})
	})
	return s.modelCatalog
}
