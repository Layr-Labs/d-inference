package catalog

// Invalidate removes all cached model catalog responses so the
// next request picks up any changes made by admin endpoints.
func (s *Controller) Invalidate() {
	if s.readCache == nil {
		return
	}
	for _, typeFilter := range []string{"", "text"} {
		for _, includeAliases := range []bool{false, true} {
			s.readCache.Invalidate(modelCatalogCacheKey(typeFilter, includeAliases))
		}
	}
	// /v1/models entry memo + list bodies (both include_builds values) and the
	// OpenRouter feed are derived from the same catalog; drop them too so an
	// admin alias/registry change is visible on the next request instead of
	// after their 2s/5s TTLs (which remain the bound for out-of-band DB edits).
	for _, includeBuilds := range []bool{false, true} {
		s.readCache.Invalidate(modelEntriesCacheKey(includeBuilds))
		s.readCache.Invalidate(modelListBodyCacheKey(includeBuilds))
	}
	s.readCache.Invalidate(openRouterFeedCacheKey)
	// stats:v1 is deliberately NOT evicted here: the stats refresher recomputes
	// it every minute, and evicting it made every concurrent /v1/stats request
	// rerun the multi-second usage analytics statements.
}
