package attestation

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

type canonicalContractFixture struct {
	StatusCanonical struct {
		CurrentBase64            string `json:"current_base64"`
		LegacyFalseBase64        string `json:"legacy_hypervisor_false_base64"`
		ExplicitSecurityFalseB64 string `json:"explicit_security_false_base64"`
	} `json:"status_canonical"`
}

func TestStatusCanonicalContractFixture(t *testing.T) {
	path := filepath.Join("..", "..", "tests", "contracts", "crypto", "nacl_box.json")
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read fixture: %v", err)
	}
	var fixture canonicalContractFixture
	if err := json.Unmarshal(data, &fixture); err != nil {
		t.Fatalf("decode fixture: %v", err)
	}
	current := decodeContractBase64(t, fixture.StatusCanonical.CurrentBase64)
	legacy := decodeContractBase64(t, fixture.StatusCanonical.LegacyFalseBase64)
	explicitFalse := decodeContractBase64(t, fixture.StatusCanonical.ExplicitSecurityFalseB64)

	trueValue := true
	falseValue := false
	input := StatusCanonicalInput{
		Nonce: "test-nonce", Timestamp: "2026-04-16T12:00:00Z",
		RDMADisabled: &trueValue, SIPEnabled: &trueValue, SecureBootEnabled: &trueValue,
		BinaryHash: "binhash", ActiveModelHash: "activemodel", PythonHash: "pyhash",
		RuntimeHash:    "rthash",
		TemplateHashes: map[string]string{"chatml": "tmplhash1", "gemma": "tmplhash2"},
		ModelHashes:    map[string]string{"qwen": "modelhash1", "trinity": "modelhash2"},
	}
	assertCanonicalContract(t, input, current)
	input.HypervisorActive = &falseValue
	assertCanonicalContract(t, input, legacy)
	assertCanonicalContract(t, StatusCanonicalInput{
		Nonce: "n", Timestamp: "t", SIPEnabled: &falseValue,
	}, explicitFalse)
}

func decodeContractBase64(t *testing.T, encoded string) []byte {
	t.Helper()
	decoded, err := base64.StdEncoding.DecodeString(encoded)
	if err != nil {
		t.Fatal(err)
	}
	return decoded
}

func assertCanonicalContract(t *testing.T, input StatusCanonicalInput, want []byte) {
	t.Helper()
	got, err := BuildStatusCanonical(input)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, want) {
		t.Fatalf("canonical bytes mismatch\nwant: %s\ngot:  %s", want, got)
	}
}
