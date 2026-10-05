package api

// SyncModelCatalog retains the application setup entrypoint while the catalog
// owner serializes publication and provider convergence.
func (s *Server) SyncModelCatalog() { s.catalog.SyncModelCatalog() }
