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
// Lifecycle / zeroing policy. Every request-terminal path must drop its entry
// (orphans are otherwise pinned until the chunkKeyCacheMax wholesale reset),
// but only SOME of those paths may zero the key material:
//
//   - forgetAndZero (delete + zero): ONLY from the provider read-loop
//     goroutine that performs this request's chunk decryption —
//     handleComplete, handleInferenceError, and providerReadLoop's disconnect
//     cleanup. On that goroutine no decrypt with the key can be concurrently
//     in flight, so zeroing is safe and scrubs the shared secret from the
//     heap promptly.
//   - forget (delete only, NO zeroing): every CROSS-GOROUTINE terminal —
//     dispatch retry key reassignment, the settlement-grace expiry timer,
//     dispatch-loop cancel/abandon sites. Zeroing there would race a
//     possibly-in-flight box.OpenAfterPrecomputation on the read loop; a
//     corrupted decrypt is reported as an invalid encrypted chunk and
//     triggers MarkUntrusted against an innocent provider. The deleted
//     array is left intact for the GC.
//   - The wholesale cap-reset in sharedKey must NOT zero either: the dropped
//     entries may belong to live streams that will recompute and keep
//     decrypting with the same private key.
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
		// Wholesale reset (abandoned-entry safety net). Deliberately does NOT
		// zero the dropped keys: entries may belong to live streams whose read
		// loops are decrypting with them right now (see the zeroing policy on
		// the type comment).
		c.m = make(map[*[32]byte]chunkKeyEntry)
	}
	c.m[priv] = chunkKeyEntry{peerPub: peerPub, shared: shared}
	c.mu.Unlock()
	return shared, nil
}

// forget drops the cached shared key for a finished request WITHOUT zeroing
// it. Safe to call from ANY goroutine — this is the variant every
// cross-goroutine terminal path must use (dispatch retry reassignment,
// settlement-grace timer, dispatch cancel/abandon): zeroing here could race an
// in-flight decrypt on the provider read loop (see the type comment).
func (c *chunkKeyCache) forget(priv *[32]byte) {
	if priv == nil {
		return
	}
	c.mu.Lock()
	delete(c.m, priv)
	c.mu.Unlock()
}

// forgetAndZero drops the cached shared key for a terminal request AND zeroes
// the 32-byte array so the shared secret does not linger on the heap.
//
// MUST only be called from the goroutine that performs this request's chunk
// decryption — the owning provider's read loop (handleComplete,
// handleInferenceError, providerReadLoop's disconnect cleanup). On any other
// goroutine the zeroing races a possibly-in-flight
// box.OpenAfterPrecomputation and can corrupt a decrypt (which would
// MarkUntrusted an innocent provider); use forget there instead.
func (c *chunkKeyCache) forgetAndZero(priv *[32]byte) {
	if priv == nil {
		return
	}
	c.mu.Lock()
	if e, ok := c.m[priv]; ok {
		if e.shared != nil {
			*e.shared = [32]byte{}
		}
		delete(c.m, priv)
	}
	c.mu.Unlock()
}
