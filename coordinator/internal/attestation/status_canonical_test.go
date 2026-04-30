package attestation

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"encoding/asn1"
	"encoding/base64"
	"errors"
	"math/big"
	"testing"
)

// TestBuildStatusCanonicalGoldenBytes is the cross-language wire-format
// guard. The bytes asserted here MUST be identical to the bytes produced
// by Rust's build_status_canonical for the same input. The matching Rust
// test lives in provider/src/coordinator.rs (test_build_status_canonical_golden_bytes).
// If either side drifts, both tests fail and you catch the protocol drift
// before it ships.
func TestBuildStatusCanonicalGoldenBytes(t *testing.T) {
	True := true
	in := StatusCanonicalInput{
		Nonce:             "test-nonce",
		Timestamp:         "2026-04-16T12:00:00Z",
		HypervisorActive:  &True,
		RDMADisabled:      &True,
		SIPEnabled:        &True,
		SecureBootEnabled: &True,
		BinaryHash:        "binhash",
		ActiveModelHash:   "activemodel",
		PythonHash:        "pyhash",
		RuntimeHash:       "rthash",
		TemplateHashes: map[string]string{
			"chatml": "tmplhash1",
			"gemma":  "tmplhash2",
		},
		GrpcBinaryHash:  "",
		ImageBridgeHash: "imghash",
		ModelHashes: map[string]string{
			"qwen":    "modelhash1",
			"trinity": "modelhash2",
		},
	}

	got, err := BuildStatusCanonical(in)
	if err != nil {
		t.Fatalf("BuildStatusCanonical: %v", err)
	}

	expected := []byte(`{"active_model_hash":"activemodel","binary_hash":"binhash","hypervisor_active":true,"image_bridge_hash":"imghash","model_hashes":{"qwen":"modelhash1","trinity":"modelhash2"},"nonce":"test-nonce","python_hash":"pyhash","rdma_disabled":true,"runtime_hash":"rthash","secure_boot_enabled":true,"sip_enabled":true,"template_hashes":{"chatml":"tmplhash1","gemma":"tmplhash2"},"timestamp":"2026-04-16T12:00:00Z"}`)

	if !bytes.Equal(got, expected) {
		t.Fatalf("canonical bytes drifted from Rust golden — protocol break\nwant: %s\ngot:  %s", expected, got)
	}
}

// TestBuildStatusCanonicalOmitsEmpties verifies the omission convention.
// "Unknown" must look different from "false" so a downgrade attacker
// can't strip a positive claim and have it look like normal omission.
func TestBuildStatusCanonicalOmitsEmpties(t *testing.T) {
	got, err := BuildStatusCanonical(StatusCanonicalInput{
		Nonce:     "n",
		Timestamp: "t",
	})
	if err != nil {
		t.Fatalf("BuildStatusCanonical: %v", err)
	}
	expected := []byte(`{"nonce":"n","timestamp":"t"}`)
	if !bytes.Equal(got, expected) {
		t.Fatalf("expected only nonce+timestamp\nwant: %s\ngot:  %s", expected, got)
	}
}

// TestBuildStatusCanonicalFalseIsExplicit verifies that sip_enabled=false
// is signed as `"sip_enabled":false`, distinct from the omitted (nil)
// case. This is the entire point of the omit-empties convention — a
// downgrade attacker must not be able to strip a positive claim and
// have it look like normal absence.
func TestBuildStatusCanonicalFalseIsExplicit(t *testing.T) {
	False := false
	got, err := BuildStatusCanonical(StatusCanonicalInput{
		Nonce:      "n",
		Timestamp:  "t",
		SIPEnabled: &False,
	})
	if err != nil {
		t.Fatal(err)
	}
	expected := []byte(`{"nonce":"n","sip_enabled":false,"timestamp":"t"}`)
	if !bytes.Equal(got, expected) {
		t.Fatalf("false bool not explicitly serialized\nwant: %s\ngot:  %s", expected, got)
	}
}

// TestBuildStatusCanonicalUnicodeNonce guards against future protocol
// changes that introduce non-ASCII into a signed field. Both Go's
// encoding/json and Rust's serde_json escape control chars but pass
// printable Unicode through as UTF-8 — verify the output is valid UTF-8
// and doesn't double-escape.
func TestBuildStatusCanonicalUnicodeNonce(t *testing.T) {
	// Fictional unicode nonce — nonces are base64 in production, but if
	// the protocol ever changed, we want the canonical to handle UTF-8
	// the same way on both sides.
	got, err := BuildStatusCanonical(StatusCanonicalInput{
		Nonce:     "ñön¢é-π",
		Timestamp: "t",
	})
	if err != nil {
		t.Fatal(err)
	}
	expected := []byte(`{"nonce":"ñön¢é-π","timestamp":"t"}`)
	if !bytes.Equal(got, expected) {
		t.Fatalf("unicode handling drifted\nwant: %s\ngot:  %s", expected, got)
	}
}

// TestVerifyStatusSignatureMissingReturnsSentinel ensures legacy
// providers (no status_signature field) trigger ErrStatusSignatureMissing
// rather than a generic verification failure — callers gate trust
// behavior on this specific error.
func TestVerifyStatusSignatureMissing(t *testing.T) {
	err := VerifyStatusSignature("anykey", "", StatusCanonicalInput{Nonce: "n", Timestamp: "t"})
	if !errors.Is(err, ErrStatusSignatureMissing) {
		t.Fatalf("expected ErrStatusSignatureMissing, got %v", err)
	}
}

// TestVerifyStatusSignatureRoundTrip exercises the full verify path
// with a synthetic P-256 keypair: build canonical, sign it with the
// private key, verify with the public key.
func TestVerifyStatusSignatureRoundTrip(t *testing.T) {
	priv, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	// Build raw 64-byte uncompressed pubkey (X||Y), base64.
	pubBytes := elliptic.Marshal(elliptic.P256(), priv.X, priv.Y) // 65 bytes (0x04 || X || Y)
	pubB64 := base64.StdEncoding.EncodeToString(pubBytes)

	in := StatusCanonicalInput{
		Nonce:     "round-trip-nonce",
		Timestamp: "2026-04-16T13:00:00Z",
	}
	canonical, err := BuildStatusCanonical(in)
	if err != nil {
		t.Fatal(err)
	}
	hash := sha256.Sum256(canonical)
	r, s, err := ecdsa.Sign(rand.Reader, priv, hash[:])
	if err != nil {
		t.Fatal(err)
	}
	// DER-encode the signature to match what SE keys produce on the
	// provider side.
	sigDER, err := encodeECDSASig(r, s)
	if err != nil {
		t.Fatal(err)
	}
	sigB64 := base64.StdEncoding.EncodeToString(sigDER)

	if err := VerifyStatusSignature(pubB64, sigB64, in); err != nil {
		t.Fatalf("round-trip verify failed: %v", err)
	}

	// Tamper with one field — verification must reject.
	tampered := in
	tampered.Nonce = "different-nonce"
	if err := VerifyStatusSignature(pubB64, sigB64, tampered); err == nil {
		t.Fatal("expected tampered input to fail verification")
	}
}

// encodeECDSASig writes the (r,s) pair as a DER-encoded ECDSA-Sig-Value,
// matching what Apple Secure Enclave returns.
func encodeECDSASig(r, s *big.Int) ([]byte, error) {
	type ecdsaSig struct {
		R, S *big.Int
	}
	return asn1.Marshal(ecdsaSig{R: r, S: s})
}
