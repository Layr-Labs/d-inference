package api

// Read-cache wiring for the consumer model catalog endpoints (GET /v1/models,
// GET /v1/models/{id}). The shared, caller-independent computation —
// listModelEntries: the registry snapshot plus the alias/registry DB lookups —
// is memoized for a short TTL. Anything per-caller (self-route owned-model
// views, key allow-lists) is applied by the handlers after the shared step and
// is never cached.

import (
	"strconv"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/types"
)

// modelListCacheTTL bounds staleness of the public model list. It carries live
// capacity fields (routable/warm providers, can_accept), so it matches the 2s
// window GET /v1/models/capacity already uses. Alias/registry admin changes
// become visible within the same bound: SyncModelCatalog's
// invalidateCatalogCache (server.go) does not know these keys yet — see
// invalidateModelListCache.
const modelListCacheTTL = 2 * time.Second

func modelEntriesCacheKey(includeBuilds bool) string {
	return "models:entries:v1:include_builds=" + strconv.FormatBool(includeBuilds)
}

func modelListBodyCacheKey(includeBuilds bool) string {
	return "models:list:v1:include_builds=" + strconv.FormatBool(includeBuilds)
}

// cachedModelEntries returns the public catalog's consumer-facing entries,
// memoized for modelListCacheTTL. The slice is shared between callers and
// must not be mutated (handlers copy the entry they return).
func (s *Server) cachedModelEntries(includeBuilds bool) ([]types.ModelEntry, error) {
	key := modelEntriesCacheKey(includeBuilds)
	if v, ok := s.readCacheGetValue(key); ok {
		if entries, ok := v.([]types.ModelEntry); ok {
			return entries, nil
		}
	}
	entries, err := s.listModelEntries(includeBuilds)
	if err != nil {
		return nil, err
	}
	s.readCacheSetValue(key, entries, modelListCacheTTL)
	return entries, nil
}

// cachedModelListBody returns the pre-serialized GET /v1/models response for
// the public catalog, byte-identical to what writeJSON would produce.
func (s *Server) cachedModelListBody(includeBuilds bool) ([]byte, error) {
	key := modelListBodyCacheKey(includeBuilds)
	if body, ok := s.readCacheGet(key); ok {
		return body, nil
	}
	entries, err := s.cachedModelEntries(includeBuilds)
	if err != nil {
		return nil, err
	}
	body, err := encodeCachedJSON(types.ModelListResponse{Object: "list", Data: entries})
	if err != nil {
		return nil, err
	}
	s.readCacheSet(key, body, modelListCacheTTL)
	return body, nil
}

// invalidateModelListCache drops the memoized public model list so the next
// request recomputes it. Intended to be called from SyncModelCatalog's
// invalidateCatalogCache once that hook is wired; until then the TTL bounds
// staleness after admin catalog changes.
func (s *Server) invalidateModelListCache() {
	for _, includeBuilds := range []bool{false, true} {
		s.readCacheInvalidate(modelEntriesCacheKey(includeBuilds), modelListBodyCacheKey(includeBuilds))
	}
}
