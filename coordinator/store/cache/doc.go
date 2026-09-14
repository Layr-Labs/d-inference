// Package cache decorates persistence with bounded user and model lookup caches.
// Domain invalidation and generation fences protect in-process mutations; the
// configured TTL remains the bound for writes performed by another process.
package cache
