package appattest

import (
	"bytes"
	"crypto/sha256"
	"testing"

	"github.com/fxamacker/cbor/v2"
)

// Synthetic certificates reproduce the shape of privately replayed production
// proofs. No provider certificate, receipt, identifier or real proof is a fixture.
func macAttestationExtensions(t *testing.T) []byte {
	t.Helper()
	b, err := cbor.Marshal(map[string]any{
		"apple_validation_category_01": []byte{6, 0, 0, 0},
		"apple_cd_hash_type_01":        []byte{2},
		"apple_cd_hash_hash_01":        bytes.Repeat([]byte{0x42}, 32),
	})
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func replaceAttestationExtensions(t *testing.T, auth, extensions []byte) []byte {
	t.Helper()
	var cose map[int]cbor.RawMessage
	tail, err := decoder.UnmarshalFirst(auth[87:], &cose)
	if err != nil {
		t.Fatal(err)
	}
	auth = bytes.Clone(auth[:len(auth)-len(tail)])
	auth[32] &^= 0x80
	return append(auth, extensions...)
}

func TestMacAttestationExtensionsWithoutEDFlag(t *testing.T) {
	f := makeFixtureWithAuth(t, true, func(auth []byte) []byte {
		return replaceAttestationExtensions(t, auth, macAttestationExtensions(t))
	})
	key, err := f.verifier.Attestation(f.proof, f.keyID, f.hash)
	if err != nil {
		t.Fatal(err)
	}
	if key.ValidationCategory == nil || *key.ValidationCategory != 6 || !bytes.Equal(key.CodeDirectorySHA256(), bytes.Repeat([]byte{0x42}, 32)) {
		t.Fatalf("lost authenticated Mac metadata: %+v", key)
	}

	wrong := sha256.Sum256([]byte("another challenge"))
	if _, err := f.verifier.Attestation(f.proof, f.keyID, wrong); err == nil || err.Error() != "nonce" {
		t.Fatalf("unbound extensions accepted: %v", err)
	}
	var object attestationObject
	if err := decoder.Unmarshal(f.proof, &object); err != nil {
		t.Fatal(err)
	}
	object.AuthData[len(object.AuthData)-1] ^= 1
	tampered, _ := cbor.Marshal(object)
	if _, err := f.verifier.Attestation(tampered, f.keyID, f.hash); err == nil || err.Error() != "nonce" {
		t.Fatalf("changed extension bytes accepted: %v", err)
	}
	withoutACL := makeFixtureWithAuth(t, false, func(auth []byte) []byte {
		return replaceAttestationExtensions(t, auth, macAttestationExtensions(t))
	})
	if _, err := withoutACL.verifier.Attestation(withoutACL.proof, withoutACL.keyID, withoutACL.hash); err == nil || err.Error() != "mac_acl" {
		t.Fatalf("unflagged extensions bypassed Mac ACL: %v", err)
	}
}

func TestUnflaggedMacAttestationRequiresCompleteBoundedExtensions(t *testing.T) {
	valid := macAttestationExtensions(t)
	categoryOnly, _ := cbor.Marshal(map[string]any{"apple_validation_category_01": []byte{6, 0, 0, 0}})
	key, _ := cbor.Marshal("apple_cd_hash_type_01")
	duplicate := append([]byte{0xa2}, append(append(bytes.Clone(key), 0x41, 2), append(key, 0x41, 2)...)...)
	for name, tail := range map[string][]byte{
		"not_map": {0x01}, "null": {0xf6}, "empty_map": {0xa0},
		"no_code_measurement": categoryOnly, "duplicate": duplicate,
		"truncated": valid[:len(valid)-1], "trailing_item": append(bytes.Clone(valid), 0),
	} {
		t.Run(name, func(t *testing.T) {
			f := makeFixtureWithAuth(t, true, func(auth []byte) []byte { return replaceAttestationExtensions(t, auth, tail) })
			if _, err := f.verifier.Attestation(f.proof, f.keyID, f.hash); err == nil {
				t.Fatal("malformed unflagged extension accepted")
			}
		})
	}
}

func TestUnflaggedAssertionStillRejectsTrailingDictionary(t *testing.T) {
	f := makeFixture(t, true)
	auth := testAuth(t, f.private, 1, false, "production")
	auth[32] &^= 0x80
	if _, err := f.verifier.authData(auth, false); err == nil || err.Error() != "authenticator_trailing_data" {
		t.Fatalf("attestation compatibility changed assertion framing: %v", err)
	}
}
