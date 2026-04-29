package attestation

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"encoding/asn1"
	"encoding/base64"
	"testing"
)

func TestProviderIdentityRegistrationCanonicalGolden(t *testing.T) {
	templates := map[string]string{"z": "2", "a": "1"}
	got, err := BuildProviderIdentityRegistrationCanonical(ProviderIdentityRegistrationInput{
		ProviderIdentityPublicKey: "idpk",
		PublicKey:                 "x25519",
		BinaryHash:                "binhash",
		Version:                   "0.4.7",
		Backend:                   "inprocess-mlx",
		EncryptedResponseChunks:   true,
		PythonHash:                "py",
		RuntimeHash:               "rt",
		TemplateHashes:            templates,
		PrivacyCapabilities: &ProviderIdentityPrivacyCapabilities{
			TextBackendInprocess:    true,
			TextProxyDisabled:       true,
			PythonRuntimeLocked:     true,
			DangerousModulesBlocked: true,
			SIPEnabled:              true,
			AntiDebugEnabled:        true,
			CoreDumpsDisabled:       true,
			EnvScrubbed:             true,
			HypervisorActive:        false,
		},
	})
	if err != nil {
		t.Fatal(err)
	}

	expected := `{"backend":"inprocess-mlx","binary_hash":"binhash","domain":"darkbloom.provider.registration.v1","encrypted_response_chunks":true,"privacy_capabilities":{"anti_debug_enabled":true,"core_dumps_disabled":true,"dangerous_modules_blocked":true,"env_scrubbed":true,"hypervisor_active":false,"python_runtime_locked":true,"sip_enabled":true,"text_backend_inprocess":true,"text_proxy_disabled":true},"provider_identity_public_key":"idpk","public_key":"x25519","python_hash":"py","runtime_hash":"rt","template_hashes":{"a":"1","z":"2"},"version":"0.4.7"}`
	if string(got) != expected {
		t.Fatalf("canonical mismatch\n got: %s\nwant: %s", got, expected)
	}
}

func TestProviderIdentityChallengeCanonicalGolden(t *testing.T) {
	truthy := true
	got, err := BuildProviderIdentityChallengeCanonical(ProviderIdentityChallengeInput{
		ProviderIdentityPublicKey: "idpk",
		PublicKey:                 "x25519",
		Nonce:                     "nonce",
		Timestamp:                 "2026-04-28T20:00:00Z",
		HypervisorActive:          &truthy,
		RDMADisabled:              &truthy,
		SIPEnabled:                &truthy,
		SecureBootEnabled:         &truthy,
		BinaryHash:                "binhash",
		ActiveModelHash:           "active",
		PythonHash:                "py",
		RuntimeHash:               "rt",
		TemplateHashes:            map[string]string{"z": "2", "a": "1"},
		ModelHashes:               map[string]string{"qwen": "abc", "llama": "def"},
	})
	if err != nil {
		t.Fatal(err)
	}

	expected := `{"active_model_hash":"active","binary_hash":"binhash","domain":"darkbloom.provider.challenge.v1","hypervisor_active":true,"model_hashes":{"llama":"def","qwen":"abc"},"nonce":"nonce","provider_identity_public_key":"idpk","public_key":"x25519","python_hash":"py","rdma_disabled":true,"runtime_hash":"rt","secure_boot_enabled":true,"sip_enabled":true,"template_hashes":{"a":"1","z":"2"},"timestamp":"2026-04-28T20:00:00Z"}`
	if string(got) != expected {
		t.Fatalf("canonical mismatch\n got: %s\nwant: %s", got, expected)
	}
}

func TestProviderIdentityCanonicalDoesNotEscapeHTML(t *testing.T) {
	got, err := BuildProviderIdentityRegistrationCanonical(ProviderIdentityRegistrationInput{
		ProviderIdentityPublicKey: "id<&>pk",
		PublicKey:                 "x25519",
		Backend:                   "inprocess-mlx",
		EncryptedResponseChunks:   true,
		TemplateHashes:            map[string]string{"a<&>": "v<&>"},
	})
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != `{"backend":"inprocess-mlx","domain":"darkbloom.provider.registration.v1","encrypted_response_chunks":true,"provider_identity_public_key":"id<&>pk","public_key":"x25519","template_hashes":{"a<&>":"v<&>"}}` {
		t.Fatalf("canonical HTML escaping mismatch: %s", got)
	}
}

func TestProviderIdentityChallengeCanonicalDoesNotEscapeHTML(t *testing.T) {
	got, err := BuildProviderIdentityChallengeCanonical(ProviderIdentityChallengeInput{
		ProviderIdentityPublicKey: "id<&>pk",
		PublicKey:                 "x<&>25519",
		Nonce:                     "n<&>",
		Timestamp:                 "2026-04-28T20:00:00Z",
		BinaryHash:                "bin<&>hash",
		TemplateHashes:            map[string]string{"a<&>": "v<&>"},
		ModelHashes:               map[string]string{"m<&>": "w<&>"},
	})
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != `{"binary_hash":"bin<&>hash","domain":"darkbloom.provider.challenge.v1","model_hashes":{"m<&>":"w<&>"},"nonce":"n<&>","provider_identity_public_key":"id<&>pk","public_key":"x<&>25519","template_hashes":{"a<&>":"v<&>"},"timestamp":"2026-04-28T20:00:00Z"}` {
		t.Fatalf("canonical challenge HTML escaping mismatch: %s", got)
	}
}

func TestVerifyProviderIdentitySignature(t *testing.T) {
	priv, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}

	payload := []byte(`{"domain":"darkbloom.provider.registration.v1","public_key":"x25519"}`)
	sig := signProviderIdentityTestPayload(t, priv, payload)
	pub := base64.StdEncoding.EncodeToString(elliptic.Marshal(elliptic.P256(), priv.X, priv.Y))

	if err := VerifyProviderIdentitySignature(pub, sig, payload); err != nil {
		t.Fatalf("signature should verify: %v", err)
	}
	if err := VerifyProviderIdentitySignature(pub, sig, []byte(`{"domain":"tampered"}`)); err == nil {
		t.Fatal("tampered payload should fail verification")
	}
}

func signProviderIdentityTestPayload(t *testing.T, priv *ecdsa.PrivateKey, payload []byte) string {
	t.Helper()
	hash := sha256.Sum256(payload)
	r, s, err := ecdsa.Sign(rand.Reader, priv, hash[:])
	if err != nil {
		t.Fatal(err)
	}
	der, err := asn1.Marshal(ecdsaSig{R: r, S: s})
	if err != nil {
		t.Fatal(err)
	}
	return base64.StdEncoding.EncodeToString(der)
}
