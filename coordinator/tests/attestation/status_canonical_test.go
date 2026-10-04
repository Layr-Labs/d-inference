package attestation_test

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

	production "github.com/eigeninference/d-inference/coordinator/attestation"
)

// swiftStatusCanonicalGolden is the exact canonical status the Swift
// provider's StatusCanonical.build produces for goldenStatusInput. The
// matching Swift test lives in
// provider-swift/Tests/ProviderCoreTests/Security/SecurityTests.swift
// (statusCanonicalMatchesCoordinatorGoldenBytes). If either side drifts,
// both tests fail and you catch the protocol drift before it ships.
const swiftStatusCanonicalGolden = `{"active_model_hash":"activemodel","binary_hash":"binhash","model_hashes":{"qwen":"modelhash1","trinity":"modelhash2"},"nonce":"test-nonce","rdma_disabled":true,"secure_boot_enabled":true,"sip_enabled":true,"template_hashes":{"chatml":"tmplhash1","gemma":"tmplhash2"},"timestamp":"2026-04-16T12:00:00Z"}`

func goldenStatusInput() production.StatusCanonicalInput {
	True := true
	return production.StatusCanonicalInput{
		Nonce:             "test-nonce",
		Timestamp:         "2026-04-16T12:00:00Z",
		RDMADisabled:      &True,
		SIPEnabled:        &True,
		SecureBootEnabled: &True,
		BinaryHash:        "binhash",
		ActiveModelHash:   "activemodel",
		TemplateHashes: map[string]string{
			"chatml": "tmplhash1",
			"gemma":  "tmplhash2",
		},
		GrpcBinaryHash: "",
		ModelHashes: map[string]string{
			"qwen":    "modelhash1",
			"trinity": "modelhash2",
		},
	}
}

// TestBuildStatusCanonicalGoldenBytes is the cross-language wire-format
// guard for the current provider shape. The bytes asserted here MUST be
// identical to the bytes the Swift provider signs for the same input.
func TestBuildStatusCanonicalGoldenBytes(t *testing.T) {
	got, err := production.BuildStatusCanonical(goldenStatusInput())
	if err != nil {
		t.Fatalf("BuildStatusCanonical: %v", err)
	}
	if !bytes.Equal(got, []byte(swiftStatusCanonicalGolden)) {
		t.Fatalf("canonical bytes drifted from Swift golden — protocol break\nwant: %s\ngot:  %s", swiftStatusCanonicalGolden, got)
	}
}

// TestVerifyStatusSignatureOverSwiftGoldenBytes: a provider that signs the
// exact bytes the Swift encoder produces for the current status shape
// verifies against the coordinator's reconstruction of the same fields.
func TestVerifyStatusSignatureOverSwiftGoldenBytes(t *testing.T) {
	priv, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	pubB64 := base64.StdEncoding.EncodeToString(
		elliptic.Marshal(elliptic.P256(), priv.X, priv.Y))
	hash := sha256.Sum256([]byte(swiftStatusCanonicalGolden))
	r, s, err := ecdsa.Sign(rand.Reader, priv, hash[:])
	if err != nil {
		t.Fatal(err)
	}
	sigDER, err := encodeECDSASig(r, s)
	if err != nil {
		t.Fatal(err)
	}
	sigB64 := base64.StdEncoding.EncodeToString(sigDER)
	if err := production.VerifyStatusSignature(pubB64, sigB64, goldenStatusInput()); err != nil {
		t.Fatalf("current-shape signed status failed verification: %v", err)
	}
}

// TestBuildStatusCanonicalOmitsEmpties verifies the omission convention.
// "Unknown" must look different from "false" so a downgrade attacker
// can't strip a positive claim and have it look like normal omission.
func TestBuildStatusCanonicalOmitsEmpties(t *testing.T) {
	got, err := production.BuildStatusCanonical(production.StatusCanonicalInput{
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
	got, err := production.BuildStatusCanonical(production.StatusCanonicalInput{
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
// encoding/json and the Swift provider's JSON encoder escape control
// chars but pass printable Unicode through as UTF-8 — verify the output
// is valid UTF-8 and doesn't double-escape.
func TestBuildStatusCanonicalUnicodeNonce(t *testing.T) {
	// Fictional unicode nonce — nonces are base64 in production, but if
	// the protocol ever changed, we want the canonical to handle UTF-8
	// the same way on both sides.
	got, err := production.BuildStatusCanonical(production.StatusCanonicalInput{
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

// TestBuildStatusCanonicalDoesNotHTMLEscape guards the SetEscapeHTML(false)
// fix. Go's default json.Marshal escapes <, >, & as < > &,
// but the Swift provider's JSONEncoder emits them raw — so any signed field
// containing one of those characters would produce a canonical mismatch and a
// spurious status-signature failure. The canonical bytes here MUST match what
// Swift signs (raw characters, no \u00xx escapes).
func TestBuildStatusCanonicalDoesNotHTMLEscape(t *testing.T) {
	got, err := production.BuildStatusCanonical(production.StatusCanonicalInput{
		// Fictional values exercising every HTML-escaped character. Real
		// hashes/nonces are base64/hex today, which is exactly why this
		// divergence is latent — this test makes it impossible to regress.
		Nonce:           "a<b>c&d",
		Timestamp:       "t",
		BinaryHash:      "x&y",
		ActiveModelHash: "p<q>r",
	})
	if err != nil {
		t.Fatalf("BuildStatusCanonical: %v", err)
	}
	expected := []byte(`{"active_model_hash":"p<q>r","binary_hash":"x&y","nonce":"a<b>c&d","timestamp":"t"}`)
	if !bytes.Equal(got, expected) {
		t.Fatalf("HTML escaping not disabled — canonical will mismatch Swift\nwant: %s\ngot:  %s", expected, got)
	}
	// Belt-and-suspenders: Go's HTML escaping would turn these characters into
	// \u00xx sequences, which introduce a backslash (0x5c). The correct,
	// un-escaped output for these inputs contains no backslash at all — so any
	// backslash byte means escaping leaked back in.
	if bytes.IndexByte(got, '\\') != -1 {
		t.Fatalf("canonical output contains an escape backslash — HTML escaping not fully disabled: %s", got)
	}
}

// TestVerifyStatusSignatureMissingReturnsSentinel ensures legacy
// providers (no status_signature field) trigger ErrStatusSignatureMissing
// rather than a generic verification failure — callers gate trust
// behavior on this specific error.
func TestVerifyStatusSignatureMissing(t *testing.T) {
	err := production.VerifyStatusSignature("anykey", "", production.StatusCanonicalInput{Nonce: "n", Timestamp: "t"})
	if !errors.Is(err, production.ErrStatusSignatureMissing) {
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

	in := production.StatusCanonicalInput{
		Nonce:     "round-trip-nonce",
		Timestamp: "2026-04-16T13:00:00Z",
	}
	canonical, err := production.BuildStatusCanonical(in)
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

	if err := production.VerifyStatusSignature(pubB64, sigB64, in); err != nil {
		t.Fatalf("round-trip verify failed: %v", err)
	}

	// Tamper with one field — verification must reject.
	tampered := in
	tampered.Nonce = "different-nonce"
	if err := production.VerifyStatusSignature(pubB64, sigB64, tampered); err == nil {
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
