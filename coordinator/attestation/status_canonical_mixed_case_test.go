package attestation

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"testing"
)

// The matching Swift vectors live in ProviderCoreTests/StatusCanonicalTests.swift.
// The production-model vector originates in Jake McAllister's PR #826.
func statusCanonicalVectors() []struct {
	name     string
	input    StatusCanonicalInput
	expected string
} {
	True, False := true, false
	return []struct {
		name     string
		input    StatusCanonicalInput
		expected string
	}{
		{
			name: "production-model-ids",
			input: StatusCanonicalInput{Nonce: "n", Timestamp: "t", ModelHashes: map[string]string{
				"Qwen3.5-9B":                   "127de76b4ef82b7a",
				"gemma-4-26b-qat-4bit":         "2468a0cb3049a871",
				"qwen3.6-35b-a3b-vl-mtp-mxfp8": "d932e96b00404b05",
			}},
			expected: `{"model_hashes":{"Qwen3.5-9B":"127de76b4ef82b7a","gemma-4-26b-qat-4bit":"2468a0cb3049a871","qwen3.6-35b-a3b-vl-mtp-mxfp8":"d932e96b00404b05"},"nonce":"n","timestamp":"t"}`,
		},
		{
			name: "both-nested-maps",
			input: StatusCanonicalInput{Nonce: "n", Timestamp: "t", TemplateHashes: map[string]string{
				"template2": "02", "Template10": "10", "template10": "11",
				"_Template": "12", "-template": "13", "Z": "14", "a": "15",
			}, ModelHashes: map[string]string{
				"model2": "22", "Model10": "10", "model10": "11",
				"A.Model": "01", "a/model": "02", "_model": "03", "-model": "04",
			}},
			expected: `{"model_hashes":{"-model":"04","A.Model":"01","Model10":"10","_model":"03","a/model":"02","model10":"11","model2":"22"},"nonce":"n","template_hashes":{"-template":"13","Template10":"10","Z":"14","_Template":"12","a":"15","template10":"11","template2":"02"},"timestamp":"t"}`,
		},
		{
			name: "template-filename-escaping",
			input: StatusCanonicalInput{Nonce: "abc+/=", Timestamp: "t", TemplateHashes: map[string]string{
				"é\"\\\t\n<>&": "d00d", "模板": "beef", "Z": "00",
			}},
			expected: `{"nonce":"abc+/=","template_hashes":{"Z":"00","é\"\\\t\n<>&":"d00d","模板":"beef"},"timestamp":"t"}`,
		},
		{
			name: "template-unicode-separators",
			input: StatusCanonicalInput{Nonce: "n", Timestamp: "t", TemplateHashes: map[string]string{
				"line\u2028paragraph\u2029": "abcd",
			}},
			expected: `{"nonce":"n","template_hashes":{"line\u2028paragraph\u2029":"abcd"},"timestamp":"t"}`,
		},
		{
			name: "lowercase-compatibility",
			input: StatusCanonicalInput{Nonce: "n", Timestamp: "t", TemplateHashes: map[string]string{
				"chatml": "c", "gemma": "d",
			}, ModelHashes: map[string]string{"qwen": "a", "trinity": "b"}},
			expected: `{"model_hashes":{"qwen":"a","trinity":"b"},"nonce":"n","template_hashes":{"chatml":"c","gemma":"d"},"timestamp":"t"}`,
		},
		{
			name: "empty-fields-and-false",
			input: StatusCanonicalInput{
				Nonce: "n", Timestamp: "t", RDMADisabled: &False, SIPEnabled: &False,
				SecureBootEnabled: &True,
			},
			expected: `{"nonce":"n","rdma_disabled":false,"secure_boot_enabled":true,"sip_enabled":false,"timestamp":"t"}`,
		},
		{
			name: "literal-unicode-escape-text",
			input: StatusCanonicalInput{Nonce: "n", Timestamp: "t", TemplateHashes: map[string]string{
				"literal\\u2028\\u2029": "cafe",
			}},
			expected: `{"nonce":"n","template_hashes":{"literal\\u2028\\u2029":"cafe"},"timestamp":"t"}`,
		},
	}
}

func TestBuildStatusCanonicalNestedMapVectors(t *testing.T) {
	for _, vector := range statusCanonicalVectors() {
		t.Run(vector.name, func(t *testing.T) {
			actual, err := BuildStatusCanonical(vector.input)
			if err != nil {
				t.Fatal(err)
			}
			if !bytes.Equal(actual, []byte(vector.expected)) {
				t.Fatalf("canonical bytes differ from Swift vector\nwant: %s\ngot:  %s", vector.expected, actual)
			}
		})
	}
}

func TestVerifyStatusSignatureBindsMixedCaseNestedMaps(t *testing.T) {
	privateKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	publicKey := base64.StdEncoding.EncodeToString(elliptic.Marshal(elliptic.P256(), privateKey.X, privateKey.Y))
	vector := statusCanonicalVectors()[1]
	// Sign the independent Swift golden, not the verifier's reconstructed bytes.
	digest := sha256.Sum256([]byte(vector.expected))
	signature, err := ecdsa.SignASN1(rand.Reader, privateKey, digest[:])
	if err != nil {
		t.Fatal(err)
	}
	signatureB64 := base64.StdEncoding.EncodeToString(signature)
	if err := VerifyStatusSignature(publicKey, signatureB64, vector.input); err != nil {
		t.Fatalf("matching Swift canonical signature rejected: %v", err)
	}

	for _, field := range []string{"model", "template"} {
		t.Run(field, func(t *testing.T) {
			input := statusCanonicalVectors()[1].input
			if field == "model" {
				input.ModelHashes["model2"] = "changed"
			} else {
				input.TemplateHashes["template2"] = "changed"
			}
			if err := VerifyStatusSignature(publicKey, signatureB64, input); err == nil {
				t.Fatal("tampered nested hash accepted")
			}
		})
	}
	// Equivalent JSON in the former case-insensitive order is still a different
	// signed message; the verifier must never accept an alternate ordering.
	legacy := `{"model_hashes":{"gemma-4-26b-qat-4bit":"2468a0cb3049a871","Qwen3.5-9B":"127de76b4ef82b7a","qwen3.6-35b-a3b-vl-mtp-mxfp8":"d932e96b00404b05"},"nonce":"n","timestamp":"t"}`
	legacyDigest := sha256.Sum256([]byte(legacy))
	legacySignature, err := ecdsa.SignASN1(rand.Reader, privateKey, legacyDigest[:])
	if err != nil {
		t.Fatal(err)
	}
	if err := VerifyStatusSignature(publicKey, base64.StdEncoding.EncodeToString(legacySignature), statusCanonicalVectors()[0].input); err == nil {
		t.Fatal("noncanonical ordering accepted")
	}
}
