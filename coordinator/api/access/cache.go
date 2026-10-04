package access

// InvalidateAPIKeyCache fences in-flight reads and removes the cached credential.
func (s *Owner) InvalidateAPIKeyCache(token string) {
	s.apiKeyCache.Invalidate(token)
}

// InvalidateAllAPIKeyCache is called before and after by-ID credential mutations.
func (s *Owner) InvalidateAllAPIKeyCache() {
	s.apiKeyCache.InvalidateAll()
}
