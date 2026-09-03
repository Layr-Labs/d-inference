package attestation

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"encoding/asn1"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"math/big"
	"os"
	"path/filepath"
	"testing"
)

type statusCanonicalFixtureCorpus struct {
	SchemaVersion uint32                   `json:"schema_version"`
	Cases         []statusCanonicalFixture `json:"cases"`
}

type statusCanonicalFixture struct {
	Name                         string                      `json:"name"`
	Input                        statusCanonicalFixtureInput `json:"input"`
	ExpectedSignatureInputBase64 string                      `json:"expected_signature_input_base64"`
}

type statusCanonicalFixtureInput struct {
	Nonce             string            `json:"nonce"`
	Timestamp         string            `json:"timestamp"`
	HypervisorActive  *bool             `json:"hypervisor_active"`
	RDMADisabled      *bool             `json:"rdma_disabled"`
	SIPEnabled        *bool             `json:"sip_enabled"`
	SecureBootEnabled *bool             `json:"secure_boot_enabled"`
	BinaryHash        string            `json:"binary_hash"`
	ActiveModelHash   string            `json:"active_model_hash"`
	PythonHash        string            `json:"python_hash"`
	RuntimeHash       string            `json:"runtime_hash"`
	TemplateHashes    map[string]string `json:"template_hashes"`
	GrpcBinaryHash    string            `json:"grpc_binary_hash"`
	ModelHashes       map[string]string `json:"model_hashes"`
}

func (in statusCanonicalFixtureInput) canonicalInput() StatusCanonicalInput {
	return StatusCanonicalInput{
		Nonce:             in.Nonce,
		Timestamp:         in.Timestamp,
		HypervisorActive:  in.HypervisorActive,
		RDMADisabled:      in.RDMADisabled,
		SIPEnabled:        in.SIPEnabled,
		SecureBootEnabled: in.SecureBootEnabled,
		BinaryHash:        in.BinaryHash,
		ActiveModelHash:   in.ActiveModelHash,
		PythonHash:        in.PythonHash,
		RuntimeHash:       in.RuntimeHash,
		TemplateHashes:    in.TemplateHashes,
		GrpcBinaryHash:    in.GrpcBinaryHash,
		ModelHashes:       in.ModelHashes,
	}
}

func TestBuildStatusCanonicalSharedVectors(t *testing.T) {
	corpus := loadStatusCanonicalFixtureCorpus(t)
	if len(corpus.Cases) == 0 {
		t.Fatal("attestation fixture has no named cases")
	}
	seen := make(map[string]struct{}, len(corpus.Cases))
	for _, fixture := range corpus.Cases {
		t.Run(fixture.Name, func(t *testing.T) {
			if fixture.Name == "" {
				t.Fatal("attestation fixture case has no name")
			}
			if _, duplicate := seen[fixture.Name]; duplicate {
				t.Fatalf("duplicate attestation fixture case %q", fixture.Name)
			}
			seen[fixture.Name] = struct{}{}

			expected, err := base64.StdEncoding.DecodeString(fixture.ExpectedSignatureInputBase64)
			if err != nil {
				t.Fatalf("decode expected signature input: %v", err)
			}
			got, err := BuildStatusCanonical(fixture.Input.canonicalInput())
			if err != nil {
				t.Fatalf("BuildStatusCanonical: %v", err)
			}
			if !bytes.Equal(got, expected) {
				t.Fatalf("canonical signature input drifted\nwant: %s\ngot:  %s", expected, got)
			}
		})
	}
}

func TestStatusCanonicalFixtureRejectsSchemaDrift(t *testing.T) {
	for _, test := range []struct {
		name    string
		encoded string
	}{
		{name: "missing", encoded: `{"cases":[]}`},
		{name: "unknown", encoded: `{"schema_version":2,"cases":[]}`},
	} {
		t.Run(test.name, func(t *testing.T) {
			var corpus statusCanonicalFixtureCorpus
			if err := decodeStatusCanonicalFixture([]byte(test.encoded), &corpus); err == nil {
				t.Fatal("fixture schema drift was accepted")
			}
		})
	}
}

func loadStatusCanonicalFixtureCorpus(t *testing.T) statusCanonicalFixtureCorpus {
	t.Helper()
	encoded, err := os.ReadFile(filepath.Join(
		"..", "..", "fixtures", "security", "v1", "attestation_status_vectors.json",
	))
	if err != nil {
		t.Fatal(err)
	}
	var corpus statusCanonicalFixtureCorpus
	if err := decodeStatusCanonicalFixture(encoded, &corpus); err != nil {
		t.Fatal(err)
	}
	return corpus
}

func decodeStatusCanonicalFixture(encoded []byte, output any) error {
	var metadata struct {
		SchemaVersion *uint32 `json:"schema_version"`
	}
	if err := json.Unmarshal(encoded, &metadata); err != nil {
		return err
	}
	if metadata.SchemaVersion == nil {
		return errors.New("fixture schema version is missing")
	}
	if *metadata.SchemaVersion != 1 {
		return fmt.Errorf("unsupported fixture schema version %d", *metadata.SchemaVersion)
	}
	return json.Unmarshal(encoded, output)
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
