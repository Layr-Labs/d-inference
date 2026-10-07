package catalog

// Read-cache wiring for the consumer model catalog endpoints (GET /v1/models,
// GET /v1/models/{id}). The shared, caller-independent computation —
// listModelEntries: the registry snapshot plus the alias/registry DB lookups —
// is memoized for a short TTL. Anything per-caller (self-route owned-model
// views, key allow-lists) is applied by the handlers after the shared step and
// is never cached.

import (
	"strconv"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/httpx"
	"github.com/eigeninference/d-inference/coordinator/api/types"
)

// modelListCacheTTL bounds staleness of the public model list. It carries live
// capacity fields (routable/warm providers, can_accept), so it matches the 2s
// window GET /v1/models/capacity already uses. Catalog sync invalidates these
// entries and prevents an older in-flight fill from publishing afterward.
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
func (s *Owner) cachedModelEntries(includeBuilds bool) ([]types.ModelEntry, error) {
	key := modelEntriesCacheKey(includeBuilds)
	if v, ok := s.readCache.GetValue(key); ok {
		if entries, ok := v.([]types.ModelEntry); ok {
			return entries, nil
		}
	}
	generation := s.readCache.Generation()
	entries, err := s.listModelEntries(includeBuilds)
	if err != nil {
		return nil, err
	}
	s.readCache.SetValueIfCurrent(key, entries, modelListCacheTTL, generation)
	return entries, nil
}

// cachedModelListBody returns the pre-serialized GET /v1/models response for
// the public catalog, byte-identical to what writeJSON would produce. A body
// miss recomputes the entries (refreshing the entries memo alongside) rather
// than reusing an almost-expired memo, so the body is never older than
// modelListCacheTTL.
func (s *Owner) cachedModelListBody(includeBuilds bool) ([]byte, error) {
	key := modelListBodyCacheKey(includeBuilds)
	if body, ok := s.readCache.Get(key); ok {
		return body, nil
	}
	generation := s.readCache.Generation()
	entries, err := s.listModelEntries(includeBuilds)
	if err != nil {
		return nil, err
	}
	body, err := httpx.EncodeCachedJSON(types.ModelListResponse{Object: "list", Data: entries})
	if err != nil {
		return nil, err
	}
	s.readCache.SetValueIfCurrent(modelEntriesCacheKey(includeBuilds), entries, modelListCacheTTL, generation)
	s.readCache.SetIfCurrent(key, body, modelListCacheTTL, generation)
	return body, nil
}
