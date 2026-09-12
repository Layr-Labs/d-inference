package api

import "time"

// readCacheGeneration snapshots the invalidation generation before a catalog
// computation reads its inputs. A concurrent admin sync may invalidate the
// result while it is being built; that request can finish with its snapshot,
// but must not repopulate the cache for requests after the sync completes.
func (s *Server) readCacheGeneration() uint64 {
	if s.readCache == nil {
		return 0
	}
	c := s.readCache
	c.mu.RLock()
	defer c.mu.RUnlock()
	return c.generation
}

// readCacheSetEntryIfCurrent publishes a catalog fill only if no invalidation
// has raced it. The comparison and write use the same lock as Invalidate, so
// a successful check cannot race with the eviction it is meant to preserve.
func (s *Server) readCacheSetEntryIfCurrent(key string, entry ttlEntry, ttl time.Duration, generation uint64) {
	if s.readCache == nil {
		return
	}
	c := s.readCache
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.generation != generation {
		return
	}
	entry.expiresAt = time.Now().Add(ttl)
	c.data[key] = entry
}
