package api

import (
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
