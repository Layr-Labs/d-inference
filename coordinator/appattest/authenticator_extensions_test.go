package appattest

import (
	"crypto/ecdsa"
	"crypto/rand"
	"crypto/sha256"
	"testing"

	"github.com/fxamacker/cbor/v2"
)

func TestValidationCategoryEncodings(t *testing.T) {
	// Apple's published attestation contains CBOR 44 01 00 00 00 for this
	// field: a four-byte little-endian value, not a CBOR integer.
	// https://developer.apple.com/documentation/devicecheck/attestation-object-validation-guide
	cases := []struct {
		name string
		raw  cbor.RawMessage
		want uint32
		bad  bool
	}{
		{"apple_example", []byte{0x44, 1, 0, 0, 0}, 1, false},
		{"developer_id_bytes", []byte{0x44, 6, 0, 0, 0}, 6, false},
		{"developer_id_integer", []byte{6}, 6, false},
		{"unknown_category_remains_unknown", []byte{0x44, 0, 0, 0, 6}, 0x06000000, false},
		{"short_bytes", []byte{0x43, 6, 0, 0}, 0, true},
		{"long_bytes", []byte{0x45, 6, 0, 0, 0, 0}, 0, true},
		{"negative", []byte{0x20}, 0, true},
		{"overflow", []byte{0x1b, 0, 0, 0, 1, 0, 0, 0, 0}, 0, true},
		{"text", []byte{0x61, '6'}, 0, true},
		{"float", []byte{0xf9, 0x46, 0}, 0, true},
		{"null", []byte{0xf6}, 0, true},
		{"boolean", []byte{0xf5}, 0, true},
	}
	v := New(Policy{"TEST.app", "production"})
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			auth := categoryAuthData(t, tc.raw)
			got, err := v.authData(auth, false)
			if tc.bad {
				if err == nil || err.Error() != "validation_category" {
					t.Fatalf("invalid category accepted: %+v, %v", got, err)
				}
				return
			}
			if err != nil || got.category == nil || *got.category != tc.want {
				t.Fatalf("category: %+v, %v; want %d", got, err, tc.want)
			}
		})
	}
}

func TestAssertionAuthenticatesByteEncodedCategory(t *testing.T) {
	f := makeFixture(t, true)
	auth := categoryAuthData(t, cbor.RawMessage{0x44, 6, 0, 0, 0})
	nonce := digest(auth, f.hash)
	nonce = sha256.Sum256(nonce[:])
	signature, err := ecdsa.SignASN1(rand.Reader, f.private, nonce[:])
	if err != nil {
		t.Fatal(err)
	}
	proof, err := cbor.Marshal(map[string]any{"signature": signature, "authenticatorData": auth})
	if err != nil {
		t.Fatal(err)
	}
	counter, metadata, err := f.verifier.Assertion(proof, f.public, f.hash, 0)
	if err != nil || counter != 1 || metadata.ValidationCategory == nil || *metadata.ValidationCategory != 6 {
		t.Fatalf("byte-encoded assertion: %d %+v %v", counter, metadata, err)
	}
	tampered := categoryAuthData(t, cbor.RawMessage{0x44, 4, 0, 0, 0})
	proof, err = cbor.Marshal(map[string]any{"signature": signature, "authenticatorData": tampered})
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := f.verifier.Assertion(proof, f.public, f.hash, 0); err == nil {
		t.Fatal("modified category accepted with original signature")
	}
}

func categoryAuthData(t *testing.T, category cbor.RawMessage) []byte {
	t.Helper()
	rp := sha256.Sum256([]byte("TEST.app"))
	auth := append([]byte{}, rp[:]...)
	auth = append(auth, 0x80, 0, 0, 0, 1)
	extensions, err := cbor.Marshal(map[string]any{
		"apple_bundle_version_01":      "0.9.2",
		"apple_validation_category_01": category,
	})
	if err != nil {
		t.Fatal(err)
	}
	return append(auth, extensions...)
}
