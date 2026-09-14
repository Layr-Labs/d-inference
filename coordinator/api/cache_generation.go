package api

import "time"

func (s *Server) readCacheGeneration() uint64 {
	if s.readCache == nil {
		return 0
	}
	return s.readCache.Generation()
}

func (s *Server) readCacheSetIfCurrent(key string, body []byte, ttl time.Duration, generation uint64) {
	if s.readCache != nil {
		s.readCache.SetIfCurrent(key, body, ttl, generation)
	}
}

func (s *Server) readCacheSetValueIfCurrent(key string, value any, ttl time.Duration, generation uint64) {
	if s.readCache != nil {
		s.readCache.SetValueIfCurrent(key, value, ttl, generation)
	}
}
