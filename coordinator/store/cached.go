package store

import (
	storecache "github.com/eigeninference/d-inference/coordinator/store/cache"
)

type (
	CachedStore   = storecache.Store
	CacheConfig   = storecache.CacheConfig
	CacheCounters = storecache.CacheCounters
	CacheStats    = storecache.CacheStats
)

func DefaultCacheConfig() CacheConfig {
	return storecache.DefaultCacheConfig()
}

func NewCached(inner Store, cfg CacheConfig) *CachedStore {
	return storecache.New(inner, cfg)
}
