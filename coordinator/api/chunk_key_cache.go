package api

import (
	"sync"

	"github.com/eigeninference/d-inference/coordinator/internal/e2e"
)

// chunkKeyCacheMax bounds the cache. Entries are removed proactively when a
// request completes or errors; the cap is a safety net for abandoned requests
// (provider disconnect mid-stream). At 8192 entries the cache is ~1 MiB. When
// full it is dropped wholesale — it is a pure cache, so a reset only costs one
// X25519 recompute per live stream.
const chunkKeyCacheMax = 8192

// chunkKeyCache memoizes the NaCl box shared key per inference request so the
// per-token chunk decrypt path performs only the symmetric open, not a fresh
// X25519 scalar multiplication per chunk (~40-60µs each, serialized on the
// provider's single read goroutine).
//
// Keyed by the request's SessionPrivKey pointer, which is unique and stable
// per PendingRequest. The provider public key is stored alongside so a peer
// key change (paranoia: reconnect races) invalidates the entry instead of
// decrypting with a stale shared key.
//
// The zero value is ready to use.
type chunkKeyCache struct {
	mu sync.Mutex
	m  map[*[32]byte]chunkKeyEntry
}

type chunkKeyEntry struct {
	peerPub string
	shared  *[32]byte
}

// sharedKey returns the memoized shared key for (priv, peerPub), computing and
// caching it on first use. peerPub is the provider's base64 X25519 public key,
// already validated by the caller against the chunk's ephemeral key.
func (c *chunkKeyCache) sharedKey(priv *[32]byte, peerPub string) (*[32]byte, error) {
	c.mu.Lock()
	if e, ok := c.m[priv]; ok && e.peerPub == peerPub {
		c.mu.Unlock()
		return e.shared, nil
	}
	c.mu.Unlock()

	pub, err := e2e.ParsePublicKey(peerPub)
	if err != nil {
		return nil, err
	}
	shared := e2e.PrecomputeSharedKey(&pub, priv)

	c.mu.Lock()
	if c.m == nil || len(c.m) >= chunkKeyCacheMax {
		c.m = make(map[*[32]byte]chunkKeyEntry)
	}
	c.m[priv] = chunkKeyEntry{peerPub: peerPub, shared: shared}
	c.mu.Unlock()
	return shared, nil
}

// forget drops the cached shared key for a finished request.
func (c *chunkKeyCache) forget(priv *[32]byte) {
	if priv == nil {
		return
	}
	c.mu.Lock()
	delete(c.m, priv)
	c.mu.Unlock()
}
