package api

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"encoding/asn1"
	"encoding/base64"
	"log/slog"
	"math/big"
	"os"
	"testing"
	"time"

	"github.com/eigeninference/coordinator/internal/attestation"
	"github.com/eigeninference/coordinator/internal/protocol"
	"github.com/eigeninference/coordinator/internal/registry"
	"github.com/eigeninference/coordinator/internal/store"
)

const testKnownBinaryHash = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

type providerIdentityTestSig struct {
	R, S *big.Int
}

func TestProviderIdentityRegistrationVerifiesWithKnownBinaryHash(t *testing.T) {
	srv, reg := providerIdentityTestServer(t)
	srv.SetKnownBinaryHashes([]string{testKnownBinaryHash})

	providerPublicKey := testPublicKeyB64()
	provider := reg.Register("provider-1", nil, &protocol.RegisterMessage{
		Type:                    protocol.TypeRegister,
		Backend:                 "inprocess-mlx",
		PublicKey:               providerPublicKey,
		EncryptedResponseChunks: true,
		PrivacyCapabilities:     testPrivacyCaps(),
	})

	regMsg := signedProviderIdentityRegisterMessage(t, providerPublicKey, testKnownBinaryHash)
	srv.verifyProviderIdentityRegistration(provider.ID, provider, regMsg)

	provider.Mu().Lock()
	defer provider.Mu().Unlock()
	if !provider.ProviderIdentityVerified {
		t.Fatal("provider identity should verify when signature and binary hash are valid")
	}
	if provider.ProviderIdentityPublicKey != regMsg.ProviderIdentityPublicKey {
		t.Fatal("provider identity public key was not recorded")
	}
	if provider.BinaryHash != testKnownBinaryHash {
		t.Fatalf("binary hash = %q, want %q", provider.BinaryHash, testKnownBinaryHash)
	}
}

func TestProviderIdentityRegistrationRequiresKnownBinaryHashes(t *testing.T) {
	srv, reg := providerIdentityTestServer(t)
	providerPublicKey := testPublicKeyB64()
	provider := reg.Register("provider-1", nil, &protocol.RegisterMessage{
		Type:                    protocol.TypeRegister,
		Backend:                 "inprocess-mlx",
		PublicKey:               providerPublicKey,
		EncryptedResponseChunks: true,
		PrivacyCapabilities:     testPrivacyCaps(),
	})

	regMsg := signedProviderIdentityRegisterMessage(t, providerPublicKey, testKnownBinaryHash)
	srv.verifyProviderIdentityRegistration(provider.ID, provider, regMsg)

	provider.Mu().Lock()
	defer provider.Mu().Unlock()
	if provider.ProviderIdentityVerified {
		t.Fatal("provider identity must not verify when the coordinator has no known-good binary hashes")
	}
}

func TestProviderIdentityChallengeMissingBinaryHashClearsVerification(t *testing.T) {
	srv, reg := providerIdentityTestServer(t)
	srv.SetKnownBinaryHashes([]string{testKnownBinaryHash})

	providerPublicKey := testPublicKeyB64()
	identityPriv, identityPublicKey := providerIdentityTestKey(t)
	provider := reg.Register("provider-1", nil, &protocol.RegisterMessage{
		Type:                    protocol.TypeRegister,
		Backend:                 "inprocess-mlx",
		PublicKey:               providerPublicKey,
		EncryptedResponseChunks: true,
		PrivacyCapabilities:     testPrivacyCaps(),
	})
	provider.Mu().Lock()
	provider.ProviderIdentityPublicKey = identityPublicKey
	provider.ProviderIdentityVerified = true
	provider.BinaryHash = testKnownBinaryHash
	provider.LastChallengeVerified = time.Now()
	provider.Mu().Unlock()

	pc := &pendingChallenge{nonce: "nonce", timestamp: "2026-04-28T20:00:00Z"}
	resp := &protocol.AttestationResponseMessage{
		PublicKey:                 providerPublicKey,
		ProviderIdentitySignature: signProviderIdentityPayload(t, identityPriv, []byte("not used")),
	}

	if srv.verifyProviderIdentityChallenge(provider.ID, provider, pc, resp) {
		t.Fatal("challenge should fail when a verified provider omits binary hash")
	}

	provider.Mu().Lock()
	defer provider.Mu().Unlock()
	if provider.ProviderIdentityVerified {
		t.Fatal("missing binary hash should clear provider identity verification")
	}
	if !provider.LastChallengeVerified.IsZero() {
		t.Fatal("failed provider identity challenge should clear prior challenge freshness")
	}
}

func TestProviderIdentityChallengeVerifiesWithKnownBinaryHash(t *testing.T) {
	srv, reg := providerIdentityTestServer(t)
	srv.SetKnownBinaryHashes([]string{testKnownBinaryHash})

	providerPublicKey := testPublicKeyB64()
	identityPriv, identityPublicKey := providerIdentityTestKey(t)
	provider := reg.Register("provider-1", nil, &protocol.RegisterMessage{
		Type:                    protocol.TypeRegister,
		Backend:                 "inprocess-mlx",
		PublicKey:               providerPublicKey,
		EncryptedResponseChunks: true,
		PrivacyCapabilities:     testPrivacyCaps(),
	})
	provider.Mu().Lock()
	provider.ProviderIdentityPublicKey = identityPublicKey
	provider.ProviderIdentityVerified = true
	provider.BinaryHash = testKnownBinaryHash
	provider.Mu().Unlock()

	truthy := true
	pc := &pendingChallenge{nonce: "nonce", timestamp: "2026-04-28T20:00:00Z"}
	resp := &protocol.AttestationResponseMessage{
		PublicKey:         providerPublicKey,
		HypervisorActive:  &truthy,
		RDMADisabled:      &truthy,
		SIPEnabled:        &truthy,
		SecureBootEnabled: &truthy,
		BinaryHash:        testKnownBinaryHash,
		PythonHash:        "py",
		RuntimeHash:       "rt",
		TemplateHashes:    map[string]string{"chatml": "tmpl"},
		ModelHashes:       map[string]string{"qwen": "weights"},
		ActiveModelHash:   "weights",
	}
	canonical, err := attestation.BuildProviderIdentityChallengeCanonical(attestation.ProviderIdentityChallengeInput{
		ProviderIdentityPublicKey: identityPublicKey,
		PublicKey:                 resp.PublicKey,
		Nonce:                     pc.nonce,
		Timestamp:                 pc.timestamp,
		HypervisorActive:          resp.HypervisorActive,
		RDMADisabled:              resp.RDMADisabled,
		SIPEnabled:                resp.SIPEnabled,
		SecureBootEnabled:         resp.SecureBootEnabled,
		BinaryHash:                resp.BinaryHash,
		ActiveModelHash:           resp.ActiveModelHash,
		PythonHash:                resp.PythonHash,
		RuntimeHash:               resp.RuntimeHash,
		TemplateHashes:            resp.TemplateHashes,
		ModelHashes:               resp.ModelHashes,
	})
	if err != nil {
		t.Fatal(err)
	}
	resp.ProviderIdentitySignature = signProviderIdentityPayload(t, identityPriv, canonical)

	if !srv.verifyProviderIdentityChallenge(provider.ID, provider, pc, resp) {
		t.Fatal("challenge should verify when signature and binary hash are valid")
	}

	provider.Mu().Lock()
	defer provider.Mu().Unlock()
	if !provider.ProviderIdentityVerified {
		t.Fatal("valid challenge should preserve provider identity verification")
	}
}

func TestProviderIdentityChallengeCanRecoverUnverifiedProvider(t *testing.T) {
	srv, reg := providerIdentityTestServer(t)
	srv.SetKnownBinaryHashes([]string{testKnownBinaryHash})

	providerPublicKey := testPublicKeyB64()
	identityPriv, identityPublicKey := providerIdentityTestKey(t)
	provider := reg.Register("provider-1", nil, &protocol.RegisterMessage{
		Type:                      protocol.TypeRegister,
		Backend:                   "inprocess-mlx",
		PublicKey:                 providerPublicKey,
		ProviderIdentityPublicKey: identityPublicKey,
		EncryptedResponseChunks:   true,
		PrivacyCapabilities:       testPrivacyCaps(),
	})
	provider.Mu().Lock()
	provider.BinaryHash = testKnownBinaryHash
	provider.ProviderIdentityVerified = false
	provider.Mu().Unlock()

	pc := &pendingChallenge{nonce: "nonce", timestamp: "2026-04-28T20:00:00Z"}
	resp := &protocol.AttestationResponseMessage{
		PublicKey:  providerPublicKey,
		BinaryHash: testKnownBinaryHash,
	}
	canonical, err := attestation.BuildProviderIdentityChallengeCanonical(attestation.ProviderIdentityChallengeInput{
		ProviderIdentityPublicKey: identityPublicKey,
		PublicKey:                 resp.PublicKey,
		Nonce:                     pc.nonce,
		Timestamp:                 pc.timestamp,
		BinaryHash:                resp.BinaryHash,
	})
	if err != nil {
		t.Fatal(err)
	}
	resp.ProviderIdentitySignature = signProviderIdentityPayload(t, identityPriv, canonical)

	if !srv.verifyProviderIdentityChallenge(provider.ID, provider, pc, resp) {
		t.Fatal("challenge should verify and recover provider identity")
	}

	provider.Mu().Lock()
	defer provider.Mu().Unlock()
	if !provider.ProviderIdentityVerified {
		t.Fatal("valid challenge should restore provider identity verification")
	}
}

func TestKnownBinaryHashPolicyRevokesLiveProviderIdentity(t *testing.T) {
	srv, reg := providerIdentityTestServer(t)
	srv.SetKnownBinaryHashes([]string{testKnownBinaryHash})

	provider := reg.Register("provider-1", nil, &protocol.RegisterMessage{
		Type:                    protocol.TypeRegister,
		Backend:                 "inprocess-mlx",
		PublicKey:               testPublicKeyB64(),
		EncryptedResponseChunks: true,
		PrivacyCapabilities:     testPrivacyCaps(),
	})
	provider.Mu().Lock()
	provider.ProviderIdentityVerified = true
	provider.BinaryHash = testKnownBinaryHash
	provider.LastChallengeVerified = time.Now()
	provider.Mu().Unlock()

	srv.SetKnownBinaryHashes([]string{"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"})

	provider.Mu().Lock()
	defer provider.Mu().Unlock()
	if provider.ProviderIdentityVerified {
		t.Fatal("provider identity should be revoked immediately when its binary hash leaves the allow-list")
	}
	if provider.Status != registry.StatusUntrusted {
		t.Fatalf("provider status = %q, want %q", provider.Status, registry.StatusUntrusted)
	}
	if !provider.LastChallengeVerified.IsZero() {
		t.Fatal("binary hash revocation should clear challenge freshness")
	}
}

func TestChallengeResponseRequiresBinaryHashWhenKnownHashesConfigured(t *testing.T) {
	srv, reg := providerIdentityTestServer(t)
	srv.SetKnownBinaryHashes([]string{testKnownBinaryHash})

	providerPublicKey := testPublicKeyB64()
	provider := reg.Register("provider-1", nil, &protocol.RegisterMessage{
		Type:                    protocol.TypeRegister,
		Backend:                 "inprocess-mlx",
		PublicKey:               providerPublicKey,
		EncryptedResponseChunks: true,
		PrivacyCapabilities:     testPrivacyCaps(),
	})
	provider.SetLastChallengeVerified(time.Now())

	truthy := true
	pc := &pendingChallenge{nonce: "nonce", timestamp: "2026-04-28T20:00:00Z"}
	resp := &protocol.AttestationResponseMessage{
		Nonce:             pc.nonce,
		Signature:         "non-empty",
		PublicKey:         providerPublicKey,
		RDMADisabled:      &truthy,
		SIPEnabled:        &truthy,
		SecureBootEnabled: &truthy,
	}

	srv.verifyChallengeResponse(provider.ID, provider, pc, resp)

	provider.Mu().Lock()
	defer provider.Mu().Unlock()
	if provider.Status != registry.StatusUntrusted {
		t.Fatalf("provider status = %q, want %q", provider.Status, registry.StatusUntrusted)
	}
	if !provider.LastChallengeVerified.IsZero() {
		t.Fatal("missing binary hash challenge should clear prior challenge freshness")
	}
}

func TestAttestationRequiresBinaryHashWhenKnownHashesConfigured(t *testing.T) {
	srv, reg := providerIdentityTestServer(t)
	srv.SetKnownBinaryHashes([]string{testKnownBinaryHash})

	providerPublicKey := testPublicKeyB64()
	provider := reg.Register("provider-1", nil, &protocol.RegisterMessage{
		Type:                    protocol.TypeRegister,
		Backend:                 "inprocess-mlx",
		PublicKey:               providerPublicKey,
		EncryptedResponseChunks: true,
		PrivacyCapabilities:     testPrivacyCaps(),
	})
	regMsg := &protocol.RegisterMessage{
		Type:        protocol.TypeRegister,
		PublicKey:   providerPublicKey,
		Attestation: createTestAttestationJSON(t, providerPublicKey),
	}

	srv.verifyProviderAttestation(provider.ID, provider, regMsg)

	result := provider.GetAttestationResult()
	if result == nil {
		t.Fatal("expected attestation result")
	}
	if result.Valid {
		t.Fatal("attestation should fail when known binary hashes are configured but binaryHash is omitted")
	}
	if result.Error != "binary hash missing" {
		t.Fatalf("attestation error = %q, want %q", result.Error, "binary hash missing")
	}
	if provider.TrustLevel != registry.TrustNone {
		t.Fatalf("trust level = %q, want %q", provider.TrustLevel, registry.TrustNone)
	}
}

func providerIdentityTestServer(t *testing.T) (*Server, *registry.Registry) {
	t.Helper()
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory("test-key")
	reg := registry.New(logger)
	return NewServer(reg, st, logger), reg
}

func signedProviderIdentityRegisterMessage(t *testing.T, providerPublicKey, binaryHash string) *protocol.RegisterMessage {
	t.Helper()
	identityPriv, identityPublicKey := providerIdentityTestKey(t)
	msg := &protocol.RegisterMessage{
		Type:                      protocol.TypeRegister,
		Backend:                   "inprocess-mlx",
		PublicKey:                 providerPublicKey,
		BinaryHash:                binaryHash,
		Version:                   "0.4.7",
		EncryptedResponseChunks:   true,
		PythonHash:                "py",
		RuntimeHash:               "rt",
		TemplateHashes:            map[string]string{"chatml": "tmpl"},
		PrivacyCapabilities:       testPrivacyCaps(),
		ProviderIdentityPublicKey: identityPublicKey,
	}
	canonical, err := attestation.BuildProviderIdentityRegistrationCanonical(attestation.ProviderIdentityRegistrationInput{
		ProviderIdentityPublicKey: msg.ProviderIdentityPublicKey,
		PublicKey:                 msg.PublicKey,
		BinaryHash:                msg.BinaryHash,
		Version:                   msg.Version,
		Backend:                   msg.Backend,
		EncryptedResponseChunks:   msg.EncryptedResponseChunks,
		PythonHash:                msg.PythonHash,
		RuntimeHash:               msg.RuntimeHash,
		TemplateHashes:            msg.TemplateHashes,
		PrivacyCapabilities:       providerIdentityPrivacyCapabilities(msg.PrivacyCapabilities),
	})
	if err != nil {
		t.Fatal(err)
	}
	msg.ProviderIdentitySignature = signProviderIdentityPayload(t, identityPriv, canonical)
	return msg
}

func providerIdentityTestKey(t *testing.T) (*ecdsa.PrivateKey, string) {
	t.Helper()
	priv, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	return priv, base64.StdEncoding.EncodeToString(elliptic.Marshal(elliptic.P256(), priv.X, priv.Y))
}

func signProviderIdentityPayload(t *testing.T, priv *ecdsa.PrivateKey, payload []byte) string {
	t.Helper()
	hash := sha256.Sum256(payload)
	r, s, err := ecdsa.Sign(rand.Reader, priv, hash[:])
	if err != nil {
		t.Fatal(err)
	}
	der, err := asn1.Marshal(providerIdentityTestSig{R: r, S: s})
	if err != nil {
		t.Fatal(err)
	}
	return base64.StdEncoding.EncodeToString(der)
}
