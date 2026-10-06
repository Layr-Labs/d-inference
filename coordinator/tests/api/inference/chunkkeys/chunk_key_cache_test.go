package chunkkeys_test

import (
	"crypto/rand"
	"encoding/base64"
	"sync"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/internal/e2e"
	chunkkeys "github.com/eigeninference/d-inference/coordinator/internal/inference/chunkkeys"
	"golang.org/x/crypto/nacl/box"
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
	var c chunkkeys.Cache
	peerPub, _, _ := testPeerKeyB64(t)
	priv := new([32]byte)
	if _, err := rand.Read(priv[:]); err != nil {
		t.Fatalf("rand: %v", err)
	}

	first, err := c.SharedKey(priv, peerPub)
	if err != nil {
		t.Fatalf("sharedKey (miss): %v", err)
	}
	second, err := c.SharedKey(priv, peerPub)
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
	var c chunkkeys.Cache
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

	shared, err := c.SharedKey(&session.PrivateKey, peerPubB64)
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
	var c chunkkeys.Cache
	peerA, _, _ := testPeerKeyB64(t)
	peerB, _, _ := testPeerKeyB64(t)
	priv := new([32]byte)
	if _, err := rand.Read(priv[:]); err != nil {
		t.Fatalf("rand: %v", err)
	}

	forA, err := c.SharedKey(priv, peerA)
	if err != nil {
		t.Fatalf("sharedKey(A): %v", err)
	}
	forB, err := c.SharedKey(priv, peerB)
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
	if again, _ := c.SharedKey(priv, peerB); again != forB {
		t.Error("repeat lookup for the new peer should hit the cache")
	}
	if againA, _ := c.SharedKey(priv, peerA); againA == forA {
		t.Error("lookup for the replaced peer should recompute, not return the old pointer")
	}
}

func TestChunkKeyCacheForgetRemoves(t *testing.T) {
	var c chunkkeys.Cache
	peerPub, _, _ := testPeerKeyB64(t)
	priv := new([32]byte)
	if _, err := rand.Read(priv[:]); err != nil {
		t.Fatalf("rand: %v", err)
	}

	first, err := c.SharedKey(priv, peerPub)
	if err != nil {
		t.Fatalf("sharedKey: %v", err)
	}
	c.Forget(priv)

	stillThere := c.Contains(priv)
	if stillThere {
		t.Fatal("forget should remove the entry")
	}

	recomputed, err := c.SharedKey(priv, peerPub)
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
	var c chunkkeys.Cache
	c.Forget(nil)           // nil priv is a documented no-op
	c.Forget(new([32]byte)) // forget on a zero-value cache (nil map) must not panic
}

func TestChunkKeyCacheInvalidPeerKeyNotCached(t *testing.T) {
	var c chunkkeys.Cache
	priv := new([32]byte)
	if _, err := c.SharedKey(priv, "not-valid-base64!!!"); err == nil {
		t.Fatal("invalid peer key should error")
	}
	if _, err := c.SharedKey(priv, base64.StdEncoding.EncodeToString(make([]byte, 16))); err == nil {
		t.Fatal("wrong-length peer key should error")
	}
	n := c.Len()
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
	var c chunkkeys.Cache
	peerPub, _, _ := testPeerKeyB64(t)

	privs := make([]*[32]byte, chunkkeys.MaxEntries)
	for i := range privs {
		privs[i] = new([32]byte)
		privs[i][0] = byte(i)
		privs[i][1] = byte(i >> 8)
		if _, err := c.SharedKey(privs[i], peerPub); err != nil {
			t.Fatalf("sharedKey fill %d: %v", i, err)
		}
	}
	filled := c.Len()
	if filled != chunkkeys.MaxEntries {
		t.Fatalf("cache size after fill = %d, want %d", filled, chunkkeys.MaxEntries)
	}

	// One past the cap: the map is reset wholesale, then the new entry lands.
	overflowPriv := new([32]byte)
	overflowPriv[2] = 0xAA
	overflowShared, err := c.SharedKey(overflowPriv, peerPub)
	if err != nil {
		t.Fatalf("sharedKey overflow: %v", err)
	}
	afterReset := c.Len()
	if afterReset != 1 {
		t.Errorf("cache size after overflow = %d, want 1 (wholesale reset + new entry)", afterReset)
	}

	// Still functions: the overflow entry hits, and an evicted entry
	// recomputes to the same key value under a new pointer.
	if again, _ := c.SharedKey(overflowPriv, peerPub); again != overflowShared {
		t.Error("overflow entry should be cached after the reset")
	}
	recomputed, err := c.SharedKey(privs[0], peerPub)
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
	var c chunkkeys.Cache
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
			var ref chunkkeys.Cache
			k, err := ref.SharedKey(priv, peer)
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
				k, err := c.SharedKey(priv, peer)
				if err != nil {
					t.Errorf("worker %d: sharedKey: %v", w, err)
					return
				}
				if want := expected[comboKey{priv, peer}]; *k != want {
					t.Errorf("worker %d: shared key value mismatch for (priv[0]=%d, peer=%s...)",
						w, priv[0], peer[:8])
					return
				}
				if _, err := c.SharedKey(ownPriv, peerA); err != nil {
					t.Errorf("worker %d: own sharedKey: %v", w, err)
					return
				}
				if i%7 == 0 {
					c.Forget(priv)
				}
				if i%11 == 0 {
					c.Forget(ownPriv)
				}
			}
		}(w)
	}
	wg.Wait()
}
