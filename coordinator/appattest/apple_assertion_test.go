package appattest

import (
	"crypto/ecdsa"
	"crypto/rand"
	"encoding/json"
	"os"
	"testing"

	"github.com/fxamacker/cbor/v2"
)

func TestAppAttestPhysicalMacAssertion(t *testing.T) {
	data, err := os.ReadFile("testdata/macos27_assertion.json")
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		AppID          string `json:"app_id"`
		PublicKey      []byte `json:"public_key"`
		ClientDataHash []byte `json:"client_data_hash"`
		Assertion      []byte `json:"assertion"`
		Counter        uint32 `json:"counter"`
	}
	if err := json.Unmarshal(data, &fixture); err != nil || len(fixture.ClientDataHash) != 32 {
		t.Fatalf("invalid fixture: %v", err)
	}
	var hash [32]byte
	copy(hash[:], fixture.ClientDataHash)
	v := New(Policy{fixture.AppID, "production"})
	count, metadata, err := v.Assertion(fixture.Assertion, fixture.PublicKey, hash, 0)
	if err != nil || count != fixture.Counter {
		t.Fatalf("Apple assertion: counter %d, error %v", count, err)
	}
	// This real Mac omits extension metadata. Never fabricate a release verdict.
	if metadata.BundleVersion != "" || metadata.ValidationCategory != nil {
		t.Fatalf("fabricated metadata: %+v", metadata)
	}
	if _, _, err := v.Assertion(fixture.Assertion, fixture.PublicKey, hash, count); err == nil {
		t.Fatal("replayed Apple assertion accepted")
	}
	hash[0] ^= 1
	if _, _, err := v.Assertion(fixture.Assertion, fixture.PublicKey, hash, 0); err == nil {
		t.Fatal("Apple assertion accepted for different client data")
	}
	hash[0] ^= 1
	v.policy.AppID = "OTHER.app"
	if _, _, err := v.Assertion(fixture.Assertion, fixture.PublicKey, hash, 0); err == nil || err.Error() != "app_identity" {
		t.Fatalf("Apple assertion accepted for a different app: %v", err)
	}
}

func TestAppAttestAssertionATFlagRejectsCredentialTail(t *testing.T) {
	f := makeFixture(t, true)
	auth := testAuth(t, f.private, 1, false, "production")[:37]
	auth[32] = 0x40
	if _, err := f.verifier.authData(auth, false); err != nil {
		t.Fatalf("Mac assertion header rejected: %v", err)
	}
	if _, err := f.verifier.authData(append(auth, 0, 32, 0), false); err == nil {
		t.Fatal("AT bit allowed unexpected credential bytes in an assertion")
	}
}

func TestAppAttestAssertionRejectsSignatureOverUnhashedNonce(t *testing.T) {
	f := makeFixture(t, true)
	auth := testAuth(t, f.private, 1, false, "production")
	nonce := digest(auth, f.hash)
	// The old synthetic fixture signed the nonce as an already-hashed digest.
	// Actual Mac assertions use ES256 over the nonce as a message.
	sig, err := ecdsa.SignASN1(rand.Reader, f.private, nonce[:])
	if err != nil {
		t.Fatal(err)
	}
	proof, err := cbor.Marshal(map[string]any{"signature": sig, "authenticatorData": auth})
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := f.verifier.Assertion(proof, f.public, f.hash, 0); err == nil {
		t.Fatal("incorrect signature construction accepted")
	}
}
