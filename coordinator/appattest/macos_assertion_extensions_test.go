package appattest

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"encoding/binary"
	"testing"

	"github.com/fxamacker/cbor/v2"
)

// A macOS 27 assertion can contain the measured Apple extension dictionary
// while leaving ED clear. Synthetic keys and measurements keep private Apple
// evidence out of the repository.
func TestMacAssertionExtensionsWithoutEDFlag(t *testing.T) {
	f := makeFixture(t, true)
	measured := macAttestationExtensions(t)
	if len(measured) != 116 {
		t.Fatalf("unexpected synthetic measured dictionary size: %d", len(measured))
	}
	auth := macAssertionAuthData(t, "TEST.app", 1, measured)
	proof := signMacAssertion(t, f, auth)
	count, metadata, err := f.verifier.Assertion(proof, f.public, f.hash, 0)
	if err != nil || count != 1 || metadata.ValidationCategory == nil || *metadata.ValidationCategory != 6 ||
		!bytes.Equal(metadata.CodeDirectorySHA256(), bytes.Repeat([]byte{0x42}, 32)) {
		t.Fatalf("measured Mac assertion rejected or metadata lost: count=%d metadata=%+v err=%v", count, metadata, err)
	}
	if _, _, err := f.verifier.Assertion(proof, f.public, f.hash, 1); err == nil || err.Error() != "counter_replay" {
		t.Fatalf("replayed counter accepted: %v", err)
	}
	if _, _, err := f.verifier.Assertion(proof, f.public, sha256.Sum256([]byte("another challenge")), 0); err == nil || err.Error() != "signature" {
		t.Fatalf("wrong challenge accepted: %v", err)
	}
	wrongApp := *f.verifier
	wrongApp.policy.AppID = "TEST.other"
	if _, _, err := wrongApp.Assertion(proof, f.public, f.hash, 0); err == nil || err.Error() != "app_identity" {
		t.Fatalf("wrong app accepted: %v", err)
	}
	otherKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	otherPublic := elliptic.Marshal(elliptic.P256(), otherKey.X, otherKey.Y)
	if _, _, err := f.verifier.Assertion(proof, otherPublic, f.hash, 0); err == nil || err.Error() != "signature" {
		t.Fatalf("wrong key accepted: %v", err)
	}

	tampered := bytes.Clone(auth)
	tampered[len(tampered)-1] ^= 1
	changedProof, err := cbor.Marshal(map[string]any{"signature": assertionSignature(t, f, auth), "authenticatorData": tampered})
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := f.verifier.Assertion(changedProof, f.public, f.hash, 0); err == nil || err.Error() != "signature" {
		t.Fatalf("tampered measured bytes accepted: %v", err)
	}
	missingAT := bytes.Clone(auth)
	missingAT[32] &^= 0x40
	if _, _, err := f.verifier.Assertion(signMacAssertion(t, f, missingAT), f.public, f.hash, 0); err == nil || err.Error() != "authenticator_trailing_data" {
		t.Fatalf("unflagged assertion without Mac AT bit accepted: %v", err)
	}
	extraFlag := bytes.Clone(auth)
	extraFlag[32] |= 0x01
	if _, _, err := f.verifier.Assertion(signMacAssertion(t, f, extraFlag), f.public, f.hash, 0); err == nil || err.Error() != "authenticator_trailing_data" {
		t.Fatalf("unflagged assertion with unobserved flags accepted: %v", err)
	}
}

func TestMacAssertionAuthenticatesTruncatedSHA256Measurement(t *testing.T) {
	f := makeFixture(t, true)
	short, err := cbor.Marshal(map[string]any{
		"apple_validation_category_01": []byte{6, 0, 0, 0},
		"apple_cd_hash_type_01":        []byte{2},
		"apple_cd_hash_hash_01":        bytes.Repeat([]byte{0x42}, 20),
	})
	if err != nil {
		t.Fatal(err)
	}
	auth := macAssertionAuthData(t, "TEST.app", 1, short)
	proof := signMacAssertion(t, f, auth)
	count, metadata, err := f.verifier.Assertion(proof, f.public, f.hash, 0)
	if err != nil || count != 1 || !bytes.Equal(metadata.CodeDirectorySHA256Candidate(), bytes.Repeat([]byte{0x42}, 20)) || metadata.CodeDirectorySHA256() != nil {
		t.Fatalf("signed short Apple measurement not preserved distinctly: count=%d metadata=%+v err=%v", count, metadata, err)
	}
	tampered := bytes.Clone(auth)
	tampered[len(tampered)-1] ^= 1
	changedProof, err := cbor.Marshal(map[string]any{"signature": assertionSignature(t, f, auth), "authenticatorData": tampered})
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := f.verifier.Assertion(changedProof, f.public, f.hash, 0); err == nil || err.Error() != "signature" {
		t.Fatalf("tampered short measurement escaped signature binding: %v", err)
	}
}

func TestUnflaggedMacAssertionRequiresCompleteDeveloperIDMeasurement(t *testing.T) {
	f := makeFixture(t, true)
	valid := macAttestationExtensions(t)
	categoryOnly, _ := cbor.Marshal(map[string]any{"apple_validation_category_01": []byte{6, 0, 0, 0}})
	noCategory, _ := cbor.Marshal(map[string]any{"apple_cd_hash_type_01": []byte{2}, "apple_cd_hash_hash_01": bytes.Repeat([]byte{0x42}, 32)})
	nonDeveloper, _ := cbor.Marshal(map[string]any{
		"apple_validation_category_01": []byte{4, 0, 0, 0},
		"apple_cd_hash_type_01":        []byte{2},
		"apple_cd_hash_hash_01":        bytes.Repeat([]byte{0x42}, 32),
	})
	wrongType, _ := cbor.Marshal(map[string]any{
		"apple_validation_category_01": []byte{6, 0, 0, 0},
		"apple_cd_hash_type_01":        []byte{1},
		"apple_cd_hash_hash_01":        bytes.Repeat([]byte{0x42}, 32),
	})
	key, _ := cbor.Marshal("apple_cd_hash_type_01")
	duplicate := append([]byte{0xa2}, append(append(bytes.Clone(key), 0x41, 2), append(key, 0x41, 2)...)...)
	for name, tail := range map[string][]byte{
		"not_map": {0x01}, "null": {0xf6}, "empty_map": {0xa0},
		"no_code_measurement": categoryOnly, "no_category": noCategory,
		"non_developer_id":     nonDeveloper,
		"wrong_code_hash_type": wrongType, "duplicate": duplicate,
		"truncated": valid[:len(valid)-1], "trailing_item": append(bytes.Clone(valid), 0),
	} {
		t.Run(name, func(t *testing.T) {
			auth := macAssertionAuthData(t, "TEST.app", 1, tail)
			proof := signMacAssertion(t, f, auth)
			if _, _, err := f.verifier.Assertion(proof, f.public, f.hash, 0); err == nil {
				t.Fatal("malformed or incomplete unflagged assertion accepted")
			}
		})
	}
}

func macAssertionAuthData(t *testing.T, appID string, counter uint32, extensions []byte) []byte {
	t.Helper()
	rp := sha256.Sum256([]byte(appID))
	auth := append([]byte{}, rp[:]...)
	auth = append(auth, 0x40)
	var count [4]byte
	binary.BigEndian.PutUint32(count[:], counter)
	auth = append(auth, count[:]...)
	return append(auth, extensions...)
}

func assertionSignature(t *testing.T, f fixture, auth []byte) []byte {
	t.Helper()
	nonce := digest(auth, f.hash)
	signatureHash := sha256.Sum256(nonce[:])
	sig, err := ecdsa.SignASN1(rand.Reader, f.private, signatureHash[:])
	if err != nil {
		t.Fatal(err)
	}
	return sig
}

func signMacAssertion(t *testing.T, f fixture, auth []byte) []byte {
	t.Helper()
	proof, err := cbor.Marshal(map[string]any{"signature": assertionSignature(t, f, auth), "authenticatorData": auth})
	if err != nil {
		t.Fatal(err)
	}
	return proof
}
