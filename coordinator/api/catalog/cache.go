package catalog

import "time"

// Cache adapters retain the API's optional-cache behavior.
func (s *Controller) readCacheGet(key string) ([]byte, bool) {
	if s.readCache == nil {
		return nil, false
	}
	return s.readCache.Get(key)
}

func (s *Controller) readCacheGetValue(key string) (any, bool) {
	if s.readCache == nil {
		return nil, false
	}
	return s.readCache.GetValue(key)
}

func (s *Controller) readCacheGeneration() uint64 {
	if s.readCache == nil {
		return 0
	}
	return s.readCache.Generation()
}

func (s *Controller) readCacheSetIfCurrent(key string, body []byte, ttl time.Duration, generation uint64) {
	if s.readCache != nil {
		s.readCache.SetIfCurrent(key, body, ttl, generation)
	}
}

func (s *Controller) readCacheSetValueIfCurrent(key string, value any, ttl time.Duration, generation uint64) {
	if s.readCache != nil {
		s.readCache.SetValueIfCurrent(key, value, ttl, generation)
	}
}
