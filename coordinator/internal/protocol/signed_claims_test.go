package protocol

import (
	"strings"
	"testing"
)

func TestCanonicalRegisterJSONIsAlphabetical(t *testing.T) {
	c := RegisterClaims{
		Timestamp:       "2026-01-01T00:00:00Z",
		Backend:         "vllm_mlx",
		Version:         "0.4.0",
		PublicKey:       "abc",
		WalletAddress:   "0x0",
		AuthToken:       "tok",
		PythonHash:      "ph",
		RuntimeHash:     "rh",
		GrpcBinaryHash:  "gh",
		ImageBridgeHash: "ih",
		TemplateHashes:  map[string]string{"chatml": "11", "llama": "22"},
		ModelHashes:     map[string]string{"a": "1", "z": "9"},
		PrefillTPSMilli: 500_000,
		DecodeTPSMilli:  100_000,
	}
	got := string(CanonicalRegisterJSON(c))
	// Top-level fields must appear alphabetically
	for i, key := range []string{
		"\"auth_token\"", "\"backend\"", "\"decode_tps_milli\"",
		"\"grpc_binary_hash\"", "\"image_bridge_hash\"", "\"model_hashes\"",
		"\"prefill_tps_milli\"", "\"public_key\"", "\"python_hash\"",
		"\"runtime_hash\"", "\"template_hashes\"", "\"timestamp\"",
		"\"version\"", "\"wallet_address\"",
	} {
		if !strings.Contains(got, key) {
			t.Fatalf("missing key %s in %s", key, got)
		}
		if i > 0 {
			prev := []string{"\"auth_token\"", "\"backend\"", "\"decode_tps_milli\"",
				"\"grpc_binary_hash\"", "\"image_bridge_hash\"", "\"model_hashes\"",
				"\"prefill_tps_milli\"", "\"public_key\"", "\"python_hash\"",
				"\"runtime_hash\"", "\"template_hashes\"", "\"timestamp\"",
				"\"version\"", "\"wallet_address\""}[i-1]
			if strings.Index(got, prev) > strings.Index(got, key) {
				t.Fatalf("keys not alphabetical: %s appears after %s in %s", prev, key, got)
			}
		}
	}
}

func TestCanonicalChallengeJSONIsStable(t *testing.T) {
	c := ChallengeClaims{
		Nonce:             "n",
		Timestamp:         "t",
		BinaryHash:        "bh",
		ActiveModelHash:   "amh",
		PythonHash:        "ph",
		RuntimeHash:       "rh",
		GrpcBinaryHash:    "",
		ImageBridgeHash:   "",
		TemplateHashes:    map[string]string{"chatml": "11"},
		ModelHashes:       map[string]string{"m1": "h1", "m2": "h2"},
		SIPEnabled:        true,
		SecureBootEnabled: true,
		RDMADisabled:      true,
		HypervisorActive:  false,
	}
	a := CanonicalChallengeJSON(c)
	b := CanonicalChallengeJSON(c)
	if string(a) != string(b) {
		t.Fatalf("canonical JSON not stable across calls")
	}
	// nested map keys must also be alphabetical
	got := string(a)
	if strings.Index(got, "\"m1\"") > strings.Index(got, "\"m2\"") {
		t.Fatalf("nested map keys not alphabetical: %s", got)
	}
}

// TestCanonicalChallengeJSONByteForByteRustParity asserts the output matches
// what the Rust provider emits byte-for-byte. The reference string was
// captured from `cargo test` against signed_claims.rs with identical inputs.
func TestCanonicalChallengeJSONByteForByteRustParity(t *testing.T) {
	c := ChallengeClaims{
		Nonce:             "n",
		Timestamp:         "t",
		BinaryHash:        "bh",
		ActiveModelHash:   "amh",
		PythonHash:        "ph",
		RuntimeHash:       "rh",
		GrpcBinaryHash:    "",
		ImageBridgeHash:   "",
		TemplateHashes:    map[string]string{},
		ModelHashes:       map[string]string{"apple": "a", "zebra": "z"},
		SIPEnabled:        true,
		SecureBootEnabled: true,
		RDMADisabled:      true,
		HypervisorActive:  false,
	}
	got := string(CanonicalChallengeJSON(c))
	want := `{"active_model_hash":"amh","binary_hash":"bh","grpc_binary_hash":"","hypervisor_active":false,"image_bridge_hash":"","model_hashes":{"apple":"a","zebra":"z"},"nonce":"n","python_hash":"ph","rdma_disabled":true,"runtime_hash":"rh","secure_boot_enabled":true,"sip_enabled":true,"template_hashes":{},"timestamp":"t"}`
	if got != want {
		t.Fatalf("byte mismatch:\n got: %s\nwant: %s", got, want)
	}
}

func TestCanonicalRegisterJSONByteForByteRustParity(t *testing.T) {
	c := RegisterClaims{
		Timestamp:       "2026-01-01T00:00:00Z",
		Backend:         "vllm_mlx",
		Version:         "0.4.0",
		PublicKey:       "abc",
		WalletAddress:   "0x0",
		AuthToken:       "",
		PythonHash:      "",
		RuntimeHash:     "",
		GrpcBinaryHash:  "",
		ImageBridgeHash: "",
		TemplateHashes:  map[string]string{},
		ModelHashes:     map[string]string{},
		PrefillTPSMilli: 500_000,
		DecodeTPSMilli:  100_000,
	}
	got := string(CanonicalRegisterJSON(c))
	want := `{"auth_token":"","backend":"vllm_mlx","decode_tps_milli":100000,"grpc_binary_hash":"","image_bridge_hash":"","model_hashes":{},"prefill_tps_milli":500000,"public_key":"abc","python_hash":"","runtime_hash":"","template_hashes":{},"timestamp":"2026-01-01T00:00:00Z","version":"0.4.0","wallet_address":"0x0"}`
	if got != want {
		t.Fatalf("byte mismatch:\n got: %s\nwant: %s", got, want)
	}
}
