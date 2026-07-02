package api

import (
	"crypto/rand"
	"encoding/base64"
	"sync"
	"testing"

	"golang.org/x/crypto/nacl/box"

	"github.com/eigeninference/d-inference/coordinator/internal/e2e"
)

// testPeerKeyB64 generates a fresh X25519 keypair and returns the base64
// public key plus the raw pair, for driving chunkKeyCache directly.
func testPeerKeyB64(t *testing.T) (string, *[32]byte, *[32]byte) {
	t.Helper()
	pub, priv, err := box.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatalf("generate peer keys: %v", err)
	}
	return base64.StdEncoding.EncodeToString(pub[:]), pub, priv
}

func TestChunkKeyCacheHitReturnsIdenticalPointer(t *testing.T) {
	var c chunkKeyCache
	peerPub, _, _ := testPeerKeyB64(t)
	priv := new([32]byte)
	if _, err := rand.Read(priv[:]); err != nil {
		t.Fatalf("rand: %v", err)
	}

	first, err := c.sharedKey(priv, peerPub)
	if err != nil {
		t.Fatalf("sharedKey (miss): %v", err)
	}
	second, err := c.sharedKey(priv, peerPub)
	if err != nil {
		t.Fatalf("sharedKey (hit): %v", err)
	}
	if first != second {
		t.Error("cache hit should return the identical *[32]byte pointer")
	}
}

// TestChunkKeyCacheSharedKeyDecrypts verifies the cached key is the real NaCl
// box shared key: a payload encrypted by the peer must open with it, matching
// the e2e.Decrypt reference path.
func TestChunkKeyCacheSharedKeyDecrypts(t *testing.T) {
	var c chunkKeyCache
	peerPubB64, peerPub, peerPriv := testPeerKeyB64(t)

	session, err := e2e.GenerateSessionKeys()
	if err != nil {
		t.Fatalf("GenerateSessionKeys: %v", err)
	}
	plaintext := []byte(`data: {"choices":[{"delta":{"content":"tok"}}]}`)
	payload, err := e2e.Encrypt(plaintext, session.PublicKey, &e2e.SessionKeys{
		PublicKey:  *peerPub,
		PrivateKey: *peerPriv,
	})
	if err != nil {
		t.Fatalf("Encrypt: %v", err)
	}

	shared, err := c.sharedKey(&session.PrivateKey, peerPubB64)
	if err != nil {
		t.Fatalf("sharedKey: %v", err)
	}
	got, err := e2e.DecryptWithSharedKey(payload, shared)
	if err != nil {
		t.Fatalf("DecryptWithSharedKey: %v", err)
	}
	if string(got) != string(plaintext) {
		t.Errorf("decrypted = %q, want %q", got, plaintext)
	}
}

func TestChunkKeyCachePeerPubChangeRecomputes(t *testing.T) {
	var c chunkKeyCache
	peerA, _, _ := testPeerKeyB64(t)
	peerB, _, _ := testPeerKeyB64(t)
	priv := new([32]byte)
	if _, err := rand.Read(priv[:]); err != nil {
		t.Fatalf("rand: %v", err)
	}

	forA, err := c.sharedKey(priv, peerA)
	if err != nil {
		t.Fatalf("sharedKey(A): %v", err)
	}
	forB, err := c.sharedKey(priv, peerB)
	if err != nil {
		t.Fatalf("sharedKey(B): %v", err)
	}
	if forA == forB {
		t.Error("a different peer key must not reuse the stale cached shared key")
	}
	if *forA == *forB {
		t.Error("shared keys for different peers should differ in value")
	}

	// The entry now belongs to peerB: a repeat for B hits the cache, and a
	// repeat for A recomputes (single-entry-per-priv semantics).
	if again, _ := c.sharedKey(priv, peerB); again != forB {
		t.Error("repeat lookup for the new peer should hit the cache")
	}
	if againA, _ := c.sharedKey(priv, peerA); againA == forA {
		t.Error("lookup for the replaced peer should recompute, not return the old pointer")
	}
}

func TestChunkKeyCacheForgetRemoves(t *testing.T) {
	var c chunkKeyCache
	peerPub, _, _ := testPeerKeyB64(t)
	priv := new([32]byte)
	if _, err := rand.Read(priv[:]); err != nil {
		t.Fatalf("rand: %v", err)
	}

	first, err := c.sharedKey(priv, peerPub)
	if err != nil {
		t.Fatalf("sharedKey: %v", err)
	}
	c.forget(priv)

	c.mu.Lock()
	_, stillThere := c.m[priv]
	c.mu.Unlock()
	if stillThere {
		t.Fatal("forget should remove the entry")
	}

	recomputed, err := c.sharedKey(priv, peerPub)
	if err != nil {
		t.Fatalf("sharedKey after forget: %v", err)
	}
	if recomputed == first {
		t.Error("post-forget lookup should be a fresh computation (new pointer)")
	}
	if *recomputed != *first {
		t.Error("recomputed shared key should have the same value for the same inputs")
	}
}

func TestChunkKeyCacheForgetNilAndEmptyAreSafe(t *testing.T) {
	var c chunkKeyCache
	c.forget(nil)                  // nil priv is a documented no-op
	c.forget(new([32]byte))        // forget on a zero-value cache (nil map) must not panic
	c.forgetAndZero(nil)           // same no-op guarantees for the zeroing variant
	c.forgetAndZero(new([32]byte)) // absent entry on a nil map must not panic
}

// forgetAndZero removes the entry AND scrubs the 32-byte shared key so the
// secret does not linger on the heap (read-loop terminal paths only — see the
// zeroing policy on chunkKeyCache).
func TestChunkKeyCacheForgetAndZeroRemovesAndZeroes(t *testing.T) {
	var c chunkKeyCache
	peerPub, _, _ := testPeerKeyB64(t)
	priv := new([32]byte)
	if _, err := rand.Read(priv[:]); err != nil {
		t.Fatalf("rand: %v", err)
	}

	shared, err := c.sharedKey(priv, peerPub)
	if err != nil {
		t.Fatalf("sharedKey: %v", err)
	}
	if *shared == ([32]byte{}) {
		t.Fatal("sanity: freshly computed shared key should not be all-zero")
	}

	c.forgetAndZero(priv)

	c.mu.Lock()
	_, stillThere := c.m[priv]
	c.mu.Unlock()
	if stillThere {
		t.Fatal("forgetAndZero should remove the entry")
	}
	if *shared != ([32]byte{}) {
		t.Error("forgetAndZero should zero the shared key array")
	}

	// Cache still functions: the same inputs recompute the same value under a
	// fresh array (the zeroed one is never reused).
	recomputed, err := c.sharedKey(priv, peerPub)
	if err != nil {
		t.Fatalf("sharedKey after forgetAndZero: %v", err)
	}
	if recomputed == shared {
		t.Error("recompute after forgetAndZero must allocate a new array, not reuse the zeroed one")
	}
	if *recomputed == ([32]byte{}) {
		t.Error("recomputed shared key should be the real value, not zeroes")
	}
}

// The plain forget must NOT zero — cross-goroutine callers rely on the array
// staying intact for a possibly-in-flight decrypt on the provider read loop.
func TestChunkKeyCacheForgetDoesNotZero(t *testing.T) {
	var c chunkKeyCache
	peerPub, _, _ := testPeerKeyB64(t)
	priv := new([32]byte)
	if _, err := rand.Read(priv[:]); err != nil {
		t.Fatalf("rand: %v", err)
	}

	shared, err := c.sharedKey(priv, peerPub)
	if err != nil {
		t.Fatalf("sharedKey: %v", err)
	}
	want := *shared
	c.forget(priv)
	if *shared != want {
		t.Error("forget must leave the shared key array intact (no zeroing cross-goroutine)")
	}
}

// A forgotten priv must never be re-cached: forget tombstones it, so a late
// straggler decrypt — or one whose unlocked X25519 compute window in sharedKey
// raced the forget — hands back a working key WITHOUT re-inserting an entry
// that no terminal path remains to clean up.
func TestChunkKeyCacheForgetPreventsRecache(t *testing.T) {
	var c chunkKeyCache
	peerPub, _, _ := testPeerKeyB64(t)
	priv := new([32]byte)
	if _, err := rand.Read(priv[:]); err != nil {
		t.Fatalf("rand: %v", err)
	}

	first, err := c.sharedKey(priv, peerPub)
	if err != nil {
		t.Fatalf("sharedKey: %v", err)
	}
	c.forget(priv)

	late, err := c.sharedKey(priv, peerPub) // late straggler decrypt
	if err != nil {
		t.Fatalf("sharedKey after forget: %v", err)
	}
	if *late != *first {
		t.Error("straggler decrypt must still get the correct key value")
	}
	c.mu.Lock()
	_, cached := c.m[priv]
	c.mu.Unlock()
	if cached {
		t.Error("a forgotten priv must not be re-cached by a late sharedKey call")
	}
}

// The tombstone also protects the cancel-before-first-chunk case: a forget on
// a priv that never entered the cache must still block a later first-chunk
// decrypt from caching. Same guarantee for the zeroing variant.
func TestChunkKeyCacheForgetBeforeFirstUsePreventsCache(t *testing.T) {
	for name, forget := range map[string]func(*chunkKeyCache, *[32]byte){
		"forget":        (*chunkKeyCache).forget,
		"forgetAndZero": (*chunkKeyCache).forgetAndZero,
	} {
		var c chunkKeyCache
		peerPub, _, _ := testPeerKeyB64(t)
		priv := new([32]byte)
		if _, err := rand.Read(priv[:]); err != nil {
			t.Fatalf("rand: %v", err)
		}

		forget(&c, priv) // request cancelled before any chunk arrived

		if _, err := c.sharedKey(priv, peerPub); err != nil {
			t.Fatalf("%s: sharedKey after early forget: %v", name, err)
		}
		c.mu.Lock()
		_, cached := c.m[priv]
		c.mu.Unlock()
		if cached {
			t.Errorf("%s: a late first chunk must not cache a tombstoned priv", name)
		}
	}
}

// The tombstone set is bounded: once it hits chunkKeyDeadMax it is dropped
// wholesale, after which an old tombstoned priv may cache again (the race
// window a tombstone protects is milliseconds; this is the documented
// safety-net trade-off).
func TestChunkKeyCacheDeadTombstoneCapResets(t *testing.T) {
	var c chunkKeyCache
	peerPub, _, _ := testPeerKeyB64(t)

	first := new([32]byte)
	first[0] = 0xF1
	c.forget(first)
	// chunkKeyDeadMax more tombstones guarantee at least one wholesale reset
	// after first's tombstone landed.
	for i := 0; i < chunkKeyDeadMax; i++ {
		c.forget(new([32]byte))
	}
	c.mu.Lock()
	deadLen := len(c.dead)
	c.mu.Unlock()
	if deadLen > chunkKeyDeadMax {
		t.Fatalf("tombstone set grew past the cap: %d > %d", deadLen, chunkKeyDeadMax)
	}

	if _, err := c.sharedKey(first, peerPub); err != nil {
		t.Fatalf("sharedKey after tombstone reset: %v", err)
	}
	c.mu.Lock()
	_, cached := c.m[first]
	c.mu.Unlock()
	if !cached {
		t.Error("after the tombstone wholesale reset the priv should cache again")
	}
}

// forgetPeer sweeps every entry cached under one peer public key — the
// provider-disconnect catch-all — without zeroing and without tombstoning
// (same-keypair replacement sessions must be able to keep caching).
func TestChunkKeyCacheForgetPeerSweepsWithoutZeroingOrTombstoning(t *testing.T) {
	var c chunkKeyCache
	peerA, _, _ := testPeerKeyB64(t)
	peerB, _, _ := testPeerKeyB64(t)

	privA1, privA2, privB := &[32]byte{1}, &[32]byte{2}, &[32]byte{3}
	sharedA1, err := c.sharedKey(privA1, peerA)
	if err != nil {
		t.Fatalf("sharedKey A1: %v", err)
	}
	wantA1 := *sharedA1
	if _, err := c.sharedKey(privA2, peerA); err != nil {
		t.Fatalf("sharedKey A2: %v", err)
	}
	sharedB, err := c.sharedKey(privB, peerB)
	if err != nil {
		t.Fatalf("sharedKey B: %v", err)
	}

	c.forgetPeer(peerA)

	c.mu.Lock()
	_, a1 := c.m[privA1]
	_, a2 := c.m[privA2]
	_, b := c.m[privB]
	c.mu.Unlock()
	if a1 || a2 {
		t.Error("forgetPeer should sweep every entry for the matching peer")
	}
	if !b {
		t.Error("forgetPeer must not touch entries for other peers")
	}
	if *sharedA1 != wantA1 {
		t.Error("forgetPeer must NOT zero swept keys (replacement session may be decrypting)")
	}
	if again, _ := c.sharedKey(privB, peerB); again != sharedB {
		t.Error("unswept entry should still hit the cache")
	}

	// NOT tombstoned: a replacement session reusing the keypair re-caches.
	if _, err := c.sharedKey(privA1, peerA); err != nil {
		t.Fatalf("sharedKey re-cache after forgetPeer: %v", err)
	}
	c.mu.Lock()
	_, recached := c.m[privA1]
	c.mu.Unlock()
	if !recached {
		t.Error("forgetPeer must not tombstone: a live replacement session must re-cache")
	}

	c.forgetPeer("") // empty peer is a documented no-op
	var empty chunkKeyCache
	empty.forgetPeer(peerA) // nil map must not panic
}

func TestChunkKeyCacheInvalidPeerKeyNotCached(t *testing.T) {
	var c chunkKeyCache
	priv := new([32]byte)
	if _, err := c.sharedKey(priv, "not-valid-base64!!!"); err == nil {
		t.Fatal("invalid peer key should error")
	}
	if _, err := c.sharedKey(priv, base64.StdEncoding.EncodeToString(make([]byte, 16))); err == nil {
		t.Fatal("wrong-length peer key should error")
	}
	c.mu.Lock()
	n := len(c.m)
	c.mu.Unlock()
	if n != 0 {
		t.Errorf("failed lookups must not populate the cache, have %d entries", n)
	}
}

// TestChunkKeyCacheCapResets fills the cache past chunkKeyCacheMax and checks
// the wholesale-reset safety net: the map is dropped, stays bounded, and the
// cache keeps functioning afterwards.
func TestChunkKeyCacheCapResets(t *testing.T) {
	if testing.Short() {
		t.Skip("fills chunkKeyCacheMax entries (~0.5s of X25519)")
	}
	var c chunkKeyCache
	peerPub, _, _ := testPeerKeyB64(t)

	privs := make([]*[32]byte, chunkKeyCacheMax)
	for i := range privs {
		privs[i] = new([32]byte)
		privs[i][0] = byte(i)
		privs[i][1] = byte(i >> 8)
		if _, err := c.sharedKey(privs[i], peerPub); err != nil {
			t.Fatalf("sharedKey fill %d: %v", i, err)
		}
	}
	c.mu.Lock()
	filled := len(c.m)
	c.mu.Unlock()
	if filled != chunkKeyCacheMax {
		t.Fatalf("cache size after fill = %d, want %d", filled, chunkKeyCacheMax)
	}

	// One past the cap: the map is reset wholesale, then the new entry lands.
	overflowPriv := new([32]byte)
	overflowPriv[2] = 0xAA
	overflowShared, err := c.sharedKey(overflowPriv, peerPub)
	if err != nil {
		t.Fatalf("sharedKey overflow: %v", err)
	}
	c.mu.Lock()
	afterReset := len(c.m)
	c.mu.Unlock()
	if afterReset != 1 {
		t.Errorf("cache size after overflow = %d, want 1 (wholesale reset + new entry)", afterReset)
	}

	// Still functions: the overflow entry hits, and an evicted entry
	// recomputes to the same key value under a new pointer.
	if again, _ := c.sharedKey(overflowPriv, peerPub); again != overflowShared {
		t.Error("overflow entry should be cached after the reset")
	}
	recomputed, err := c.sharedKey(privs[0], peerPub)
	if err != nil {
		t.Fatalf("sharedKey recompute after reset: %v", err)
	}
	if recomputed == nil {
		t.Fatal("recomputed shared key is nil")
	}
}

// TestChunkKeyCacheConcurrentAccess hammers sharedKey/forget from parallel
// goroutines. Run with -race. Pointer identity is deliberately NOT asserted
// across goroutines: two concurrent first-uses may both compute (the lock is
// dropped during the X25519), which is benign — the values must still match.
func TestChunkKeyCacheConcurrentAccess(t *testing.T) {
	var c chunkKeyCache
	peerA, _, _ := testPeerKeyB64(t)
	peerB, _, _ := testPeerKeyB64(t)

	const workers = 16
	const iters = 200

	// A mix of shared and per-goroutine privs.
	sharedPrivs := make([]*[32]byte, 4)
	for i := range sharedPrivs {
		sharedPrivs[i] = new([32]byte)
		sharedPrivs[i][0] = byte(i)
	}

	// The shared key is a deterministic function of (priv, peer): precompute
	// the expected value for every combination so workers can assert exact
	// values no matter how lookups interleave with forgets and peer flips.
	type comboKey struct {
		priv *[32]byte
		peer string
	}
	expected := make(map[comboKey][32]byte)
	for _, priv := range sharedPrivs {
		for _, peer := range []string{peerA, peerB} {
			var ref chunkKeyCache
			k, err := ref.sharedKey(priv, peer)
			if err != nil {
				t.Fatalf("precompute expected key: %v", err)
			}
			expected[comboKey{priv, peer}] = *k
		}
	}

	var wg sync.WaitGroup
	for w := 0; w < workers; w++ {
		wg.Add(1)
		go func(w int) {
			defer wg.Done()
			ownPriv := new([32]byte)
			ownPriv[0] = 0x80
			ownPriv[1] = byte(w)
			for i := 0; i < iters; i++ {
				priv := sharedPrivs[i%len(sharedPrivs)]
				peer := peerA
				if i%3 == 0 {
					peer = peerB
				}
				k, err := c.sharedKey(priv, peer)
				if err != nil {
					t.Errorf("worker %d: sharedKey: %v", w, err)
					return
				}
				if want := expected[comboKey{priv, peer}]; *k != want {
					t.Errorf("worker %d: shared key value mismatch for (priv[0]=%d, peer=%s...)",
						w, priv[0], peer[:8])
					return
				}
				if _, err := c.sharedKey(ownPriv, peerA); err != nil {
					t.Errorf("worker %d: own sharedKey: %v", w, err)
					return
				}
				if i%7 == 0 {
					c.forget(priv)
				}
				if i%11 == 0 {
					c.forget(ownPriv)
				}
			}
		}(w)
	}
	wg.Wait()
}
