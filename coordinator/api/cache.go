package api

import (
	"context"
	"net/http"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/httpresponse"
	"github.com/eigeninference/d-inference/coordinator/api/readcache"
)

// Response cache storage and synchronization live in readcache.
type ttlCache = readcache.Cache

func newTTLCache() *ttlCache { return readcache.New() }

// writeCachedJSON serves the exact pre-encoded response body.
func writeCachedJSON(w http.ResponseWriter, body []byte) {
	httpresponse.WriteCachedJSON(w, body)
}

func encodeCachedJSON(v any) ([]byte, error) { return httpresponse.EncodeCachedJSON(v) }

// Nil-safe readCache accessors: handlers reached through a bare Server
// literal (some tests) have no cache and simply recompute every time.

func (s *Server) readCacheGet(key string) ([]byte, bool) {
	if s.readCache == nil {
		return nil, false
	}
	return s.readCache.Get(key)
}

func (s *Server) readCacheSet(key string, body []byte, ttl time.Duration) {
	if s.readCache != nil {
		s.readCache.Set(key, body, ttl)
	}
}

// readCacheJanitorInterval is how often expired readCache entries are reclaimed.
// Get already skips expired entries, so this only frees memory — but without it
// high-cardinality keys (e.g. the per-account "account-earnings:" entries) are
// written and never re-read, so they linger forever and the cache grows unbounded.
const readCacheJanitorInterval = time.Minute

// StartReadCacheJanitor periodically purges expired entries from the read cache
// so it can't grow unbounded. Call as a goroutine; stops when ctx is cancelled.
func (s *Server) StartReadCacheJanitor(ctx context.Context) {
	s.runReadCacheJanitor(ctx, readCacheJanitorInterval)
}

// runReadCacheJanitor is StartReadCacheJanitor with an injectable interval (tests).
func (s *Server) runReadCacheJanitor(ctx context.Context, interval time.Duration) {
	if s.readCache == nil {
		return
	}
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			s.readCache.PurgeExpired()
		}
	}
}
