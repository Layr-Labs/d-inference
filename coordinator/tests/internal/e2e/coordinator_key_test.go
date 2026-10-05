package e2e_test

import (
	"crypto/rand"
	"encoding/base64"
	"errors"
	"testing"

	production "github.com/eigeninference/d-inference/coordinator/internal/e2e"
	"golang.org/x/crypto/nacl/box"
)

// A real, freshly generated 12-word BIP39 mnemonic. Test-only — not used
// anywhere in production. Generated for these tests via `bx mnemonic new`.
const testMnemonic = "praise warfare warrior rebuild raven garlic kite blast crew impulse pencil hidden"

func TestDeriveCoordinatorKey_Deterministic(t *testing.T) {
	a, err := production.DeriveCoordinatorKey(testMnemonic)
	if err != nil {
		t.Fatalf("derive a: %v", err)
	}
	b, err := production.DeriveCoordinatorKey(testMnemonic)
	if err != nil {
		t.Fatalf("derive b: %v", err)
	}
	if a.PrivateKey != b.PrivateKey {
		t.Fatal("derivation is not deterministic — same mnemonic produced different private keys")
	}
	if a.PublicKey != b.PublicKey {
		t.Fatal("derivation is not deterministic — same mnemonic produced different public keys")
	}
	if a.KID != b.KID {
		t.Fatalf("kid mismatch: %s != %s", a.KID, b.KID)
	}
	if len(a.KID) != 16 {
		t.Fatalf("kid expected 16 hex chars, got %d", len(a.KID))
	}
}

func TestDeriveCoordinatorKey_DistinctMnemonics(t *testing.T) {
	// Confirm two different mnemonics derive to unrelated keys (no fixed key
	// material leaking across instances).
	a, err := production.DeriveCoordinatorKey(testMnemonic)
	if err != nil {
		t.Fatal(err)
	}
	b, err := production.DeriveCoordinatorKey("legal winner thank year wave sausage worth useful legal winner thank yellow")
	if err != nil {
		t.Fatal(err)
	}
	if a.PrivateKey == b.PrivateKey {
		t.Fatal("different mnemonics produced the same private key")
	}
	if a.KID == b.KID {
		t.Fatal("different mnemonics produced the same kid")
	}
}

func TestDeriveCoordinatorKey_Empty(t *testing.T) {
	_, err := production.DeriveCoordinatorKey("")
	if !errors.Is(err, production.ErrNoMnemonic) {
		t.Fatalf("want ErrNoMnemonic, got %v", err)
	}
}

func TestDeriveCoordinatorKey_BadWordCount(t *testing.T) {
	_, err := production.DeriveCoordinatorKey("only three words here")
	if err == nil {
		t.Fatal("want error for bad mnemonic word count")
	}
}

// TestRoundTrip exercises the full NaCl Box round trip the way a sender would
// use it: derive coord key, generate ephemeral keys, seal request with sender
// privkey + coord pubkey, decrypt with coord privkey + sender pubkey.
func TestCoordinatorKey_RoundTrip(t *testing.T) {
	coord, err := production.DeriveCoordinatorKey(testMnemonic)
	if err != nil {
		t.Fatal(err)
	}

	ephemPub, ephemPriv, err := box.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}

	plaintext := []byte(`{"model":"qwen3-32b","messages":[{"role":"user","content":"hi"}]}`)
	var nonce [24]byte
	if _, err := rand.Read(nonce[:]); err != nil {
		t.Fatal(err)
	}
	sealed := box.Seal(nonce[:], plaintext, &nonce, &coord.PublicKey, ephemPriv)

	// Coord-side decrypt
	var n2 [24]byte
	copy(n2[:], sealed[:24])
	got, ok := box.Open(nil, sealed[24:], &n2, ephemPub, &coord.PrivateKey)
	if !ok {
		t.Fatal("coord-side decrypt failed")
	}
	if string(got) != string(plaintext) {
		t.Fatalf("plaintext mismatch:\n got: %s\nwant: %s", got, plaintext)
	}

	// And confirm the kid doesn't change across runs (regression: rotation
	// must be intentional).
	want := coord.KID
	again, _ := production.DeriveCoordinatorKey(testMnemonic)
	if again.KID != want {
		t.Fatalf("kid drifted: %s != %s", again.KID, want)
	}

	// Sanity: pubkey is exactly 32 bytes when decoded.
	enc := base64.StdEncoding.EncodeToString(coord.PublicKey[:])
	dec, err := base64.StdEncoding.DecodeString(enc)
	if err != nil || len(dec) != 32 {
		t.Fatalf("pubkey serialization broken: %v len=%d", err, len(dec))
	}
}
