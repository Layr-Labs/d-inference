package appattest

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/rand"
	"crypto/sha256"
	"testing"

	"github.com/fxamacker/cbor/v2"
)

func TestMacCodeMeasurementShapeAndUnknownAlgorithms(t *testing.T) {
	for _, tc := range []struct {
		name            string
		hash, algorithm any
		bad, qualified  bool
	}{
		{"observed SDK27 SHA256", bytes.Repeat([]byte{1}, 32), []byte{2}, false, true},
		{"unknown algorithm", bytes.Repeat([]byte{1}, 32), []byte{255}, false, false},
		{"truncated CDHash", bytes.Repeat([]byte{1}, 20), []byte{2}, true, false},
		{"text hash", "hash", []byte{2}, true, false},
		{"integer algorithm", bytes.Repeat([]byte{1}, 32), 2, true, false},
		{"missing type", bytes.Repeat([]byte{1}, 32), nil, true, false},
		{"missing hash", nil, []byte{2}, true, false},
		{"oversized", bytes.Repeat([]byte{1}, 65), []byte{255}, true, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			values := map[string]cbor.RawMessage{}
			if tc.hash != nil {
				values["apple_cd_hash_hash_01"], _ = cbor.Marshal(tc.hash)
			}
			if tc.algorithm != nil {
				values["apple_cd_hash_type_01"], _ = cbor.Marshal(tc.algorithm)
			}
			hash, algorithm, err := codeDirectoryMeasurement(values)
			if (err != nil) != tc.bad {
				t.Fatalf("error=%v", err)
			}
			key := &Key{CodeDirectoryHash: hash, CodeDirectoryType: algorithm}
			if (len(key.CodeDirectorySHA256()) != 0) != tc.qualified {
				t.Fatal("unsupported measurement qualified")
			}
		})
	}
	if hash, algorithm, err := codeDirectoryMeasurement(nil); err != nil || hash != nil || algorithm != nil {
		t.Fatal("legacy assertions must remain decodable")
	}
}

func TestMacCodeMeasurementIsCoveredByAssertionSignature(t *testing.T) {
	f := makeFixture(t, true)
	digestBytes := bytes.Repeat([]byte{0xab}, 32)
	ext, _ := cbor.Marshal(map[string]any{"apple_cd_hash_hash_01": digestBytes, "apple_cd_hash_type_01": []byte{2}, "apple_validation_category_01": []byte{6, 0, 0, 0}})
	rp := sha256.Sum256([]byte("TEST.app"))
	auth := append(append(append([]byte{}, rp[:]...), 0x80, 0, 0, 0, 1), ext...)
	nonce := digest(auth, f.hash)
	hashed := sha256.Sum256(nonce[:])
	signature, _ := ecdsa.SignASN1(rand.Reader, f.private, hashed[:])
	proof, _ := cbor.Marshal(map[string]any{"signature": signature, "authenticatorData": auth})
	_, metadata, err := f.verifier.Assertion(proof, f.public, f.hash, 0)
	if err != nil || !bytes.Equal(metadata.CodeDirectorySHA256(), digestBytes) || metadata.BundleVersion != "" {
		t.Fatalf("metadata=%+v error=%v", metadata, err)
	}
	index := bytes.Index(auth, digestBytes)
	if index < 37 {
		t.Fatal("measurement missing from signed extensions")
	}
	auth[index] ^= 1
	proof, _ = cbor.Marshal(map[string]any{"signature": signature, "authenticatorData": auth})
	if _, _, err := f.verifier.Assertion(proof, f.public, f.hash, 0); err == nil {
		t.Fatal("modified measurement accepted under original signature")
	}
}
