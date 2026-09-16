package codeidentity

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"encoding/asn1"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"math/big"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/apns"
	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/internal/e2e"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// fakeCodeAttestor simulates APNs in-process — no real Apple push. onSend is
// invoked synchronously by sendCodeIdentityChallenge with the SAME args the
// production APNsPushAttestor would receive; a test supplies an onSend that either
// drops the challenge (to model a lost/late push) or completes the round-trip by
// feeding a code_attestation_response into the coordinator's read-loop delivery
// path (handleCodeAttestationResponse), exactly as a real WebSocket reply would.
//
// mode lets a test exercise the loop's mode-aware budget selection (Fix 3): the
// loop type-asserts Mode() on the attestor to choose the alert vs background push
// cooldown.
type fakeCodeAttestor struct {
	onSend func(deviceToken, env, pubKeyB64, nonceB64 string) error
	mode   apns.Mode
}

func (f *fakeCodeAttestor) SendCodeChallenge(_ context.Context, deviceToken, env, pubKeyB64, nonceB64 string) error {
	return f.onSend(deviceToken, env, pubKeyB64, nonceB64)
}

func (f *fakeCodeAttestor) Mode() apns.Mode { return f.mode }

// marshalP256 returns the uncompressed (0x04||X||Y) encoding ParseP256PublicKey expects.
func marshalP256(pub *ecdsa.PublicKey) []byte {
	out := make([]byte, 65)
	out[0] = 0x04
	pub.X.FillBytes(out[1:33])
	pub.Y.FillBytes(out[33:65])
	return out
}

// signSEOverString produces base64(DER ECDSA) over SHA-256(data) — the exact
// shape attestation.VerifyChallengeSignature verifies (and the Swift SE signer
// produces). This stands in for the provider's Sign_SE.
func signSEOverString(t *testing.T, key *ecdsa.PrivateKey, data string) string {
	t.Helper()
	h := sha256.Sum256([]byte(data))
	r, s, err := ecdsa.Sign(rand.Reader, key, h[:])
	if err != nil {
		t.Fatalf("sign: %v", err)
	}
	der, err := asn1.Marshal(struct{ R, S *big.Int }{r, s})
	if err != nil {
		t.Fatalf("marshal sig: %v", err)
	}
	return base64.StdEncoding.EncodeToString(der)
}

// providerKeyMaterial generates the two distinct provider keys: the X25519 K
// (encrypt/decrypt only) and the Secure-Enclave P-256 signing key.
func providerKeyMaterial(t *testing.T) (kPubB64 string, kPriv [32]byte, seKey *ecdsa.PrivateKey, sePubB64 string) {
	t.Helper()
	k, err := e2e.GenerateSessionKeys()
	if err != nil {
		t.Fatalf("gen K: %v", err)
	}
	se, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatalf("gen SE: %v", err)
	}
	return base64.StdEncoding.EncodeToString(k.PublicKey[:]), k.PrivateKey, se,
		base64.StdEncoding.EncodeToString(marshalP256(&se.PublicKey))
}

func newCodeAttestProvider(kPubB64, sePubB64 string) *registry.Provider {
	return &registry.Provider{
		ID:                "p1",
		PublicKey:         kPubB64,
		APNsDeviceToken:   "devtok",
		APNsEnvironment:   "production",
		AttestationResult: &attestation.VerificationResult{Valid: true, PublicKey: sePubB64},
	}
}

// completeRoundTrip performs the REAL coordinator-side encrypt + genuine-provider
// decrypt + SE-sign for a pushed nonce, then feeds the reply into the read-loop
// delivery path exactly as a WebSocket code_attestation_response would arrive.
// signKey is the SE key the provider signs with (the genuine key for a passing
// round-trip; a different key to model a fork). deliverTo is the connection that
// the reply lands on (the same provider normally, a DIFFERENT one for reconnect).
func completeRoundTrip(t *testing.T, srv *testManager, deliverTo *registry.Provider, deliverID string, kPriv [32]byte, signKey *ecdsa.PrivateKey, pubKeyB64, nonceB64 string) error {
	t.Helper()
	payload, err := apns.BuildCodeChallengePayload(nonceB64, pubKeyB64, apns.ModeBackground)
	if err != nil {
		return err
	}
	var body struct {
		CodeChallenge e2e.EncryptedPayload `json:"code_challenge"`
	}
	if err := json.Unmarshal(payload, &body); err != nil {
		return err
	}
	recovered, err := e2e.DecryptWithPrivateKey(&body.CodeChallenge, kPriv)
	if err != nil {
		return err
	}
	srv.HandleResponse(deliverID, deliverTo, &protocol.CodeAttestationResponseMessage{
		Type:      protocol.TypeCodeAttestationResponse,
		Nonce:     string(recovered),
		Signature: signSEOverString(t, signKey, string(recovered)),
	})
	return nil
}

func completeResumeRoundTrip(
	t *testing.T,
	srv *testManager,
	deliverTo *registry.Provider,
	deliverID string,
	kPriv [32]byte,
	signKey *ecdsa.PrivateKey,
	message protocol.CodeAttestationResumeChallenge,
) error {
	t.Helper()
	if deliverTo.GetCodeAttested() || deliverTo.GetFreshCodeAttested() {
		t.Fatal("cached evidence granted code trust before live resume proof")
	}
	recovered, err := e2e.DecryptWithPrivateKey(
		&e2e.EncryptedPayload{
			EphemeralPublicKey: message.CodeChallenge.EphemeralPublicKey,
			Ciphertext:         message.CodeChallenge.Ciphertext,
		},
		kPriv,
	)
	if err != nil {
		return err
	}
	nonce := string(recovered)
	srv.HandleResponse(
		deliverID,
		deliverTo,
		&protocol.CodeAttestationResponseMessage{
			Type:      protocol.TypeCodeAttestationResponse,
			Nonce:     nonce,
			Signature: signSEOverString(t, signKey, nonce),
		},
	)
	return nil
}

// waitForCond polls cond up to d, returning its final value. Used to observe a
// goroutine-driven re-arm/attestation outcome without a fixed sleep.
func waitForCond(d time.Duration, cond func() bool) bool {
	deadline := time.Now().Add(d)
	for time.Now().Before(deadline) {
		if cond() {
			return true
		}
		time.Sleep(time.Millisecond)
	}
	return cond()
}

func fastBudgets(srv *testManager) {
	srv.state.backgroundPushCooldown = time.Millisecond
	srv.state.alertPushCooldown = time.Millisecond
	srv.state.budgetClearCooldown = time.Millisecond
	srv.state.retrySpacing = time.Millisecond
	srv.state.retryJitter = 0
}

func providerToken(p *registry.Provider) string {
	p.Mu().Lock()
	defer p.Mu().Unlock()
	return p.APNsDeviceToken
}

// quietLogger returns a logger that discards everything — for tests that
// exercise noisy failure paths.
func quietLogger() *slog.Logger { return slog.New(slog.NewTextHandler(io.Discard, nil)) }

func normalizeSHA256Hex(value, field string) (string, error) {
	value = strings.ToLower(strings.TrimSpace(value))
	if len(value) != sha256.Size*2 {
		return "", fmt.Errorf("%s must be a 64-character SHA-256 hex digest", field)
	}
	if _, err := hex.DecodeString(value); err != nil {
		return "", fmt.Errorf("%s must be a valid SHA-256 hex digest", field)
	}
	return value, nil
}

// providerApplicationBinaryHash resolves the binary measured for this
// connection. A registration hash is authoritative when present. Hashless
// registrations may use fresh application evidence only while it remains
// installed and bound to both the verified SE identity and this provider
// process's current public key.
func providerApplicationBinaryHash(provider *registry.Provider, seKey, registrationHash string) string {
	if registrationHash != "" {
		return registrationHash
	}
	if provider == nil || seKey == "" {
		return ""
	}

	provider.Mu().Lock()
	defer provider.Mu().Unlock()
	evidence := provider.ApplicationEvidence
	if evidence.EvidenceGeneration == 0 || evidence.SEPublicKey != seKey ||
		provider.PublicKey == "" || evidence.ProcessPublicKey != provider.PublicKey {
		return ""
	}
	return evidence.BinaryHash
}

const trHashA = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

func makeRoutableProvider(t *testing.T, reg *registry.Registry, id, model string) *registry.Provider {
	t.Helper()
	msg := &protocol.RegisterMessage{
		Type: protocol.TypeRegister,
		Hardware: protocol.Hardware{
			MachineModel:       "Mac15,8",
			ChipName:           "Apple M3 Max",
			MemoryGB:           64,
			MemoryBandwidthGBs: 400,
			CPUCores:           protocol.CPUCores{Total: 16, Performance: 12, Efficiency: 4},
			GPUCores:           40,
		},
		Models: []protocol.ModelInfo{
			{ID: model, SizeBytes: 5_000_000_000, ModelType: "chat", Quantization: "4bit"},
		},
		Backend:                 "mlx-swift",
		PublicKey:               "fX6XYH7p2hmM3ogeXaAsY+p8M6UKD1df/LJUN9Nj9Nw=",
		EncryptedResponseChunks: true,
		PrivacyCapabilities: &protocol.PrivacyCapabilities{
			TextBackendInprocess:    true,
			TextProxyDisabled:       true,
			PythonRuntimeLocked:     true,
			DangerousModulesBlocked: true,
			SIPEnabled:              true,
			AntiDebugEnabled:        true,
			CoreDumpsDisabled:       true,
			EnvScrubbed:             true,
		},
	}
	p := reg.Register(id, nil, msg)
	// This helper constructs an already registered, routable fixture. Recovery
	// failure cases use their own pending-registration fixtures.
	p.CompleteProviderStateRestore()
	p.Mu().Lock()
	p.TrustLevel = registry.TrustHardware
	p.RuntimeVerified = true
	p.RuntimeManifestChecked = true
	p.ChallengeVerifiedSIP = true
	p.LastChallengeVerified = time.Now()
	p.DecodeTPS = 90.0
	p.PrefillTPS = 500.0
	p.SystemMetrics = protocol.SystemMetrics{
		MemoryPressure: 0.1,
		CPUUsage:       0.1,
		ThermalState:   "nominal",
	}
	p.BackendCapacity = &protocol.BackendCapacity{
		TotalMemoryGB:     64,
		GPUMemoryActiveGB: 8,
		Slots: []protocol.BackendSlotCapacity{
			{Model: model, State: "running", NumRunning: 0, NumWaiting: 0},
		},
	}
	p.Mu().Unlock()
	return p
}
