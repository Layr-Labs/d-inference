package e2e

import (
	"crypto/rand"
	"encoding/base64"
	"errors"
	"testing"

	"golang.org/x/crypto/nacl/box"
)

// A real, freshly generated 12-word BIP39 mnemonic. Test-only — not used
// anywhere in production. Generated for these tests via `bx mnemonic new`.
const testMnemonic = "praise warfare warrior rebuild raven garlic kite blast crew impulse pencil hidden"

func TestDeriveCoordinatorKey_Golden(t *testing.T) {
	const (
		wantKID       = "db174b1a34ab9e26"
		wantPublicKey = "iESmUb2Yp6z3cECwkIJsh0S7rzmWEOuiCJpXdw892BE="
	)
	key, err := DeriveCoordinatorKey(testMnemonic)
	if err != nil {
		t.Fatalf("derive: %v", err)
	}
	if key.KID != wantKID {
		t.Fatalf("kid = %q, want %q", key.KID, wantKID)
	}
	if got := base64.StdEncoding.EncodeToString(key.PublicKey[:]); got != wantPublicKey {
		t.Fatalf("public key = %q, want %q", got, wantPublicKey)
	}
}

func TestDeriveCoordinatorKey_DistinctMnemonics(t *testing.T) {
	// Confirm two different mnemonics derive to unrelated keys (no fixed key
	// material leaking across instances).
	a, err := DeriveCoordinatorKey(testMnemonic)
	if err != nil {
		t.Fatal(err)
	}
	b, err := DeriveCoordinatorKey("legal winner thank year wave sausage worth useful legal winner thank yellow")
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
	_, err := DeriveCoordinatorKey("")
	if !errors.Is(err, ErrNoMnemonic) {
		t.Fatalf("want ErrNoMnemonic, got %v", err)
	}
}

func TestDeriveCoordinatorKey_BadWordCount(t *testing.T) {
	_, err := DeriveCoordinatorKey("only three words here")
	if err == nil {
		t.Fatal("want error for bad mnemonic word count")
	}
}

// TestRoundTrip exercises the full NaCl Box round trip the way a sender would
// use it: derive coord key, generate ephemeral keys, seal request with sender
// privkey + coord pubkey, decrypt with coord privkey + sender pubkey.
func TestCoordinatorKey_RoundTrip(t *testing.T) {
	coord, err := DeriveCoordinatorKey(testMnemonic)
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

}
