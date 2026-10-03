package access

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// apiKeyCacheEntry stores the authenticated key record for a single raw API
// key. Cached to skip DB round trips on repeat requests with the same key. A
// nil key means the token is known-invalid (negative cache).
type apiKeyCacheEntry struct {
	key      *store.APIKey
	cachedAt time.Time
	gen      uint64 // cache generation this entry was stored under
}

const (
	apiKeyCacheTTL     = 60 * time.Second
	apiKeyCacheMaxSize = 1000
)

// lookupAPIKeyCache returns a cached AuthenticateKey result if present and
// not expired. Returns false on miss or expiry.
func (s *Owner) lookupAPIKeyCache(token string) (apiKeyCacheEntry, bool) {
	s.apiKeyCacheMu.RLock()
	entry, ok := s.apiKeyCache[token]
	gen := s.apiKeyCacheGen
	s.apiKeyCacheMu.RUnlock()
	// Miss on absence, TTL expiry, or a stale generation (a key mutation has
	// occurred since the entry was cached).
	if !ok || entry.gen != gen || time.Since(entry.cachedAt) > apiKeyCacheTTL {
		return apiKeyCacheEntry{}, false
	}
	return entry, true
}

// storeAPIKeyCache inserts an auth result into the cache, stamped with the
// current generation. If the cache is at capacity, the oldest entry is evicted.
func (s *Owner) storeAPIKeyCache(token string, entry apiKeyCacheEntry) {
	s.apiKeyCacheMu.Lock()
	defer s.apiKeyCacheMu.Unlock()
	entry.gen = s.apiKeyCacheGen
	if len(s.apiKeyCache) >= apiKeyCacheMaxSize {
		var oldest string
		var oldestTime time.Time
		for k, v := range s.apiKeyCache {
			if oldest == "" || v.cachedAt.Before(oldestTime) {
				oldest = k
				oldestTime = v.cachedAt
			}
		}
		delete(s.apiKeyCache, oldest)
	}
	s.apiKeyCache[token] = entry
}

// InvalidateAPIKeyCache removes a single key from the API key cache. Called
// when a key is revoked so stale positive results don't grant access.
func (s *Owner) InvalidateAPIKeyCache(token string) {
	s.apiKeyCacheMu.Lock()
	delete(s.apiKeyCache, token)
	s.apiKeyCacheMu.Unlock()
}

// InvalidateAllAPIKeyCache atomically invalidates every cached auth result by
// bumping the cache generation (entries cached under an older generation are
// ignored). Called BEFORE and AFTER a by-ID key mutation (update/revoke/rotate)
// where we don't hold the raw token: the pre-bump drops any pre-existing entry,
// and the post-bump drops any entry a concurrent request re-cached from
// pre-commit state during the mutation — closing the read-stale race.
func (s *Owner) InvalidateAllAPIKeyCache() {
	s.apiKeyCacheMu.Lock()
	s.apiKeyCacheGen++
	s.apiKeyCache = make(map[string]apiKeyCacheEntry)
	s.apiKeyCacheMu.Unlock()
}
